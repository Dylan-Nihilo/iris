import XCTest
@testable import IrisCore

final class ClockTests: XCTestCase {
    func testPausesAreLeftOutOfRecordingTime() {
        let clock = RecordingClock(start: 100, pauses: [Interval(start: 104, end: 110)])
        XCTAssertNil(clock.time(99))
        XCTAssertEqual(clock.time(103), 3)
        XCTAssertNil(clock.time(107))
        XCTAssertEqual(clock.time(111), 5)
    }

    func testQuietGapsAreCutInTheMiddle() {
        let map = TimeMap.trimmingIdle(duration: 20, activity: [1, 2, 12, 13], idleMax: 2)
        XCTAssertEqual(map.kept, [Interval(start: 0, end: 3), Interval(start: 11, end: 14), Interval(start: 19, end: 20)])
        XCTAssertEqual(map.outputDuration, 7, accuracy: 1e-9)
        XCTAssertEqual(map.removed, 13, accuracy: 1e-9)
    }

    func testAGapBarelyOverTheAllowanceIsKept() {
        let map = TimeMap.trimmingIdle(duration: 6, activity: [1, 3.3, 5.5], idleMax: 2)
        XCTAssertEqual(map.kept, [Interval(start: 0, end: 6)])
    }

    func testOutputAndSourceAgreeOutsideCuts() {
        let map = TimeMap(kept: [Interval(start: 0, end: 3), Interval(start: 11, end: 14)])
        XCTAssertEqual(map.output(12), 4)
        XCTAssertEqual(map.source(4), 12)
        // A moment inside a cut lands on the cut.
        XCTAssertEqual(map.output(7), 3)
        XCTAssertEqual(map.source(99), 14)
    }
}

final class TimelineTests: XCTestCase {
    private func info() -> SessionInfo {
        SessionInfo(name: "t", createdAt: Date(), target: TargetInfo(kind: "window", displayID: 1),
                    captureRect: Rect(x: 0, y: 0, w: 800, h: 600), scale: 2, pixelWidth: 1600, pixelHeight: 1200, fps: 60,
                    startHost: 10, endHost: 20, duration: 10)
    }

    func testInputForAnotherApplicationIsLeftOut() {
        let input = [
            InputEvent(u: 11, k: "d", x: 0.5, y: 0.5, b: 0),
            InputEvent(u: 12, k: "d", x: 0.4, y: 0.4, b: 0, f: 0),
            InputEvent(u: 13, k: "d", x: 1.4, y: 0.4, b: 0),
            InputEvent(u: 14, k: "k"),
            InputEvent(u: 15, k: "k", f: 0),
        ]
        let timeline = Timeline(info: info(), input: input, marks: [], frameTimes: [0, 10])
        XCTAssertEqual(timeline.clicks.map(\.t), [1])
        XCTAssertEqual(timeline.keys, [4])
    }

    func testThePointerFollowsDeclaredClicksWhenTheSystemSawNone() {
        let marks = [Mark(u: 12, kind: "click", x: 0.3, y: 0.3)]
        let quiet = Timeline(info: info(), input: [InputEvent(u: 11, k: "m", x: 0.9, y: 0.9)], marks: marks, frameTimes: [0, 10])
        XCTAssertEqual(quiet.pointerSource(.auto), .declared)
        XCTAssertEqual(quiet.pointerSource(.system), .system)
        XCTAssertTrue(quiet.declaredOnly().cursor.isEmpty)

        let real = Timeline(info: info(), input: [InputEvent(u: 12, k: "d", x: 0.3, y: 0.3, b: 0)], marks: marks, frameTimes: [0, 10])
        XCTAssertEqual(real.pointerSource(.auto), .system)
    }

    func testACaretBlinkIsNotActivity() {
        var timeline = Timeline(duration: 10)
        timeline.changes = [
            Change(t: 2, share: 0.0001, rect: Rect(x: 0.5, y: 0.5, w: 0.002, h: 0.02), sliver: true),
            Change(t: 6, share: 0.1, rect: Rect(x: 0.2, y: 0.2, w: 0.5, h: 0.5)),
        ]
        XCTAssertEqual(timeline.activity(markHold: 2.5), [6])
    }
}

final class SyncTests: XCTestCase {
    private let box = Rect(x: 0.2, y: 0.2, w: 0.3, h: 0.3)

    func testADeclaredClickWaitsForThePictureToAnswer() {
        var timeline = Timeline(duration: 30)
        timeline.marks = [
            TimedMark(t: 2, mark: Mark(u: 0, kind: "click", x: 0.3, y: 0.3)),
            TimedMark(t: 10, mark: Mark(u: 0, kind: "click", x: 0.6, y: 0.6)),
            TimedMark(t: 20, mark: Mark(u: 0, kind: "focus", x: 0.5, y: 0.5)),
        ]
        timeline.changes = [
            Change(t: 3, share: 0.0001, rect: box, sliver: true),
            Change(t: 5.5, share: 0.05, rect: box),
            Change(t: 10.1, share: 0.05, rect: box),
            Change(t: 24, share: 0.05, rect: box),
        ]
        let times = timeline.syncedToResponses().marks.map(\.t)
        XCTAssertEqual(times[0], 5.38, accuracy: 1e-9)   // the agent took 3.5 s to act
        XCTAssertEqual(times[1], 10)                     // answered at once
        XCTAssertEqual(times[2], 20)                     // a look, not an action
    }

    func testAnAnswerBelongsToTheActionBeforeIt() {
        var timeline = Timeline(duration: 30)
        timeline.marks = [
            TimedMark(t: 2, mark: Mark(u: 0, kind: "click", x: 0.3, y: 0.3)),
            TimedMark(t: 4, mark: Mark(u: 0, kind: "click", x: 0.6, y: 0.6)),
            TimedMark(t: 9, mark: Mark(u: 0, t: 9, kind: "click", x: 0.6, y: 0.6)),
        ]
        timeline.changes = [Change(t: 6, share: 0.05, rect: box), Change(t: 12, share: 0.05, rect: box)]
        let times = timeline.syncedToResponses().marks.map(\.t)
        XCTAssertEqual(times, [2, 5.88, 9])
    }

    func testADeclaredClickJoinsTheRealOne() {
        var timeline = Timeline(duration: 30)
        timeline.marks = [TimedMark(t: 2, mark: Mark(u: 0, kind: "click", x: 0.3, y: 0.3))]
        timeline.clicks = [Click(t: 3, p: Point(x: 0.9, y: 0.9)), Click(t: 4.2, p: Point(x: 0.31, y: 0.3))]
        timeline.changes = [Change(t: 3.1, share: 0.05, rect: box)]
        XCTAssertEqual(timeline.syncedToResponses().marks[0].t, 4.2)
    }
}

final class PlanTests: XCTestCase {
    private func timeline(_ marks: [(Double, Mark)], duration: Double = 30) -> Timeline {
        var timeline = Timeline(duration: duration)
        timeline.marks = marks.map { TimedMark(t: $0.0, mark: $0.1) }
        return timeline
    }

    func testClicksCloseInTimeShareOneZoom() {
        let plan = ZoomPlan(timeline: timeline([
            (2, Mark(u: 0, kind: "click", x: 0.2, y: 0.2)),
            (4, Mark(u: 0, kind: "click", x: 0.7, y: 0.6)),
            (20, Mark(u: 0, kind: "click", x: 0.5, y: 0.5)),
        ]), policy: ZoomPolicy())
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[0].keys.count, 2)
        XCTAssertEqual(plan.segments[0].start, 2 - ZoomPolicy().lead, accuracy: 1e-9)
        // Between zooms the camera is back at the full view.
        XCTAssertEqual(plan.target(at: 12).zoom, 1)
        XCTAssertEqual(plan.target(at: 4.5).center, Point(x: 0.7, y: 0.6))
    }

    func testARegionSetsItsOwnZoom() {
        let plan = ZoomPlan(timeline: timeline([(2, Mark(u: 0, kind: "focus", x: 0.5, y: 0.5, w: 0.4, h: 0.2))]), policy: ZoomPolicy())
        XCTAssertEqual(plan.segments[0].keys[0].zoom, 2.0, accuracy: 1e-9)
        let large = ZoomPlan(timeline: timeline([(2, Mark(u: 0, kind: "focus", x: 0.5, y: 0.5, w: 0.1, h: 0.05))]), policy: ZoomPolicy())
        XCTAssertEqual(large.segments[0].keys[0].zoom, ZoomPolicy().maxZoom)
    }

    func testALongFieldIsShownFromWhereItsTextBegins() {
        let mark = Mark(u: 0, kind: "type", x: 0.5, y: 0.3, w: 0.8, h: 0.05)
        let key = ZoomPlan(timeline: timeline([(2, mark)]), policy: ZoomPolicy()).segments[0].keys[0]
        XCTAssertEqual(key.zoom, 2.0, accuracy: 1e-9)
        // The field starts at 0.1; the view is half the picture wide and begins just left of it.
        XCTAssertEqual(key.center.x, 0.1 + 0.4 / 2.0, accuracy: 1e-9)
    }

    func testTypingNobodyDeclaredIsFollowedWhenItIsOutOfView() {
        // A click on a button at the top right; the text then goes into a field on the left.
        var typing = Timeline(duration: 12)
        typing.clicks = [Click(t: 2, p: Point(x: 0.9, y: 0.15))]
        typing.keys = (0..<15).map { 3 + Double($0) * 0.1 }
        typing.changes = typing.keys.enumerated().map { index, key in
            Change(t: key + 0.03, share: 0.0004, rect: Rect(x: 0.28 + Double(index) * 0.012, y: 0.24, w: 0.02, h: 0.03))
        }
        let plan = ZoomPlan(timeline: typing, policy: ZoomPolicy())
        XCTAssertEqual(plan.target(at: 2.2).center, Point(x: 0.9, y: 0.15))
        let later = plan.target(at: 4.4)
        XCTAssertEqual(later.key?.reason, "typing")
        XCTAssertLessThan(later.center.x, 0.5)
        XCTAssertEqual(later.center.y, 0.255, accuracy: 1e-9)

        // The same changes with no keys behind them are somebody else's business.
        var silent = typing
        silent.keys = []
        XCTAssertEqual(ZoomPlan(timeline: silent, policy: ZoomPolicy()).target(at: 3.5).center, Point(x: 0.9, y: 0.15))

        // Text that stays in view leaves the camera alone.
        var near = typing
        near.changes = typing.keys.map { Change(t: $0 + 0.03, share: 0.0004, rect: Rect(x: 0.85, y: 0.16, w: 0.02, h: 0.03)) }
        XCTAssertEqual(ZoomPlan(timeline: near, policy: ZoomPolicy()).segments[0].keys.count, 1)
    }

    func testAWideMarkKeepsTheCameraOut() {
        let plan = ZoomPlan(timeline: timeline([
            (2, Mark(u: 0, kind: "click", x: 0.2, y: 0.2)),
            (3, Mark(u: 0, kind: "wide", hold: 3)),
        ]), policy: ZoomPolicy())
        XCTAssertEqual(plan.target(at: 2.5).zoom, 2.0)
        XCTAssertEqual(plan.target(at: 4).zoom, 1)
    }

    func testNoZoomWhenSwitchedOff() {
        var policy = ZoomPolicy()
        policy.enabled = false
        XCTAssertTrue(ZoomPlan(timeline: timeline([(2, Mark(u: 0, kind: "click", x: 0.2, y: 0.2))]), policy: policy).segments.isEmpty)
    }
}

final class VisualFocusTests: XCTestCase {
    func testASmallBusyAreaIsZoomedOnAndALargeOneIsNot() {
        let small = (0..<10).map { Change(t: 2 + Double($0) * 0.1, share: 0.002, rect: Rect(x: 0.3, y: 0.3, w: 0.15, h: 0.05)) }
        let large = (0..<4).map { Change(t: 9 + Double($0) * 0.1, share: 0.3, rect: Rect(x: 0.05, y: 0.05, w: 0.9, h: 0.9)) }
        let marks = VisualFocus.marks(changes: small + large, policy: ZoomPolicy())
        XCTAssertEqual(marks.map(\.mark.kind), ["focus", "wide"])
        XCTAssertEqual(marks[0].mark.x ?? 0, 0.375, accuracy: 1e-9)
    }

    func testFlickersAreIgnored() {
        let blink = [Change(t: 2, share: 0.0001, rect: Rect(x: 0.5, y: 0.5, w: 0.002, h: 0.02), sliver: true),
                     Change(t: 5, share: 0.0002, rect: Rect(x: 0.5, y: 0.5, w: 0.02, h: 0.02))]
        XCTAssertTrue(VisualFocus.marks(changes: blink, policy: ZoomPolicy()).isEmpty)
    }
}

final class MotionTests: XCTestCase {
    func testTheDeclaredPointerRestsOnEachClick() {
        var timeline = Timeline(duration: 6)
        let clicks = [(2.0, Point(x: 0.2, y: 0.3)), (4.0, Point(x: 0.8, y: 0.7))]
        timeline.marks = clicks.map { TimedMark(t: $0.0, mark: Mark(u: 0, kind: "click", x: $0.1.x, y: $0.1.y)) }
        let track = CursorTrack(timeline: timeline, fps: 60, frames: 360, size: (800, 600), policy: MotionPolicy())
        XCTAssertEqual(track.states.count, 360)
        for (t, p) in clicks {
            let state = track.states[Int(t * 60)]
            XCTAssertEqual(state.position.x, p.x, accuracy: 0.004)
            XCTAssertEqual(state.position.y, p.y, accuracy: 0.004)
        }
        // On the way from one to the other it is somewhere in between, not jumping.
        let between = track.states[Int(3.6 * 60)].position.x
        XCTAssertGreaterThan(between, 0.25)
        XCTAssertLessThan(between, 0.75)
        // The button goes down with the click and comes back up.
        XCTAssertLessThan(track.states[Int(2.08 * 60)].press, 0.9)
        XCTAssertEqual(track.states[Int(3 * 60)].press, 1, accuracy: 0.01)
    }

    func testAPointerRestingOnADeclaredClickDoesNotCreepToItsNextStop() {
        // The real pointer clicks where the click was declared, rests, then hops a short way.
        var timeline = Timeline(duration: 6)
        timeline.marks = [TimedMark(t: 1, mark: Mark(u: 0, kind: "click", x: 0.5, y: 0.5))]
        timeline.clicks = [Click(t: 1, p: Point(x: 0.5, y: 0.5))]
        timeline.cursor = (0...9).map { CursorSample(t: Double($0) * 0.5, p: Point(x: 0.5, y: 0.5)) }
            + [CursorSample(t: 4.6, p: Point(x: 0.53, y: 0.55))]
        let track = CursorTrack(timeline: timeline, fps: 60, frames: 360, size: (800, 600), policy: MotionPolicy())
        XCTAssertEqual(track.states[Int(3.0 * 60)].position.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(track.states[Int(4.2 * 60)].position.y, 0.5, accuracy: 1e-4)
        XCTAssertEqual(track.states[Int(4.8 * 60)].position.y, 0.55, accuracy: 0.002)
    }

    func testTheCameraStaysInsideThePicture() {
        var timeline = Timeline(duration: 6)
        timeline.marks = [TimedMark(t: 1, mark: Mark(u: 0, kind: "click", x: 0.02, y: 0.98))]
        let plan = ZoomPlan(timeline: timeline, policy: ZoomPolicy())
        let cursor = CursorTrack(timeline: timeline, fps: 60, frames: 360, size: (800, 600), policy: MotionPolicy())
        let camera = CameraTrack(plan: plan, cursor: cursor, fps: 60, frames: 360, view: (1.1, 1.1), policy: MotionPolicy())
        XCTAssertEqual(camera.states.first, .wide)
        let peak = camera.states.max { $0.zoom < $1.zoom }!
        XCTAssertEqual(peak.zoom, 2.0, accuracy: 0.05)
        for state in camera.states {
            XCTAssertEqual(state, state.clamped())
        }
        XCTAssertEqual(camera.states.last!.zoom, 1, accuracy: 0.02)
    }
}

final class PaceTests: XCTestCase {
    func testAFastStretchTakesLessOfTheVideo() {
        let map = TimeMap.identity(duration: 10).paced([Pace(start: 2, end: 6, rate: 4)])
        XCTAssertEqual(map.outputDuration, 7, accuracy: 1e-9)
        XCTAssertEqual(map.output(4), 2.5, accuracy: 1e-9)
        XCTAssertEqual(map.source(2.5), 4, accuracy: 1e-9)
        XCTAssertEqual(map.output(8), 5, accuracy: 1e-9)
        XCTAssertEqual(map.fast, [Pace(start: 2, end: 3, rate: 4)])
        XCTAssertEqual(map.removed, 0, accuracy: 1e-9)
    }

    func testAFastStretchRunsOnAcrossACut() {
        let map = TimeMap(kept: [Interval(start: 0, end: 3), Interval(start: 11, end: 14)]).paced([Pace(start: 2, end: 12, rate: 2)])
        XCTAssertEqual(map.outputDuration, 5, accuracy: 1e-9)
        XCTAssertEqual(map.removed, 8, accuracy: 1e-9)
        XCTAssertEqual(map.fast.count, 1)
        XCTAssertEqual(map.fast[0].start, 2, accuracy: 1e-9)
        XCTAssertEqual(map.fast[0].end, 3, accuracy: 1e-9)
        // Every moment of the video still shows a moment that was kept.
        XCTAssertEqual(map.source(2.75), 11.5, accuracy: 1e-9)
    }

    func testASpeedMarkHoldsUntilTheNextOne() {
        var timeline = Timeline(duration: 10)
        timeline.marks = [
            TimedMark(t: 2, mark: Mark(u: 0, kind: "speed", rate: 4)),
            TimedMark(t: 6, mark: Mark(u: 0, kind: "speed", rate: 1)),
            TimedMark(t: 8, mark: Mark(u: 0, kind: "speed", rate: 2)),
        ]
        XCTAssertEqual(timeline.paces, [Pace(start: 2, end: 6, rate: 4), Pace(start: 8, end: 10, rate: 2)])
        // A change of pace is not something to look at, and nothing to zoom on.
        XCTAssertTrue(timeline.activity(markHold: 2.5).isEmpty)
        XCTAssertTrue(ZoomPlan(timeline: timeline, policy: ZoomPolicy()).segments.isEmpty)
    }
}

final class OverlayTests: XCTestCase {
    private func timeline(_ marks: [(Double, Mark)]) -> Timeline {
        var timeline = Timeline(duration: 30)
        timeline.marks = marks.map { TimedMark(t: $0.0, mark: $0.1) }
        return timeline
    }

    func testACaptionGivesWayToTheNextAndAnEmptyOneClears() {
        let overlays = Overlays.build(timeline: timeline([
            (1, Mark(u: 0, kind: "caption", hold: 10, text: "First")),
            (3, Mark(u: 0, kind: "caption", hold: 10, text: "Second")),
            (5, Mark(u: 0, kind: "caption", text: "")),
        ]), lead: 0.7)
        XCTAssertEqual(overlays, [Overlay(kind: "caption", text: "First", start: 1, end: 3),
                                  Overlay(kind: "caption", text: "Second", start: 3, end: 5)])
        XCTAssertEqual(overlays[0].presence(at: 2), 1)
        XCTAssertEqual(overlays[0].presence(at: 3.5), 0)
        XCTAssertEqual(overlays[0].presence(at: 1.11), 0.5, accuracy: 1e-6)
    }

    func testWordsAboutAnActionArriveWithTheCamera() {
        let overlays = Overlays.build(timeline: timeline([
            (4, Mark(u: 0, kind: "click", x: 0.3, y: 0.3, text: "Open the settings")),
        ]), lead: 0.7)
        XCTAssertEqual(overlays.count, 1)
        XCTAssertEqual(overlays[0].start, 3.3, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(overlays[0].end, 5)
        // The words cost the camera nothing: the click is still what it looks at.
        let plan = ZoomPlan(timeline: timeline([(4, Mark(u: 0, kind: "caption", text: "Just words"))]), policy: ZoomPolicy())
        XCTAssertTrue(plan.segments.isEmpty)
    }

    func testReadingTimeGrowsWithTheLineAndIsLongerForWideCharacters() {
        XCTAssertEqual(Overlays.readingTime("Hi"), 1.8)
        XCTAssertGreaterThan(Overlays.readingTime("Open the settings and choose a model"), 2.5)
        XCTAssertGreaterThan(Overlays.readingTime("打开设置并选择模型"), Overlays.readingTime("Open sets"))
        XCTAssertEqual(Overlays.readingTime(String(repeating: "word ", count: 80)), 7)
    }

    func testACaptionIsKeptThroughAStillPicture() {
        // Nothing moves for twenty seconds, but the caption needs its reading time.
        let quiet = timeline([(5, Mark(u: 0, kind: "caption", text: "A line that takes a while to read, all in all"))])
        let reading = Overlays.readingTime(quiet.marks[0].mark.text!)
        let map = TimeMap.trimmingIdle(duration: 30, activity: quiet.activity(markHold: 2.5), idleMax: 1.5)
        XCTAssertGreaterThanOrEqual(map.output(5 + reading) - map.output(5), reading - 0.25)
        XCTAssertLessThan(map.outputDuration, 30)
    }

    func testShortcutsAreWrittenTheWayTheSystemWritesThem() {
        XCTAssertEqual(Overlays.keycaps("cmd+shift+p"), ["⇧", "⌘", "P"])
        XCTAssertEqual(Overlays.keycaps("Control+ArrowDown"), ["⌃", "↓"])
        XCTAssertEqual(Overlays.keycaps("Meta+Enter"), ["⌘", "↩"])
        XCTAssertEqual(Overlays.keycaps("esc"), ["esc"])
        XCTAssertEqual(Overlays.keycaps("cmd++"), ["⌘", "+"])
        XCTAssertEqual(Overlays.keycaps("f5"), ["F5"])
        XCTAssertTrue(Overlays.keycaps("  ").isEmpty)
    }

    func testAShortcutSitsOnItsKeyOrOnThePictureAnswer() {
        var typed = Timeline(duration: 30)
        typed.marks = [TimedMark(t: 2, mark: Mark(u: 0, kind: "keys", text: "cmd+k"))]
        typed.keys = [4.5]
        typed.changes = [Change(t: 3, share: 0.05, rect: Rect(x: 0.2, y: 0.2, w: 0.3, h: 0.3))]
        XCTAssertEqual(typed.syncedToResponses().marks[0].t, 4.5)

        var scripted = typed
        scripted.keys = []
        XCTAssertEqual(scripted.syncedToResponses().marks[0].t, 2.88, accuracy: 1e-9)
        let overlays = Overlays.build(timeline: scripted.syncedToResponses(), lead: 0.7)
        XCTAssertEqual(overlays.map(\.kind), ["keys"])
        XCTAssertEqual(overlays[0].end - overlays[0].start, Overlays.keysHold, accuracy: 1e-9)
    }
}

final class GuideTests: XCTestCase {
    /// The skill file agents load is the guide the binary prints; `Scripts/install.sh
    /// --skill-file` rewrites it after the guide changes.
    func testTheSkillFileCarriesTheGuide() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let skill = try String(contentsOf: root.appendingPathComponent("skills/iris-recording/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(skill.hasPrefix("---\nname: iris-recording\n"))
        XCTAssertTrue(skill.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix(Guide.text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
