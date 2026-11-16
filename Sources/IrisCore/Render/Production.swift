import Foundation
import AVFoundation
import CoreImage
import CoreText

public struct RenderOptions {
    public var style = RenderStyle()
    public var zoom = ZoomPolicy()
    public var motion = MotionPolicy()
    public var fps = 60
    /// Longest stretch of nothing happening that is kept; nil keeps the recording's own pace.
    public var idleMax: Double? = 1.5
    public var pointer = PointerSource.auto
    public var focus = FocusSource.auto
    /// The video ends on the full view: when the recording stops while the camera is still
    /// in, its last picture is held for up to this long while the camera pulls back.
    public var outro = 2.5
    /// Move declared actions to the moment the picture answers them.
    public var syncMarks = true
    /// Show declared captions, show declared shortcut keys, follow declared changes of pace.
    public var captions = true
    public var keys = true
    public var speed = true
    public init() {}
}

/// What the camera goes by.
public enum FocusSource: String {
    /// Declared marks and clicks; the changes in the picture when there are neither.
    case auto
    /// Declared marks and clicks only.
    case declared
    /// The changes in the picture only.
    case visual
}

/// A recording prepared for rendering: its clock, zoom plan, pointer and camera, worked out
/// once so that any frame of the finished video can be drawn on its own.
public final class Production {
    public let store: SessionStore
    public let info: SessionInfo
    public let options: RenderOptions
    public let map: TimeMap
    public private(set) var timeline: Timeline
    public let plan: ZoomPlan
    /// Captions and shortcut keys, and the stretches that run faster than recorded.
    public let overlays: [Overlay]
    public let fast: [Pace]
    /// What the pointer and the camera turned out to go by.
    public let pointer: PointerSource
    public let focus: FocusSource
    public let frames: Int
    public let compositor: Compositor
    let cursor: CursorTrack
    let camera: CameraTrack
    private let ripples: [Click]
    private let lastSourceFrame: Double

    public var duration: Double { Double(frames) / Double(options.fps) }

    public init(store: SessionStore, options: RenderOptions) async throws {
        self.store = store
        self.options = options
        let info = try store.readInfo()
        self.info = info
        guard FileManager.default.fileExists(atPath: store.rawURL.path) else {
            throw IrisError("the session has no recording yet: \(store.dir.path)")
        }
        if let state = store.readState(), ["recording", "paused", "starting"].contains(state.status), kill(state.pid, 0) == 0 {
            throw IrisError("the recording is still running; run `iris stop` first")
        }
        let frameTimes = try await Self.frameTimes(store.rawURL)
        lastSourceFrame = frameTimes.last ?? 0
        var recorded = Timeline(info: info, input: store.readInput(), marks: store.readMarks(), frameTimes: frameTimes,
                                changes: store.readChanges())
        guard recorded.duration > 0 else { throw IrisError("the recording is empty") }
        if options.syncMarks { recorded = recorded.syncedToResponses() }
        pointer = recorded.pointerSource(options.pointer)
        if pointer == .declared { recorded = recorded.declaredOnly() }

        var map: TimeMap
        if let idleMax = options.idleMax {
            map = TimeMap.trimmingIdle(duration: recorded.duration,
                                       activity: recorded.activity(markHold: options.zoom.focusHold), idleMax: idleMax)
        } else {
            map = TimeMap.identity(duration: recorded.duration)
        }
        if options.speed { map = map.paced(recorded.paces) }
        self.map = map
        fast = map.fast
        timeline = recorded.remapped(map)
        overlays = Overlays.build(timeline: timeline, lead: options.zoom.lead).filter {
            $0.kind == "keys" ? options.keys : options.captions
        }

        var seen = timeline
        let directed = timeline.clicks.contains { $0.button == 0 }
            || timeline.marks.contains { $0.mark.kind != "wide" && $0.mark.x != nil && $0.mark.y != nil }
        if options.focus == .visual || (options.focus == .auto && !directed && timeline.changes != nil) {
            focus = .visual
            seen.clicks = []
            seen.keys = []
            seen.marks = timeline.marks.filter { $0.mark.kind == "wide" }
                + VisualFocus.marks(changes: timeline.changes ?? [], policy: options.zoom)
            seen.marks.sort { $0.t < $1.t }
        } else {
            focus = .declared
        }
        seen.duration += options.outro
        plan = ZoomPlan(timeline: seen, policy: options.zoom)
        if let last = plan.segments.last, last.end > timeline.duration - 1.2 {
            timeline.duration = min(last.end + 1.3, seen.duration)
        }
        let fps = Double(options.fps)
        frames = max(1, Int((timeline.duration * fps).rounded(.up)))
        compositor = try Compositor(info: info, store: store, style: options.style)
        cursor = CursorTrack(timeline: timeline, fps: fps, frames: frames,
                             size: (info.captureRect.w, info.captureRect.h), policy: options.motion)
        camera = CameraTrack(plan: plan, cursor: cursor, fps: fps, frames: frames, view: compositor.view, policy: options.motion)

        var rings = timeline.clicks.filter { $0.button == 0 }
        for item in timeline.marks where item.mark.kind == "click" {
            guard let x = item.mark.x, let y = item.mark.y else { continue }
            if !rings.contains(where: { abs($0.t - item.t) < 0.4 }) { rings.append(Click(t: item.t, p: Point(x: x, y: y))) }
        }
        ripples = rings
    }

    static func frameTimes(_ url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw IrisError("the recording has no video: \(url.path)")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw IrisError("cannot read the recording: \(reader.error?.localizedDescription ?? "")") }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if time.isFinite { times.append(time) }
        }
        return times.sorted()
    }

    /// Draws frame `index` of the finished video over the matching frame of the recording.
    public func image(frame index: Int, source: CIImage) -> CIImage {
        let t = Double(index) / Double(options.fps)
        let life = 0.5
        let active = ripples.filter { t >= $0.t && t - $0.t < life }
            .map { Ripple(point: $0.p, progress: (t - $0.t) / life) }
        let state = index < cursor.states.count ? cursor.states[index] : nil
        var notes = overlays.filter { $0.presence(at: t) > 0 }
            .map { Note(kind: $0.kind == "keys" ? .keys : .caption, text: $0.text, presence: $0.presence(at: t)) }
        for pace in fast where t > pace.start && t < pace.end {
            let fade = min(0.2, (pace.end - pace.start) / 2)
            notes.append(Note(kind: .pace, text: Overlays.paceLabel(pace.rate), presence: min((t - pace.start) / fade, (pace.end - t) / fade, 1)))
        }
        return compositor.frame(source: source, camera: camera.states[index],
                                previous: index > 0 ? camera.states[index - 1] : nil, cursor: state, ripples: active, notes: notes)
    }

    public func cameraState(frame index: Int) -> Camera { camera.states[min(max(index, 0), frames - 1)] }

    // MARK: Video

    /// Calls `body` with every frame of the finished video in order, each drawn over the
    /// frame of the recording that was on screen at that moment.
    private func compose(_ body: (Int, CIImage) async throws -> Void) async throws {
        let asset = AVURLAsset(url: store.rawURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw IrisError("the recording has no video")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw IrisError("cannot read the recording: \(reader.error?.localizedDescription ?? "")") }
        defer { reader.cancelReading() }

        var current: CVPixelBuffer?
        var upcoming: (time: Double, buffer: CVPixelBuffer)?
        func read() -> (Double, CVPixelBuffer)? {
            while let sample = output.copyNextSampleBuffer() {
                if let buffer = CMSampleBufferGetImageBuffer(sample) {
                    return (CMSampleBufferGetPresentationTimeStamp(sample).seconds, buffer)
                }
            }
            return nil
        }
        upcoming = read()
        current = upcoming?.buffer

        for index in 0..<frames {
            let sourceTime = map.source(Double(index) / Double(options.fps))
            while let next = upcoming, next.time <= sourceTime + 0.0005 {
                current = next.buffer
                upcoming = read()
            }
            guard let current else { throw IrisError("the recording has no frames") }
            try await body(index, image(frame: index, source: CIImage(cvPixelBuffer: current)))
        }
    }

    public func export(to url: URL, progress: ((Double) -> Void)? = nil) async throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let width = compositor.width, height = compositor.height, fps = options.fps
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // Screen pictures are flat and mostly still; this is generous for them.
        let bitrate = min(max(Double(width * height * fps) * 0.045, 2_500_000), 24_000_000)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        guard writer.canAdd(input) else { throw IrisError("cannot set up the video encoder") }
        writer.add(input)
        guard writer.startWriting() else { throw IrisError("cannot write \(url.path): \(writer.error?.localizedDescription ?? "")") }
        writer.startSession(atSourceTime: .zero)

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let space = CGColorSpace(name: CGColorSpace.itur_709)!
        let total = frames
        try await compose { index, image in
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing { throw IrisError("encoding failed: \(writer.error?.localizedDescription ?? "")") }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try autoreleasepool {
                guard let pool = adaptor.pixelBufferPool else { throw IrisError("the encoder gave no frame buffers") }
                var target: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target)
                guard let target else { throw IrisError("out of frame buffers") }
                self.compositor.context.render(image, to: target, bounds: canvas, colorSpace: space)
                if !adaptor.append(target, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))) {
                    throw IrisError("encoding failed: \(writer.error?.localizedDescription ?? "")")
                }
            }
            if index % 15 == 0 { progress?(Double(index) / Double(total)) }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(fps)))
        await writer.finishWriting()
        if writer.status != .completed { throw IrisError("encoding failed: \(writer.error?.localizedDescription ?? "")") }
        progress?(1)
    }

    // MARK: GIF

    /// Writes the video as a GIF with a palette of its own; needs ffmpeg. The frames go to
    /// ffmpeg as drawn, never through a video codec: a codec's noise would make every frame
    /// differ from the last, and a GIF is small only where frames repeat.
    public func exportGIF(to url: URL, progress: ((Double) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let width = compositor.width, height = compositor.height
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("iris-gif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let frames = work.appendingPathComponent("frames.mkv"), palette = work.appendingPathComponent("palette.png")

        // A lossless copy on disk first: the palette is chosen from all frames before any is drawn.
        signal(SIGPIPE, SIG_IGN)
        let encoder = try FFmpeg.start(["-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "\(width)x\(height)",
                                        "-framerate", "\(options.fps)", "-i", "pipe:0", "-c:v", "ffv1", frames.path], input: true)
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let rowBytes = width * 4
        var bitmap = Data(count: rowBytes * height)
        let total = self.frames
        do {
            try await compose { index, image in
                try autoreleasepool {
                    bitmap.withUnsafeMutableBytes { bytes in
                        self.compositor.context.render(image, toBitmap: bytes.baseAddress!, rowBytes: rowBytes, bounds: canvas,
                                                       format: .BGRA8, colorSpace: space)
                    }
                    try encoder.input!.write(contentsOf: bitmap)
                }
                if index % 15 == 0 { progress?(Double(index) / Double(total) * 0.8) }
            }
        } catch {
            encoder.process.terminate()
            throw encoder.failure() ?? error
        }
        try encoder.finish()

        try FFmpeg.start(["-i", frames.path, "-vf", "palettegen=max_colors=256:stats_mode=diff", palette.path]).finish()
        progress?(0.9)
        try? FileManager.default.removeItem(at: url)
        try FFmpeg.start(["-i", frames.path, "-i", palette.path, "-lavfi", "paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
                          "-loop", "0", url.path]).finish()
        progress?(1)
    }

    // MARK: Stills

    /// Single composed frames of the finished video at the given moments, with the moment
    /// each one really shows.
    private func pictures(at times: [Double]) async throws -> [(time: Double, image: CGImage)] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: store.rawURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = timeline.frameTimes.first ?? 0
        let canvas = CGRect(x: 0, y: 0, width: compositor.width, height: compositor.height)
        var result: [(Double, CGImage)] = []
        for time in times {
            let index = min(max(Int((time * Double(options.fps)).rounded()), 0), frames - 1)
            let sourceTime = min(max(map.source(Double(index) / Double(options.fps)), map.source(0) + first), lastSourceFrame)
            let picture = try await generator.image(at: CMTime(seconds: sourceTime, preferredTimescale: 60_000)).image
            let image = self.image(frame: index, source: CIImage(cgImage: picture))
            guard let drawn = compositor.context.createCGImage(image, from: canvas) else { throw IrisError("cannot draw the frame at \(time)") }
            result.append((Double(index) / Double(options.fps), drawn))
        }
        return result
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw IrisError("cannot write \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw IrisError("cannot write \(url.path)") }
    }

    /// Saves single composed frames at the given moments of the finished video.
    public func stills(at times: [Double], to dir: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written: [URL] = []
        for picture in try await pictures(at: times) {
            let url = dir.appendingPathComponent(String(format: "frame-%07.3f.png", picture.time))
            try Self.write(picture.image, to: url)
            written.append(url)
        }
        return written
    }

    /// Saves one image with the frames at the given moments side by side, each labelled with
    /// its time: the whole video at a glance, for whoever cannot play it.
    public func sheet(at times: [Double], columns: Int, tileWidth: Int, to url: URL) async throws {
        let pictures = try await pictures(at: times)
        guard !pictures.isEmpty else { throw IrisError("no frames to show") }
        let columns = min(max(columns, 1), pictures.count)
        let rows = (pictures.count + columns - 1) / columns
        let gap = 8
        let tileHeight = Int((Double(tileWidth) * Double(compositor.height) / Double(compositor.width)).rounded())
        let width = columns * tileWidth + (columns + 1) * gap, height = rows * tileHeight + (rows + 1) * gap
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw IrisError("cannot draw a sheet of \(width)x\(height)")
        }
        context.setFillColor(CGColor(gray: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, max(CGFloat(tileWidth) / 34, 11), nil)
        for (index, picture) in pictures.enumerated() {
            let column = index % columns, row = index / columns
            let tile = CGRect(x: gap + column * (tileWidth + gap), y: height - (row + 1) * (tileHeight + gap),
                              width: tileWidth, height: tileHeight)
            context.draw(picture.image, in: tile)
            let text = CTLineCreateWithAttributedString(NSAttributedString(string: String(format: "%.2fs", picture.time), attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
            ]))
            let bounds = CTLineGetBoundsWithOptions(text, .useOpticalBounds)
            let label = CGRect(x: tile.minX + 6, y: tile.minY + 6, width: bounds.width + 12, height: bounds.height + 8)
            context.setFillColor(CGColor(gray: 0, alpha: 0.72))
            context.addPath(CGPath(roundedRect: label, cornerWidth: 5, cornerHeight: 5, transform: nil))
            context.fillPath()
            context.textPosition = CGPoint(x: label.minX + 6 - bounds.minX, y: label.minY + 4 - bounds.minY)
            CTLineDraw(text, context)
        }
        guard let image = context.makeImage() else { throw IrisError("cannot draw the sheet") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.write(image, to: url)
    }
}

/// One run of ffmpeg.
struct FFmpeg {
    let process: Process
    let input: FileHandle?
    private let errors: Pipe

    static func start(_ arguments: [String], input: Bool = false) throws -> FFmpeg {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-y", "-v", "error"] + arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let pipe = input ? Pipe() : nil
        process.standardInput = pipe ?? FileHandle.nullDevice
        do { try process.run() } catch { throw IrisError(missing) }
        return FFmpeg(process: process, input: pipe?.fileHandleForWriting, errors: errors)
    }

    static let missing = "a GIF needs ffmpeg; install it with `brew install ffmpeg`"

    /// What went wrong, once the run has ended badly.
    func failure() -> IrisError? {
        try? input?.close()
        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        // `env` reports a missing program with status 127.
        return IrisError(process.terminationStatus == 127 ? Self.missing : "ffmpeg could not make the GIF: \(text.suffix(400))")
    }

    func finish() throws {
        if let failure = failure() { throw failure }
    }
}
