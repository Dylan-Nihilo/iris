import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreImage

/// Captures one target into a session directory: the frames, the input activity around
/// them and the shape of the captured window.
public final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let target: CaptureTarget
    private let store: SessionStore
    private let fps: Int
    private var info: SessionInfo
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sampler: InputSampler?
    private var watcher: Task<Void, Never>?
    private var detector: ChangeDetector?
    private let queue = DispatchQueue(label: "iris.recorder.frames")

    // Touched only on `queue`.
    private var startHost: Double?
    private var lastWritten = -1.0
    private var pausedTotal = 0.0
    private var pauseStart: Double?
    private var pauses: [Interval] = []
    private var frames = 0
    private var failure: String?

    public var onFailure: ((String) -> Void)?

    public init(target: CaptureTarget, store: SessionStore, name: String, fps: Int) {
        self.target = target
        self.store = store
        self.fps = fps
        // Encoders want even dimensions.
        let width = Int((target.captureRect.width * target.scale).rounded()) / 2 * 2
        let height = Int((target.captureRect.height * target.scale).rounded()) / 2 * 2
        self.info = SessionInfo(name: name, createdAt: Date(), target: target.info,
                                captureRect: Rect(target.captureRect), scale: target.scale,
                                pixelWidth: width, pixelHeight: height, fps: fps)
    }

    private func configuration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        if target.alone {
            config.ignoreShadowsSingleWindow = true
        } else {
            config.sourceRect = target.sourceRect
        }
        config.width = info.pixelWidth
        config.height = info.pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        // The pointer is drawn again at render time, smoothed and enlarged.
        config.showsCursor = false
        config.capturesAudio = false
        config.queueDepth = 6
        config.scalesToFit = false
        config.backgroundColor = .clear
        return config
    }

    public func start() async throws {
        try store.writeInfo(info)
        await captureMask()

        try? FileManager.default.removeItem(at: store.rawURL)
        let writer = try AVAssetWriter(outputURL: store.rawURL, fileType: .mov)
        let pixels = Double(info.pixelWidth * info.pixelHeight)
        let bitrate = min(max(pixels * Double(fps) * 0.09, 8_000_000), 60_000_000)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: info.pixelWidth,
            AVVideoHeightKey: info.pixelHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw IrisError("cannot set up the video encoder") }
        writer.add(input)
        guard writer.startWriting() else {
            throw IrisError("cannot start writing: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        detector = ChangeDetector(store: store)

        let stream = SCStream(filter: target.filter, configuration: configuration(), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        watchApplications()

        // The pointer and the keyboard work on the desktop in view; a window that is not there
        // gets none of it, and what is declared is all there is to show.
        guard !target.alone else { return }
        let sampler = InputSampler(store: store, captureRect: target.captureRect,
                                   targetPID: target.isolated ? target.window?.owningApplication?.processID : nil)
        await MainActor.run { sampler.start() }
        self.sampler = sampler
    }

    /// Saves the alpha shape of the captured window, so the render keeps its true corners.
    private func captureMask() async {
        guard let window = target.window else { return }
        let config = SCStreamConfiguration()
        config.width = Int((window.frame.width * target.scale).rounded())
        config.height = Int((window.frame.height * target.scale).rounded())
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.backgroundColor = .clear
        let alone = SCContentFilter(desktopIndependentWindow: window)
        guard let whole = try? await SCScreenshotManager.captureImage(contentFilter: alone, configuration: config) else { return }
        // The part of the window that is recorded, when it hangs off the display.
        let sx = Double(whole.width) / window.frame.width, sy = Double(whole.height) / window.frame.height
        let part = CGRect(x: (target.captureRect.minX - window.frame.minX) * sx, y: (target.captureRect.minY - window.frame.minY) * sy,
                          width: target.captureRect.width * sx, height: target.captureRect.height * sy).integral
        guard let image = whole.cropping(to: part) else { return }
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var alpha = [UInt8](repeating: 0, count: width * height)
        var transparent = 0
        for i in 0..<(width * height) {
            let a = rgba[i * 4 + 3]
            alpha[i] = a
            if a < 128 { transparent += 1 }
        }
        // A fully opaque capture has no shape to keep; a mostly empty one is not a window.
        let share = Double(transparent) / Double(width * height)
        guard share > 0.00002, share < 0.5 else { return }
        guard let provider = CGDataProvider(data: Data(alpha) as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        let rep = NSBitmapImageRep(cgImage: mask)
        try? rep.representation(using: .png, properties: [:])?.write(to: store.maskURL)
    }

    /// Keeps applications launched during the recording out of a window's picture.
    private func watchApplications() {
        guard target.isolated, !target.alone, let pid = target.window?.owningApplication?.processID else { return }
        let display = target.display
        watcher = Task { [weak self] in
            var known: Set<pid_t> = []
            _ = await Targets.refreshedIsolation(pid, on: display, known: &known)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let stream = self?.stream else { return }
                if let filter = await Targets.refreshedIsolation(pid, on: display, known: &known) {
                    try? await stream.updateContentFilter(filter)
                }
            }
        }
    }

    // MARK: Frames

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let input, let adaptor else { return }
        let host = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if pauseStart != nil { return }
        if startHost == nil { startHost = host }
        let time = host - startHost! - pausedTotal
        // Frames must move forward in time; a resume can land one a hair early.
        guard time > lastWritten + 0.001, input.isReadyForMoreMediaData else { return }
        if adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 60_000)) {
            lastWritten = time
            frames += 1
            detector?.observe(buffer, host: host)
        } else if failure == nil {
            failure = writer?.error?.localizedDescription ?? "the encoder rejected a frame"
            onFailure?(failure!)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard self.failure == nil else { return }
            self.failure = error.localizedDescription
            self.onFailure?(error.localizedDescription)
        }
    }

    // MARK: Control

    public func pause() {
        queue.sync { if pauseStart == nil { pauseStart = HostClock.now } }
    }

    public func resume() {
        queue.sync {
            guard let start = pauseStart else { return }
            let end = HostClock.now
            pauses.append(Interval(start: start, end: end))
            pausedTotal += end - start
            pauseStart = nil
        }
    }

    public var isPaused: Bool { queue.sync { pauseStart != nil } }

    public func progress() -> (frames: Int, duration: Double) {
        queue.sync {
            guard let startHost else { return (0, 0) }
            let end = pauseStart ?? HostClock.now
            return (frames, max(0, end - startHost - pausedTotal))
        }
    }

    public func stop() async throws -> SessionInfo {
        resume()
        let end = HostClock.now
        if let sampler { await MainActor.run { sampler.stop() } }
        watcher?.cancel()
        try? await stream?.stopCapture()
        stream = nil
        let (start, total, list, count) = queue.sync { (startHost, pausedTotal, pauses, frames) }
        queue.sync { detector?.close() }
        input?.markAsFinished()
        if let writer {
            await writer.finishWriting()
            if writer.status == .failed {
                throw IrisError("the recording could not be saved: \(writer.error?.localizedDescription ?? "unknown")")
            }
        }
        guard let start, count > 0 else { throw IrisError("no frame was captured") }
        info.startHost = start
        info.endHost = end
        info.pauses = list
        info.duration = max(0, end - start - total)
        try store.writeInfo(info)
        return info
    }
}
