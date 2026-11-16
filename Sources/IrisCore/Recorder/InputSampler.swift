import Foundation
import AppKit
import CoreGraphics

/// Samples the pointer, button, key and scroll activity of the whole login session while a
/// recording runs. It reads the window server's event counters instead of tapping events,
/// so it needs no accessibility permission and also sees input synthesized by an agent.
final class InputSampler {
    private let store: SessionStore
    private let captureRect: CGRect
    /// The recorded application, when the recording shows it alone.
    private let targetPID: pid_t?
    private var timer: DispatchSourceTimer?
    private var handle: FileHandle?
    private var lastPoint = CGPoint(x: -1, y: -1)
    private var lastMoveWrite = 0.0
    private var counters: [CGEventType: UInt32] = [:]
    private var lastKeyWrite = 0.0
    private var lastScrollWrite = 0.0
    private var tick = 0
    private var cursorID = ""
    private var knownCursors = Set<String>()

    private static let watched: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .keyDown, .scrollWheel]

    init(store: SessionStore, captureRect: CGRect, targetPID: pid_t?) {
        self.store = store
        self.captureRect = captureRect
        self.targetPID = targetPID
    }

    /// 0 when the window under `point` belongs to another application: somebody working
    /// beside a recording of one window clicks and scrolls, but not in the picture.
    private func reaches(_ point: CGPoint) -> Int? {
        guard let targetPID else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in list {
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let owner = window[kCGWindowOwnerPID as String] as? Int else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard frame.contains(point), (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            if pid_t(owner) == targetPID { return nil }
            // Overlays and status items of other applications float above without taking clicks.
            if (window[kCGWindowLayer as String] as? Int ?? 0) == 0 { return 0 }
        }
        return 0
    }

    private func focused() -> Int? {
        guard let targetPID else { return nil }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID ? nil : 0
    }

    func start() {
        FileManager.default.createFile(atPath: store.inputURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: store.inputURL)
        try? FileManager.default.createDirectory(at: store.cursorsDir, withIntermediateDirectories: true)
        for type in Self.watched { counters[type] = Self.count(type) }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        try? handle?.close()
        handle = nil
    }

    private static func count(_ type: CGEventType) -> UInt32 {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: type)
    }

    private func sample() {
        let now = HostClock.now
        tick += 1
        guard let location = CGEvent(source: nil)?.location else { return }
        let x = (location.x - captureRect.minX) / captureRect.width
        let y = (location.y - captureRect.minY) / captureRect.height

        if tick % 4 == 1 { sampleCursorShape(now) }

        let moved = abs(location.x - lastPoint.x) > 0.25 || abs(location.y - lastPoint.y) > 0.25
        if moved || now - lastMoveWrite > 0.5 {
            write(InputEvent(u: now, k: "m", x: x, y: y))
            lastPoint = location
            lastMoveWrite = now
        }

        for type in Self.watched {
            let value = Self.count(type)
            let previous = counters[type] ?? value
            guard value != previous else { continue }
            counters[type] = value
            switch type {
            case .leftMouseDown: write(InputEvent(u: now, k: "d", x: x, y: y, b: 0, f: reaches(location)))
            case .leftMouseUp: write(InputEvent(u: now, k: "u", x: x, y: y, b: 0))
            case .rightMouseDown: write(InputEvent(u: now, k: "d", x: x, y: y, b: 1, f: reaches(location)))
            case .rightMouseUp: write(InputEvent(u: now, k: "u", x: x, y: y, b: 1))
            case .keyDown:
                if now - lastKeyWrite > 0.04 { write(InputEvent(u: now, k: "k", f: focused())); lastKeyWrite = now }
            case .scrollWheel:
                if now - lastScrollWrite > 0.1 { write(InputEvent(u: now, k: "s", x: x, y: y, f: reaches(location))); lastScrollWrite = now }
            default: break
            }
        }
    }

    /// Records which pointer image the system shows, saving each distinct image once.
    private func sampleCursorShape(_ now: Double) {
        guard let cursor = NSCursor.currentSystem else { return }
        let reps = cursor.image.representations.compactMap { $0 as? NSBitmapImageRep }
        guard let smallest = reps.min(by: { $0.pixelsWide < $1.pixelsWide }),
              let largest = reps.max(by: { $0.pixelsWide < $1.pixelsWide }),
              let bytes = smallest.bitmapData else { return }
        var hash: UInt64 = 0xcbf29ce484222325
        let length = smallest.bytesPerRow * smallest.pixelsHigh
        for i in 0..<length {
            hash = (hash ^ UInt64(bytes[i])) &* 0x100000001b3
        }
        let id = String(hash, radix: 16)
        guard id != cursorID else { return }
        cursorID = id
        if !knownCursors.contains(id) {
            knownCursors.insert(id)
            if let png = largest.representation(using: .png, properties: [:]) {
                try? png.write(to: store.cursorsDir.appendingPathComponent("\(id).png"))
            }
            let shape = CursorShape(id: id, width: cursor.image.size.width, height: cursor.image.size.height,
                                    hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y)
            if let data = try? SessionStore.encoder.encode(shape) {
                try? data.write(to: store.cursorsDir.appendingPathComponent("\(id).json"))
            }
        }
        write(InputEvent(u: now, k: "c", c: id))
    }

    private func write(_ event: InputEvent) {
        guard let handle, var data = try? SessionStore.lineEncoder.encode(event) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }
}

/// A pointer image saved with a recording; sizes are in points.
public struct CursorShape: Codable {
    public var id: String
    public var width: Double
    public var height: Double
    public var hotX: Double
    public var hotY: Double
}
