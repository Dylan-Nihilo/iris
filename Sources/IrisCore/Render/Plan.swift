import Foundation
import CoreGraphics

/// How eagerly and how far the camera moves in on an action. These numbers are the taste
/// of the tool; every one of them is in seconds or in magnification.
public struct ZoomPolicy {
    public var enabled = true
    /// Magnification for an ordinary click.
    public var zoom = 2.0
    /// The camera sets off this long before the action, so it has arrived when it happens.
    public var lead = 0.7
    /// How long the camera stays after a click, a declared focus, and the last keystroke.
    public var clickHold = 2.0
    public var focusHold = 2.5
    public var typeHold = 1.4
    /// A return to the full view shorter than this is skipped; the camera pans instead.
    public var mergeGap = 1.8
    /// A declared region is fitted to this share of the view.
    public var regionFill = 0.8
    public var maxZoom = 3.5
    public init() {}
}

/// One place the camera looks at, from `t` until the next key or the end of its segment.
public struct FocusKey: Codable, Equatable {
    public var t: Double
    public var center: Point
    public var zoom: Double
    /// When the action itself happens; the camera leaves for it at `t`.
    public var at: Double
    public var reason: String
}

/// A stretch of the video spent zoomed in.
public struct ZoomSegment: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var keys: [FocusKey]
}

public struct ZoomPlan: Codable, Equatable {
    public var segments: [ZoomSegment]

    public init(segments: [ZoomSegment]) { self.segments = segments }

    struct Event {
        var t: Double
        var center: Point
        var zoom: Double
        var end: Double
        var reason: String
        /// The field a typing focus was declared for, when it is wider than the view.
        var field: Rect?
    }

    public init(timeline: Timeline, policy: ZoomPolicy) {
        guard policy.enabled else { self.segments = []; return }
        let duration = timeline.duration

        let wide: [Interval] = timeline.marks.filter { $0.mark.kind == "wide" }
            .map { Interval(start: $0.t, end: $0.t + ($0.mark.hold ?? 2.0)) }

        var events: [Event] = []
        let declared = timeline.marks.filter { $0.mark.kind != "wide" && $0.mark.x != nil && $0.mark.y != nil }
        for item in declared {
            let mark = item.mark
            var center = Point(x: mark.x!, y: mark.y!)
            var zoom = mark.zoom ?? policy.zoom
            var field: Rect?
            if let w = mark.w, let h = mark.h, w > 0, h > 0 {
                let fit = min(policy.regionFill / w, policy.regionFill / h)
                if mark.kind == "type" {
                    // Text is read at a comfortable size, however long the field it goes into.
                    if mark.zoom == nil { zoom = min(max(fit, policy.zoom), policy.zoom * 1.25) }
                    field = Rect(x: center.x - w / 2, y: center.y - h / 2, w: w, h: h)
                } else if mark.zoom == nil {
                    zoom = fit
                }
            }
            zoom = min(max(zoom, 1), policy.maxZoom)
            if let wide = field, wide.w * zoom > policy.regionFill {
                // The field does not fit: show where the text begins, not the empty middle.
                center.x = wide.x + 0.4 / zoom
            } else {
                field = nil
            }
            let hold = mark.hold ?? (mark.kind == "click" ? policy.clickHold : policy.focusHold)
            events.append(Event(t: item.t, center: center, zoom: zoom, end: item.t + hold, reason: mark.label ?? mark.kind, field: field))
        }
        for click in timeline.clicks where click.button == 0 {
            guard (0...1).contains(click.p.x), (0...1).contains(click.p.y) else { continue }
            // A declared click describes the same action better than the raw one beside it.
            let shadowed = declared.contains { abs($0.t - click.t) < 0.4 }
            if !shadowed {
                events.append(Event(t: click.t, center: click.p, zoom: policy.zoom, end: click.t + policy.clickHold, reason: "click"))
            }
        }
        events.sort { $0.t < $1.t }

        // Typing after an action keeps the camera where the text appears.
        for index in events.indices {
            let limit = index + 1 < events.count ? events[index + 1].t : Double.infinity
            for key in timeline.keys where key >= events[index].t && key < limit && key <= events[index].end + 0.4 {
                events[index].end = max(events[index].end, key + policy.typeHold)
            }
            events[index].end = min(events[index].end, limit + policy.clickHold)
        }

        // Text that runs out of the view takes the camera along, a stretch at a time.
        if let changes = timeline.changes {
            var following: [Event] = []
            for (index, event) in events.enumerated() {
                let limit = min(index + 1 < events.count ? events[index + 1].t : Double.infinity, event.end)
                let half = 0.5 / event.zoom
                guard let field = event.field else {
                    // Typing nobody declared: the keys say that text is going in, the picture
                    // says where. When that is out of view, the camera goes there.
                    let typed = timeline.keys.filter { $0 >= event.t && $0 < limit }
                    var center = event.center
                    var last = event.t
                    for change in changes where change.t > event.t && change.t < limit && !change.sliver && !typed.isEmpty {
                        let box = change.rect
                        // What a keystroke changes: a little of one line, right after the key.
                        guard box.h < 0.08, box.w < 0.5, typed.contains(where: { change.t > $0 - 0.02 && change.t < $0 + 0.25 }) else { continue }
                        let caret = Point(x: box.x + box.w, y: box.y + box.h / 2)
                        guard abs(caret.x - center.x) > half * 0.55 || abs(caret.y - center.y) > half * 0.55,
                              change.t - last > 0.35 else { continue }
                        center = Point(x: caret.x + half * 0.1, y: caret.y)
                        last = change.t
                        // The click is seen through before the camera leaves it.
                        following.append(Event(t: max(change.t, event.t + policy.lead + 0.25), center: center, zoom: event.zoom,
                                               end: event.end, reason: "typing"))
                    }
                    continue
                }
                var centerX = event.center.x
                var last = event.t
                for change in changes where change.t > event.t && change.t < limit && !change.sliver {
                    let box = change.rect
                    // What typing changes: something low and narrow on the line of the field.
                    guard box.y < field.y + field.h, box.y + box.h > field.y, box.h < max(field.h * 3, 0.08),
                          box.x > field.x - 0.02, box.x + box.w < field.x + field.w + 0.02 else { continue }
                    let caret = box.x + box.w
                    guard caret > centerX + half * 0.55, change.t - last > 0.35 else { continue }
                    centerX = caret + half * 0.1
                    last = change.t
                    following.append(Event(t: change.t, center: Point(x: centerX, y: event.center.y), zoom: event.zoom,
                                           end: event.end, reason: "typing"))
                }
            }
            if !following.isEmpty {
                events += following
                events.sort { $0.t < $1.t }
            }
        }

        // A request for the full view ends whatever zoom it meets and hides what falls inside it.
        events = events.compactMap { event in
            var event = event
            for interval in wide {
                if event.t >= interval.start && event.t < interval.end { return nil }
                if event.t < interval.start && event.end > interval.start { event.end = interval.start }
            }
            return event
        }

        var segments: [ZoomSegment] = []
        for event in events {
            let start = max(0, event.t - policy.lead)
            let key = FocusKey(t: start, center: event.center, zoom: event.zoom, at: event.t, reason: event.reason)
            let crossesWide = segments.last.map { last in wide.contains { $0.start >= last.end - 0.001 && $0.start <= event.t } } ?? false
            if var last = segments.last, start <= last.end + policy.mergeGap, !crossesWide {
                var key = key
                key.t = max(key.t, (last.keys.last?.t ?? last.start) + 0.05)
                last.keys.append(key)
                last.end = max(last.end, event.end)
                segments[segments.count - 1] = last
            } else {
                segments.append(ZoomSegment(start: start, end: event.end, keys: [key]))
            }
        }

        // Never end the video halfway through pulling back.
        for index in segments.indices {
            if segments[index].end > duration - 1.2 { segments[index].end = duration }
            segments[index].end = min(segments[index].end, duration)
        }
        self.segments = segments.filter { $0.end > $0.start }
    }

    /// Where the camera wants to be at `t`: the full view outside every segment.
    public func target(at t: Double) -> (center: Point, zoom: Double, key: FocusKey?) {
        for segment in segments where t >= segment.start && t < segment.end {
            guard let key = segment.keys.last(where: { $0.t <= t }) else { break }
            return (key.center, key.zoom, key)
        }
        return (.center, 1, nil)
    }
}

/// Stands in for declared focus in a recording that has none: where the picture changes is
/// where there is something to see. It knows nothing of intent, so it only moves in on a
/// change that stays in one part of the picture.
public enum VisualFocus {
    struct Burst {
        var start: Double
        var end: Double
        var box: CGRect
        var peak: Double
        var count = 1
    }

    public static func marks(changes: [Change], policy: ZoomPolicy) -> [TimedMark] {
        var bursts: [Burst] = []
        for change in changes where !change.sliver {
            if var last = bursts.last, change.t - last.end < 0.5 {
                last.end = change.t
                last.box = last.box.union(change.rect.cg)
                last.peak = max(last.peak, change.share)
                last.count += 1
                bursts[bursts.count - 1] = last
            } else {
                bursts.append(Burst(start: change.t, end: change.t, box: change.rect.cg, peak: change.share))
            }
        }

        var marks: [TimedMark] = []
        for burst in bursts {
            let box = burst.box
            let length = burst.end - burst.start
            // A flicker: a clock ticking over, a badge.
            if burst.count == 1 && burst.peak < 0.0005 { continue }
            // Something small that never stops is a spinner or a progress bar.
            if length > 8 && box.width * box.height < 0.01 { continue }
            let fit = min(policy.regionFill / max(box.width, 0.001), policy.regionFill / max(box.height, 0.001))
            if fit < 1.3 || box.width * box.height > 0.4 {
                marks.append(TimedMark(t: burst.start, mark: Mark(u: 0, kind: "wide", hold: length + 0.5, label: "change")))
            } else {
                marks.append(TimedMark(t: burst.start, mark: Mark(u: 0, kind: "focus", x: Double(box.midX), y: Double(box.midY),
                                                                 w: Double(box.width), h: Double(box.height),
                                                                 zoom: min(fit, policy.zoom), hold: length + policy.focusHold,
                                                                 label: "change")))
            }
        }
        return marks
    }
}
