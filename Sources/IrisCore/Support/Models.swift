import Foundation
import CoreGraphics

/// Everything on disk for one recording lives in a session directory:
///   session.json   static facts about the capture
///   raw.mov        the untouched capture, variable frame rate
///   mask.png       alpha shape of the captured window (optional)
///   input.jsonl    cursor samples, clicks, key and scroll activity
///   marks.jsonl    what the operator declared: focus points, captions, shortcut keys, pace
///   changes.jsonl  where and how much the picture changed, about ten times a second
///   state.json     live status written by the recorder
public struct SessionInfo: Codable {
    public var version = 1
    public var name: String
    public var createdAt: Date
    public var target: TargetInfo
    /// Captured area in global screen points, origin at the top left of the main display.
    public var captureRect: Rect
    /// Pixels per point of the capture.
    public var scale: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var fps: Int
    /// Host time (seconds, mach absolute time base) of the first recorded frame.
    public var startHost: Double?
    public var endHost: Double?
    /// Host time intervals that were dropped from the recording.
    public var pauses: [Interval] = []
    public var duration: Double?
}

public struct TargetInfo: Codable {
    public var kind: String          // "window" | "display" | "region"
    public var app: String?
    public var bundleID: String?
    public var title: String?
    public var windowID: UInt32?
    public var displayID: UInt32
    /// For a window: "application" (its application alone, as the display shows it), "window"
    /// (the window by itself, for one that is not on the visible desktop) or "screen".
    public var capture: String?
}

public struct Rect: Codable, Equatable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; w = r.width; h = r.height }
    public var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

public struct Interval: Codable, Equatable {
    public var start: Double, end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var length: Double { end - start }
}

public struct RecorderState: Codable {
    public var status: String        // "starting" | "recording" | "paused" | "finished" | "failed"
    public var pid: Int32
    public var frames: Int
    public var duration: Double
    public var error: String?
    public var updatedAt: Date
}

/// One line of input.jsonl. `u` is host time; x and y are normalized to the capture rect
/// (0,0 top left, 1,1 bottom right) and may fall outside it.
public struct InputEvent: Codable {
    public var u: Double
    public var k: String             // "m" move, "d" button down, "u" button up, "k" key, "s" scroll, "c" cursor shape
    public var x: Double?
    public var y: Double?
    public var b: Int?               // button: 0 left, 1 right
    public var c: String?            // cursor shape id
    /// 0 when a click, key or scroll went to some other application than the recorded one.
    public var f: Int?
    public init(u: Double, k: String, x: Double? = nil, y: Double? = nil, b: Int? = nil, c: String? = nil, f: Int? = nil) {
        self.u = u; self.k = k; self.x = x; self.y = y; self.b = b; self.c = c; self.f = f
    }
}

/// One line of changes.jsonl: the part of the picture that differs from a moment earlier.
public struct ChangeEvent: Codable {
    public var u: Double
    /// Share of the picture that changed, 0 to 1.
    public var n: Double
    /// Box around everything that changed, normalized to the capture rect.
    public var x: Double, y: Double, w: Double, h: Double
    /// 1 for a sliver the size of a text caret.
    public var s: Int?
}

/// One line of marks.jsonl: something the operator declares. A focus point, for actions that
/// leave no trace in the system input stream (DOM or CDP driven clicks, results worth
/// showing); words for the viewer; the keys of a shortcut; a change of pace.
public struct Mark: Codable {
    public var u: Double
    /// Recording time in seconds; when present it replaces `u`, for marks added afterwards.
    public var t: Double?
    public var kind: String          // "click" | "focus" | "type" | "wide" | "caption" | "keys" | "speed"
    public var x: Double?            // normalized to the capture rect
    public var y: Double?
    public var w: Double?            // normalized size when a region was given
    public var h: Double?
    public var zoom: Double?
    public var hold: Double?
    public var label: String?
    /// What the viewer reads: a caption, or the keys of a shortcut such as "cmd+k".
    public var text: String?
    /// For a speed mark: how many times faster than recorded the video runs from here on.
    public var rate: Double?
    public init(u: Double, t: Double? = nil, kind: String, x: Double? = nil, y: Double? = nil, w: Double? = nil, h: Double? = nil,
                zoom: Double? = nil, hold: Double? = nil, label: String? = nil, text: String? = nil, rate: Double? = nil) {
        self.u = u; self.t = t; self.kind = kind; self.x = x; self.y = y; self.w = w; self.h = h
        self.zoom = zoom; self.hold = hold; self.label = label; self.text = text; self.rate = rate
    }
}

public struct IrisError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum HostClock {
    /// Seconds on the mach absolute time base, the same base ScreenCaptureKit stamps frames with.
    public static var now: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_absolute_time()
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}
