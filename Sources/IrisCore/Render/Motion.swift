import Foundation

/// A critically damped spring: it reaches its target as fast as possible without overshoot.
/// `omega` sets the pace; the value settles in roughly 6 / omega seconds.
struct Spring {
    var value: Double
    var velocity = 0.0

    mutating func step(to target: Double, omega: Double, dt: Double) {
        let offset = value - target
        let decay = exp(-omega * dt)
        let carry = (velocity + omega * offset) * dt
        value = target + (offset + carry) * decay
        velocity = (velocity - omega * carry) * decay
    }
}

public struct CursorState {
    public var position: Point
    /// 1 at rest, smaller while a button is held.
    public var press: Double
    public var shape: String?
}

public struct MotionPolicy {
    /// Pace of the camera; lower is slower and calmer.
    public var cameraOmega = 5.5
    /// Pace of the pointer smoothing.
    public var cursorOmega = 38.0
    /// A pointer jump longer than this many points within one sample is a teleport,
    /// the mark of an agent; it is replaced by a glide.
    public var teleportDistance = 60.0
    /// Out of a rest, a jump of this many points is already one.
    public var hopDistance = 12.0
    /// While zoomed, the pointer may roam this share of the view before the camera follows.
    public var followBox = 0.72
    public init() {}
}

/// The pointer of the finished video: the recorded path with jumps turned into glides,
/// declared clicks placed on it, and jitter smoothed away.
public struct CursorTrack {
    public let fps: Double
    public private(set) var states: [CursorState] = []

    struct Key {
        var t: Double
        var p: Point
        var glide = 0.0
        /// How long before `t` a glide is over, so the pointer is at rest when it clicks.
        var settle = 0.0
    }

    public init(timeline: Timeline, fps: Double, frames: Int, size: (w: Double, h: Double), policy: MotionPolicy) {
        self.fps = fps
        let keys = Self.keys(timeline: timeline, size: size, policy: policy)
        guard !keys.isEmpty else { return }

        // Moments a button goes down, from the system and from declared clicks.
        var presses = timeline.clicks.map(\.t)
        presses += timeline.marks.filter { $0.mark.kind == "click" }.map(\.t)
        presses.sort()

        var sx = Spring(value: keys[0].p.x), sy = Spring(value: keys[0].p.y)
        var press = Spring(value: 1)
        var index = 0
        var shapeIndex = 0
        let dt = 1 / fps
        let substeps = 4
        states.reserveCapacity(frames)
        for frame in 0..<frames {
            let t = Double(frame) * dt
            for step in 1...substeps {
                let ts = t - dt + dt * Double(step) / Double(substeps)
                while index + 1 < keys.count && keys[index + 1].t <= ts { index += 1 }
                let target = Self.position(keys: keys, index: index, t: ts)
                sx.step(to: target.x, omega: policy.cursorOmega, dt: dt / Double(substeps))
                sy.step(to: target.y, omega: policy.cursorOmega, dt: dt / Double(substeps))
                let held = presses.contains { ts >= $0 && ts < $0 + 0.13 }
                press.step(to: held ? 0.8 : 1, omega: 42, dt: dt / Double(substeps))
            }
            while shapeIndex + 1 < timeline.shapes.count && timeline.shapes[shapeIndex + 1].t <= t { shapeIndex += 1 }
            let shape = timeline.shapes.isEmpty ? nil : timeline.shapes[shapeIndex].id
            states.append(CursorState(position: Point(x: sx.value, y: sy.value), press: press.value, shape: shape))
        }
    }

    /// The recorded samples with declared clicks merged in and every teleport given a glide.
    static func keys(timeline: Timeline, size: (w: Double, h: Double), policy: MotionPolicy) -> [Key] {
        // A declared click puts the pointer on its target; the real pointer, parked wherever
        // the agent left it, is ignored until it moves again.
        let placed = timeline.marks.filter { $0.mark.kind == "click" && $0.mark.x != nil && $0.mark.y != nil }
            .map { CursorSample(t: $0.t, p: Point(x: $0.mark.x!, y: $0.mark.y!), placed: true) }
        var merged: [CursorSample] = []
        var placedIndex = 0
        var parkedAt: Point?
        var parkedUntil: Double?
        var lastReal: Point?
        for sample in timeline.cursor {
            while placedIndex < placed.count && placed[placedIndex].t <= sample.t {
                merged.append(placed[placedIndex])
                parkedAt = lastReal ?? sample.p
                parkedUntil = nil
                placedIndex += 1
            }
            if let parked = parkedAt {
                let moved = hypot((sample.p.x - parked.x) * size.w, (sample.p.y - parked.y) * size.h)
                if moved < 2 { lastReal = sample.p; parkedUntil = sample.t; continue }
                parkedAt = nil
                // It stayed on the click until now; the move starts here, not back then.
                if let until = parkedUntil, let last = merged.last, until > last.t {
                    merged.append(CursorSample(t: until, p: last.p))
                }
            }
            merged.append(sample)
            lastReal = sample.p
        }
        merged.append(contentsOf: placed[placedIndex...])
        if timeline.cursor.isEmpty, let first = placed.first {
            // A pointer made of declared clicks alone waits somewhere calm for its first one.
            let rests = [Point(x: 0.5, y: 0.56), Point(x: 0.3, y: 0.7)]
            let rest = rests.first { hypot($0.x - first.p.x, $0.y - first.p.y) > 0.18 } ?? rests[0]
            merged.insert(CursorSample(t: 0, p: rest), at: 0)
        }
        guard var previous = merged.first else { return [] }

        var keys = [Key(t: 0, p: previous.p)]
        for sample in merged.dropFirst() {
            let distance = hypot((sample.p.x - previous.p.x) * size.w, (sample.p.y - previous.p.y) * size.h)
            let dt = sample.t - previous.t
            if distance < 0.01 && !sample.placed { previous.t = sample.t; continue }
            var key = Key(t: sample.t, p: sample.p)
            // A hand leaving a rest starts slowly; a pointer that is somewhere else all at
            // once was put there, however short the hop.
            let teleport = sample.placed || (distance > policy.teleportDistance && distance / max(dt, 0.001) > 4000)
                || (distance > policy.hopDistance && dt > 0.03)
            if teleport {
                // Longer trips take longer, within the range a hand would.
                key.glide = min(max(0.22 + distance / 2600, 0.28), 0.75)
                if sample.placed { key.settle = 0.12 }
            } else if let last = keys.last, previous.t > last.t + 1e-6 {
                // The pointer rested at the previous spot until this move began.
                keys.append(Key(t: previous.t, p: previous.p))
            }
            keys.append(key)
            previous = sample
        }
        return keys
    }

    static func position(keys: [Key], index: Int, t: Double) -> Point {
        let a = keys[index]
        guard index + 1 < keys.count else { return a.p }
        let b = keys[index + 1]
        if b.glide > 0 {
            let end = max(b.t - b.settle, (a.t + b.t) / 2)
            let start = max(end - b.glide, a.t)
            guard t > start, end > start else { return a.p }
            let u = min((t - start) / (end - start), 1)
            // Minimum jerk: the velocity profile of a relaxed reach.
            let e = u * u * u * (10 - 15 * u + 6 * u * u)
            return Point(x: a.p.x + (b.p.x - a.p.x) * e, y: a.p.y + (b.p.y - a.p.y) * e)
        }
        let span = b.t - a.t
        guard span > 0 else { return b.p }
        let u = min(max((t - a.t) / span, 0), 1)
        return Point(x: a.p.x + (b.p.x - a.p.x) * u, y: a.p.y + (b.p.y - a.p.y) * u)
    }
}

public struct Camera: Equatable {
    public var center: Point
    public var zoom: Double

    public static let wide = Camera(center: .center, zoom: 1)

    /// Keeps the view from showing more backdrop than the full view does.
    public func clamped() -> Camera {
        let z = max(zoom, 1)
        let lo = 0.5 / z
        return Camera(center: Point(x: min(max(center.x, lo), 1 - lo), y: min(max(center.y, lo), 1 - lo)), zoom: z)
    }
}

/// The camera of the finished video, one state per frame.
public struct CameraTrack {
    public private(set) var states: [Camera] = []

    /// `view` is how much wider and taller the canvas is than the recording at full view.
    public init(plan: ZoomPlan, cursor: CursorTrack, fps: Double, frames: Int, view: (x: Double, y: Double), policy: MotionPolicy) {
        var cx = Spring(value: 0.5), cy = Spring(value: 0.5), zoom = Spring(value: 1)
        var followed: Point?
        var activeKey: FocusKey?
        let dt = 1 / fps
        let substeps = 4
        states.reserveCapacity(frames)
        for frame in 0..<frames {
            let t = Double(frame) * dt
            var target = plan.target(at: t)
            if let key = target.key {
                if key != activeKey {
                    activeKey = key
                    followed = key.center
                }
                // Once the action has happened, a pointer that wanders to the edge of the
                // view pulls the camera along instead of leaving the picture.
                if t > key.at + 0.3, frame < cursor.states.count, var center = followed {
                    let p = cursor.states[frame].position
                    if (0...1).contains(p.x), (0...1).contains(p.y), Self.pointerMoved(cursor, since: key.at, fps: fps, frame: frame) {
                        let hx = view.x / (2 * key.zoom) * policy.followBox
                        let hy = view.y / (2 * key.zoom) * policy.followBox
                        center.x = min(max(center.x, p.x - hx), p.x + hx)
                        center.y = min(max(center.y, p.y - hy), p.y + hy)
                        followed = center
                    }
                }
                target.center = followed ?? key.center
            } else {
                activeKey = nil
                followed = nil
            }
            let goal = Camera(center: target.center, zoom: target.zoom).clamped()
            for _ in 0..<substeps {
                cx.step(to: goal.center.x, omega: policy.cameraOmega, dt: dt / Double(substeps))
                cy.step(to: goal.center.y, omega: policy.cameraOmega, dt: dt / Double(substeps))
                zoom.step(to: goal.zoom, omega: policy.cameraOmega, dt: dt / Double(substeps))
            }
            states.append(Camera(center: Point(x: cx.value, y: cy.value), zoom: zoom.value).clamped())
        }
    }

    static func pointerMoved(_ cursor: CursorTrack, since time: Double, fps: Double, frame: Int) -> Bool {
        let first = min(max(Int((time + 0.3) * fps), 0), frame)
        let a = cursor.states[first].position, b = cursor.states[frame].position
        return abs(a.x - b.x) + abs(a.y - b.y) > 0.004
    }
}
