import Foundation
import CoreGraphics

public struct Point: Codable, Equatable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let center = Point(x: 0.5, y: 0.5)
}

public struct CursorSample: Equatable {
    public var t: Double
    public var p: Point
    /// The pointer was placed here by a declared click rather than moved by the system.
    public var placed = false
    public init(t: Double, p: Point, placed: Bool = false) { self.t = t; self.p = p; self.placed = placed }
}

public struct Click: Equatable {
    public var t: Double
    public var p: Point
    public var button: Int
    public init(t: Double, p: Point, button: Int = 0) { self.t = t; self.p = p; self.button = button }
}

public struct TimedMark {
    public var t: Double
    public var mark: Mark
    public init(t: Double, mark: Mark) { self.t = t; self.mark = mark }
}

/// A moment at which part of the picture changed.
public struct Change: Equatable {
    public var t: Double
    /// Share of the picture that changed, 0 to 1.
    public var share: Double
    /// Box around everything that changed.
    public var rect: Rect
    /// No bigger than a text caret, which blinks without anything happening.
    public var sliver: Bool
    public init(t: Double, share: Double, rect: Rect, sliver: Bool = false) {
        self.t = t; self.share = share; self.rect = rect; self.sliver = sliver
    }
}

/// Where the pointer of the finished video comes from.
public enum PointerSource: String {
    /// The system pointer, unless clicks were declared and the system saw none in the picture.
    case auto
    /// Only the declared clicks: the pointer of an agent that works without touching the mouse.
    case declared
    /// The system pointer as recorded, with declared clicks placed on its path.
    case system
}

/// Everything known about a recording besides its pixels, on one clock. Times start at the
/// first frame; positions are normalized to the capture area.
public struct Timeline {
    public var duration: Double
    public var cursor: [CursorSample] = []
    public var clicks: [Click] = []
    public var releases: [Double] = []
    public var keys: [Double] = []
    public var scrolls: [Double] = []
    public var shapes: [(t: Double, id: String)] = []
    public var marks: [TimedMark] = []
    public var frameTimes: [Double] = []
    /// Nil for a recording that did not note its changes.
    public var changes: [Change]?

    public init(duration: Double) { self.duration = duration }

    /// Builds the timeline of a finished session from its event files.
    public init(info: SessionInfo, input: [InputEvent], marks: [Mark], frameTimes: [Double], changes: [ChangeEvent]? = nil) {
        let start = info.startHost ?? 0
        let clock = RecordingClock(start: start, pauses: info.pauses)
        let duration = info.duration ?? max(frameTimes.last ?? 0, 0)
        self.duration = duration
        self.frameTimes = frameTimes

        var lastPosition: Point?
        var lastShape: String?
        for event in input {
            // The shape and position in force when the recording began still apply.
            if event.u < start {
                if event.k == "m", let x = event.x, let y = event.y { lastPosition = Point(x: x, y: y) }
                if event.k == "c" { lastShape = event.c }
                continue
            }
            guard let t = clock.time(event.u), t <= duration + 0.05 else { continue }
            if cursor.isEmpty, let lastPosition { cursor.append(CursorSample(t: 0, p: lastPosition)) }
            if shapes.isEmpty, let lastShape { shapes.append((0, lastShape)) }
            switch event.k {
            case "m":
                if let x = event.x, let y = event.y { cursor.append(CursorSample(t: t, p: Point(x: x, y: y))) }
            case "d":
                // A click beside the picture, or on another application's window in front of
                // it, belongs to somebody else's work.
                if let x = event.x, let y = event.y, event.f != 0, (0...1).contains(x), (0...1).contains(y) {
                    clicks.append(Click(t: t, p: Point(x: x, y: y), button: event.b ?? 0))
                }
            case "u": releases.append(t)
            case "k": if event.f != 0 { keys.append(t) }
            case "s": if event.f != 0 { scrolls.append(t) }
            case "c": if let id = event.c { shapes.append((t, id)) }
            default: break
            }
        }
        if cursor.isEmpty, let lastPosition { cursor.append(CursorSample(t: 0, p: lastPosition)) }
        if shapes.isEmpty, let lastShape { shapes.append((0, lastShape)) }

        for mark in marks {
            let t: Double?
            if let at = mark.t { t = at } else { t = clock.time(mark.u) }
            guard let t, t >= -0.05, t <= duration + 0.05 else { continue }
            self.marks.append(TimedMark(t: min(max(t, 0), duration), mark: mark))
        }
        self.marks.sort { $0.t < $1.t }

        if let changes {
            self.changes = changes.compactMap { event in
                guard let t = clock.time(event.u), t <= duration + 0.05 else { return nil }
                return Change(t: t, share: event.n, rect: Rect(x: event.x, y: event.y, w: event.w, h: event.h), sliver: event.s == 1)
            }
        }
    }

    /// Settles where the pointer comes from.
    public func pointerSource(_ wanted: PointerSource) -> PointerSource {
        guard wanted == .auto else { return wanted }
        let declared = marks.contains { $0.mark.kind == "click" && $0.mark.x != nil && $0.mark.y != nil }
        return declared && !clicks.contains { $0.button == 0 } ? .declared : .system
    }

    /// The timeline without anything the system input reported. An agent that declares its
    /// clicks works without the mouse and keyboard; what they do meanwhile is the business of
    /// whoever else is at the machine.
    public func declaredOnly() -> Timeline {
        var out = self
        out.cursor = []
        out.clicks = []
        out.releases = []
        out.keys = []
        out.scrolls = []
        out.shapes = []
        return out
    }
}

/// Converts host time to recording time, skipping what was paused.
public struct RecordingClock {
    public let start: Double
    public let pauses: [Interval]

    public init(start: Double, pauses: [Interval]) {
        self.start = start
        self.pauses = pauses.sorted { $0.start < $1.start }
    }

    /// Nil for moments before the first frame or inside a pause.
    public func time(_ host: Double) -> Double? {
        guard host >= start else { return nil }
        var skipped = 0.0
        for pause in pauses {
            if host >= pause.end {
                skipped += pause.length
            } else if host > pause.start {
                return nil
            } else {
                break
            }
        }
        return host - start - skipped
    }
}

/// A stretch of time played at `rate` times the pace it was recorded at.
public struct Pace: Codable, Equatable {
    public var start: Double, end: Double
    public var rate: Double
    public init(start: Double, end: Double, rate: Double) { self.start = start; self.end = end; self.rate = rate }
}

/// Maps recording time to the time of the finished video, which leaves out stretches
/// where nothing at all happens and hurries through the ones it was asked to.
public struct TimeMap {
    /// Stretches of the recording that are kept, in order.
    public let kept: [Interval]
    /// How many times faster than recorded each of them plays.
    public let rates: [Double]

    public init(kept: [Interval], rates: [Double]? = nil) {
        self.kept = kept
        self.rates = rates ?? Array(repeating: 1, count: kept.count)
    }

    public static func identity(duration: Double) -> TimeMap {
        TimeMap(kept: [Interval(start: 0, end: duration)])
    }

    /// Cuts the middle out of every quiet gap longer than `idleMax`, keeping half of the
    /// allowance on each side so the cut lands between a result and the next action.
    public static func trimmingIdle(duration: Double, activity: [Double], idleMax: Double) -> TimeMap {
        guard duration > 0, idleMax > 0 else { return identity(duration: duration) }
        let moments = ([0] + activity.filter { $0 > 0 && $0 < duration } + [duration]).sorted()
        var kept: [Interval] = []
        var segmentStart = 0.0
        // A cut that saves next to nothing is not worth the seam.
        for (a, b) in zip(moments, moments.dropFirst()) where b - a > idleMax + 0.5 {
            kept.append(Interval(start: segmentStart, end: a + idleMax / 2))
            segmentStart = b - idleMax / 2
        }
        kept.append(Interval(start: segmentStart, end: duration))
        return TimeMap(kept: kept)
    }

    /// The same map with the given stretches of the recording played at their own rate.
    public func paced(_ paces: [Pace]) -> TimeMap {
        guard !paces.isEmpty else { return self }
        var pieces: [Interval] = []
        var rates: [Double] = []
        for interval in kept {
            var edges = [interval.start, interval.end]
            for pace in paces {
                edges += [pace.start, pace.end].filter { $0 > interval.start && $0 < interval.end }
            }
            edges.sort()
            for (a, b) in zip(edges, edges.dropFirst()) where b - a > 1e-9 {
                let middle = (a + b) / 2
                pieces.append(Interval(start: a, end: b))
                rates.append(paces.last { middle >= $0.start && middle < $0.end }?.rate ?? 1)
            }
        }
        return TimeMap(kept: pieces, rates: rates)
    }

    public var outputDuration: Double { zip(kept, rates).reduce(0) { $0 + $1.0.length / $1.1 } }

    /// The moment of the finished video that shows recording time `t`; a time inside a cut
    /// lands on the cut itself.
    public func output(_ t: Double) -> Double {
        var elapsed = 0.0
        for (interval, rate) in zip(kept, rates) {
            if t <= interval.start { return elapsed }
            if t < interval.end { return elapsed + (t - interval.start) / rate }
            elapsed += interval.length / rate
        }
        return elapsed
    }

    public func source(_ out: Double) -> Double {
        var remaining = max(out, 0)
        for (interval, rate) in zip(kept, rates) {
            let length = interval.length / rate
            if remaining < length { return interval.start + remaining * rate }
            remaining -= length
        }
        return kept.last?.end ?? 0
    }

    /// Recording time removed in total.
    public var removed: Double {
        guard let first = kept.first, let last = kept.last else { return 0 }
        return (last.end - first.start) - kept.reduce(0) { $0 + $1.length }
    }

    /// Stretches of the finished video that do not run at the recorded pace.
    public var fast: [Pace] {
        var out: [Pace] = []
        var elapsed = 0.0
        for (interval, rate) in zip(kept, rates) {
            let length = interval.length / rate
            if rate != 1 {
                if let last = out.last, last.rate == rate, elapsed - last.end < 1e-6 {
                    out[out.count - 1].end = elapsed + length
                } else {
                    out.append(Pace(start: elapsed, end: elapsed + length, rate: rate))
                }
            }
            elapsed += length
        }
        return out
    }
}

extension Timeline {
    /// Moments at which something visible or meaningful happens, for idle trimming.
    public func activity(markHold: Double) -> [Double] {
        var moments = clicks.map(\.t) + keys + scrolls
        if let changes {
            moments += changes.filter { !$0.sliver }.map(\.t)
        } else {
            // Without the changes, every frame counts; frames arrive whether or not the
            // picture moves, so such a recording keeps its own pace.
            moments += frameTimes
        }
        var previous: Point?
        for sample in cursor {
            let inside = (0...1).contains(sample.p.x) && (0...1).contains(sample.p.y)
            if inside, let previous, abs(previous.x - sample.p.x) + abs(previous.y - sample.p.y) > 1e-5 { moments.append(sample.t) }
            previous = sample.p
        }
        // A declared focus is something to look at for as long as it holds, and words are
        // there for as long as reading them takes; the result of a click shows in the picture.
        for item in marks {
            let mark = item.mark
            var hold: Double?
            switch mark.kind {
            case "speed": continue
            case "click": hold = mark.hold
            case "keys": hold = mark.hold ?? Overlays.keysHold
            case "caption": hold = mark.hold ?? Overlays.readingTime(mark.text ?? "")
            default: hold = mark.hold ?? markHold
            }
            if mark.kind != "caption", mark.kind != "keys", let text = mark.text, !text.isEmpty {
                hold = max(hold ?? 0, Overlays.readingTime(text))
            }
            guard let hold else {
                moments.append(item.t)
                continue
            }
            var t = item.t
            while t <= item.t + hold {
                moments.append(t)
                t += 0.25
            }
        }
        return moments
    }

    /// The same timeline on the clock of the finished video.
    public func remapped(_ map: TimeMap) -> Timeline {
        var out = Timeline(duration: map.outputDuration)
        out.cursor = cursor.map { CursorSample(t: map.output($0.t), p: $0.p, placed: $0.placed) }
        out.clicks = clicks.map { Click(t: map.output($0.t), p: $0.p, button: $0.button) }
        out.releases = releases.map(map.output)
        out.keys = keys.map(map.output)
        out.scrolls = scrolls.map(map.output)
        out.shapes = shapes.map { (map.output($0.t), $0.id) }
        out.marks = marks.map { TimedMark(t: map.output($0.t), mark: $0.mark) }
        out.frameTimes = frameTimes.map(map.output)
        out.changes = changes?.map { Change(t: map.output($0.t), share: $0.share, rect: $0.rect, sliver: $0.sliver) }
        return out
    }
}

extension Timeline {
    /// Stretches the operator asked to be played at another pace, in the timeline's own time:
    /// each speed mark holds until the next one.
    public var paces: [Pace] {
        let speeds = marks.filter { $0.mark.kind == "speed" }.sorted { $0.t < $1.t }
        var out: [Pace] = []
        for (index, item) in speeds.enumerated() {
            let rate = min(max(item.mark.rate ?? 1, 0.25), 32)
            let end = index + 1 < speeds.count ? speeds[index + 1].t : duration
            if rate != 1, end > item.t { out.append(Pace(start: item.t, end: end, rate: rate)) }
        }
        return out
    }

    /// Moves each declared click, typing mark and shortcut to the moment the picture answers it. An
    /// agent declares an action and only then carries it out, often seconds later while it
    /// thinks; shown as declared, the pointer would click and nothing would follow.
    /// - Parameter window: how long after a mark its answer is looked for.
    public func syncedToResponses(window: Double = 12) -> Timeline {
        var out = self
        let actions = marks.indices.filter { ["click", "type", "keys"].contains(marks[$0].mark.kind) }
        let moves = (changes ?? []).filter { !$0.sliver }
        for (order, index) in actions.enumerated() {
            let item = marks[index]
            // A mark placed at a chosen time afterwards stays where it was put.
            guard item.mark.t == nil else { continue }
            var limit = item.t + window
            if order + 1 < actions.count { limit = min(limit, marks[actions[order + 1]].t - 0.05) }

            // The click itself, when the agent works with the real pointer.
            if item.mark.kind == "click", let x = item.mark.x, let y = item.mark.y,
               let real = clicks.first(where: { $0.button == 0 && $0.t >= item.t - 0.05 && $0.t <= limit
                   && hypot($0.p.x - x, $0.p.y - y) < 0.08 }) {
                out.marks[index].t = real.t
                continue
            }
            // Or the keys themselves.
            if item.mark.kind == "keys", let real = keys.first(where: { $0 >= item.t - 0.05 && $0 <= limit }) {
                out.marks[index].t = real
                continue
            }
            // Otherwise the first thing that changes; one that follows at once needs no moving.
            guard let answer = moves.first(where: { $0.t >= item.t - 0.05 }), answer.t <= limit, answer.t - item.t > 0.3 else { continue }
            out.marks[index].t = answer.t - 0.12
        }
        out.marks.sort { $0.t < $1.t }
        return out
    }
}
