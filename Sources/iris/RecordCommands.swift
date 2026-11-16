import Foundation
import AppKit
import IrisCore

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) { print(text) }
}

func targetRequest(_ args: inout Args) throws -> TargetRequest {
    var request = TargetRequest()
    if let id = try args.int("window-id") { request.windowID = UInt32(id) }
    request.app = args.string("app")
    request.title = args.string("title")
    request.display = try args.int("display")
    request.region = try args.rect("region")
    request.wholeScreen = args.flag("whole-screen")
    return request
}

func isAlive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

func windowsCommand(_ raw: [String]) async throws {
    let args = Args(raw)
    try args.finish()
    printJSON(try await Targets.windows())
}

struct StartReport: Encodable {
    var session: String
    var status: String
    var target: TargetInfo
    var captureRect: Rect
    var pixelWidth: Int
    var pixelHeight: Int
    var note: String?
}

func startCommand(_ raw: [String]) async throws {
    printJSON(try await startRecording(raw))
}

/// Starts the background recorder and returns once it is recording.
func startRecording(_ raw: [String]) async throws -> StartReport {
    var args = Args(raw, flags: ["whole-screen"])
    _ = try targetRequest(&args)
    let name = args.string("name") ?? "recording"
    let out = args.string("out")
    _ = try args.int("fps")
    _ = try args.double("max-duration")
    let wait = max(try args.double("wait") ?? 0, 0)
    try args.finish()
    guard args.positionals.isEmpty else {
        throw IrisError("unexpected \"\(args.positionals[0])\"; a target is given with --app, --title, --window-id or --display")
    }

    if let current = SessionStore.current(), let state = current.readState(),
       ["starting", "recording", "paused"].contains(state.status), isAlive(state.pid) {
        throw IrisError("a recording is already running in \(current.dir.path); run `iris stop` first")
    }

    let dir: URL
    if let out {
        dir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
    } else {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
        dir = SessionStore.defaultRoot.appendingPathComponent("\(stamp.string(from: Date()))-\(safe)")
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = SessionStore(dir: dir)
    for url in [store.stateURL, store.infoURL, store.marksURL, store.inputURL, store.maskURL] {
        try? FileManager.default.removeItem(at: url)
    }

    FileManager.default.createFile(atPath: store.logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: store.logURL)
    let process = Process()
    process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["_record", "--session", dir.path] + raw
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = log
    process.standardError = log
    try process.run()

    let deadline = Date().addingTimeInterval(20 + wait)
    while Date() < deadline {
        try await Task.sleep(nanoseconds: 100_000_000)
        if let state = store.readState() {
            if state.status == "recording", let info = try? store.readInfo() {
                SessionStore.setCurrent(dir)
                let note = info.target.capture == "window"
                    ? "the window is not on the visible desktop, so it is recorded by itself: menus and dialogs that open as separate windows will be missing, and an application that stops drawing while out of view will give a still picture"
                    : nil
                return StartReport(session: dir.path, status: "recording", target: info.target, captureRect: info.captureRect,
                                   pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight, note: note)
            }
            if state.status == "failed" { throw IrisError(state.error ?? "the recording failed to start") }
        }
        if !process.isRunning { break }
    }
    if process.isRunning { process.terminate() }
    let tail = (try? String(contentsOf: store.logURL, encoding: .utf8)) ?? ""
    throw IrisError("the recording did not start. \(tail.suffix(600))")
}

/// The hidden entry point of the background recorder.
@MainActor
func recordDaemonCommand(_ raw: [String]) throws -> Never {
    var args = Args(raw, flags: ["whole-screen"])
    guard let session = args.string("session") else { throw IrisError("missing --session") }
    let request = try targetRequest(&args)
    let name = args.string("name") ?? "recording"
    _ = args.string("out")
    let fps = min(max(try args.int("fps") ?? 60, 10), 120)
    let maxDuration = try args.double("max-duration") ?? 1800
    let wait = max(try args.double("wait") ?? 0, 0)
    RecorderDaemon.run(store: SessionStore(dir: URL(fileURLWithPath: session)), request: request,
                       name: name, fps: fps, maxDuration: maxDuration, wait: wait)
}

func runningRecorder(_ path: String?) throws -> (SessionStore, RecorderState) {
    let store = try SessionStore.resolve(path)
    guard let state = store.readState(), ["recording", "paused", "starting"].contains(state.status), isAlive(state.pid) else {
        throw IrisError("no recording is running in \(store.dir.path)")
    }
    return (store, state)
}

struct StatusReport: Encodable {
    var session: String
    var status: String
    var duration: Double
    var frames: Int
    var error: String?
}

func signalCommand(_ raw: [String], signal sig: Int32, expect: String) async throws {
    let args = Args(raw)
    try args.finish()
    let (store, state) = try runningRecorder(args.positionals.first)
    kill(state.pid, sig)
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
        if let now = store.readState(), now.status == expect {
            printJSON(StatusReport(session: store.dir.path, status: now.status, duration: now.duration, frames: now.frames, error: nil))
            return
        }
    }
    throw IrisError("the recorder did not answer")
}

/// Stops the running recording and waits until its files are complete.
func stopRecording(_ path: String?) async throws -> SessionStore {
    let (store, state) = try runningRecorder(path)
    kill(state.pid, SIGINT)
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        try await Task.sleep(nanoseconds: 100_000_000)
        guard let now = store.readState() else { continue }
        if now.status == "finished" { return store }
        if now.status == "failed" { throw IrisError(now.error ?? "the recording failed") }
        if !isAlive(state.pid) { break }
    }
    throw IrisError("the recorder exited without finishing the recording; see \(store.logURL.path)")
}

func statusCommand(_ raw: [String]) throws {
    let args = Args(raw)
    try args.finish()
    let store = try SessionStore.resolve(args.positionals.first)
    guard var state = store.readState() else { throw IrisError("the session has no recorder state") }
    if ["recording", "paused", "starting"].contains(state.status), !isAlive(state.pid) {
        state.status = "failed"
        state.error = "the recorder is no longer running"
    }
    printJSON(StatusReport(session: store.dir.path, status: state.status, duration: state.duration, frames: state.frames, error: state.error))
}

func markCommand(_ raw: [String]) throws {
    var args = Args(raw)
    let x = try args.double("x"), y = try args.double("y")
    let rect = try args.rect("rect")
    let space = args.string("space") ?? "screen"
    let ref = try args.numbers("ref", count: 2)
    let kind = args.string("kind") ?? (rect == nil ? "click" : "focus")
    let zoom = try args.double("zoom"), hold = try args.double("hold")
    let at = try args.double("at")
    let label = args.string("label")
    let caption = args.string("caption")
    let session = args.string("session")
    try args.finish()
    guard ["click", "focus", "type", "wide"].contains(kind) else {
        throw IrisError("--kind is one of click, focus, type, wide; words, shortcuts and pace have `iris caption`, `iris keys` and `iris speed`")
    }
    guard ["screen", "window", "norm"].contains(space) else {
        throw IrisError("--space is one of screen, window, norm")
    }
    let store = try SessionStore.resolve(session)
    let info = try store.readInfo()
    let area = info.captureRect

    // Bring a point from the caller's coordinate space into the capture area's 0...1 range.
    func normalize(_ px: Double, _ py: Double) -> (Double, Double) {
        var px = px, py = py
        switch space {
        case "norm":
            return (px, py)
        case "window":
            if let ref { px *= area.w / ref[0]; py *= area.h / ref[1] }
            return (px / area.w, py / area.h)
        default:
            if let ref {
                let display = CGDisplayBounds(info.target.displayID)
                px = display.minX + px * display.width / ref[0]
                py = display.minY + py * display.height / ref[1]
            }
            return ((px - area.x) / area.w, (py - area.y) / area.h)
        }
    }

    var mark = Mark(u: HostClock.now, t: at, kind: kind, zoom: zoom, hold: hold, label: label, text: caption)
    if let rect {
        let (x0, y0) = normalize(rect.minX, rect.minY)
        let (x1, y1) = normalize(rect.maxX, rect.maxY)
        mark.x = (x0 + x1) / 2; mark.y = (y0 + y1) / 2
        // A click on an element lands in its middle; its size says nothing about how close to look.
        if kind != "click" { mark.w = x1 - x0; mark.h = y1 - y0 }
    } else if let x, let y {
        (mark.x, mark.y) = normalize(x, y)
    } else if x != nil || y != nil {
        throw IrisError("give both --x and --y")
    } else if kind != "wide", let location = CGEvent(source: nil)?.location {
        mark.x = (location.x - area.x) / area.w
        mark.y = (location.y - area.y) / area.h
    }
    try store.appendMark(mark)
    printJSON(mark)
}

/// Reads what `caption`, `keys` and `speed` share, and appends the mark they make.
private func note(_ raw: [String], kind: String, _ make: (String, inout Mark) throws -> Void) throws {
    var args = Args(raw)
    let hold = try args.double("hold"), at = try args.double("at")
    let session = args.string("session")
    try args.finish()
    let store = try SessionStore.resolve(session)
    _ = try store.readInfo()
    var mark = Mark(u: HostClock.now, t: at, kind: kind, hold: hold)
    try make(args.positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), &mark)
    try store.appendMark(mark)
    printJSON(mark)
}

/// `iris caption TEXT`: words for the viewer, from now on; without text, clears them.
func captionCommand(_ raw: [String]) throws {
    try note(raw, kind: "caption") { text, mark in mark.text = text }
}

/// `iris keys cmd+k`: the shortcut about to be pressed.
func keysCommand(_ raw: [String]) throws {
    try note(raw, kind: "keys") { text, mark in
        guard !Overlays.keycaps(text).isEmpty else { throw IrisError("name the keys, like `iris keys cmd+shift+p`") }
        mark.text = text
    }
}

/// `iris speed 4`: from now on the video runs this many times faster; `iris speed 1` ends it.
func speedCommand(_ raw: [String]) throws {
    try note(raw, kind: "speed") { text, mark in
        let number = text.hasSuffix("x") || text.hasSuffix("×") ? String(text.dropLast()) : text
        guard let rate = Double(number), rate >= 0.25, rate <= 32 else {
            throw IrisError("give a pace between 0.25 and 32, like `iris speed 4`; `iris speed 1` returns to the recorded pace")
        }
        mark.rate = rate
    }
}

struct RunReport: Encodable {
    var session: String
    var command: [String]
    var exitStatus: Int32
    var duration: Double
    var frames: Int
    var warning: String?
}

/// `iris run [start options] [--render [render options]] -- command ...`: records while a
/// command runs. The recording is stopped whatever becomes of the command, and iris exits
/// with the command's status.
func runCommand(_ raw: [String]) async throws -> Int32 {
    guard let split = raw.firstIndex(of: "--"), split + 1 < raw.count else {
        throw IrisError("give the command after --, like `iris run --app Safari --render -- node demo.mjs`")
    }
    let command = Array(raw[(split + 1)...])
    let before = Array(raw[..<split])
    let renderIndex = before.firstIndex(of: "--render")
    let start = renderIndex.map { Array(before[..<$0]) } ?? before
    let report = try await startRecording(start)
    FileHandle.standardError.write(Data("recording \(report.session)\n".utf8))

    // An interrupt goes to the command as well; iris has to outlive it to close the recording.
    // A handler rather than SIG_IGN, which the command would inherit.
    signal(SIGINT) { _ in }
    signal(SIGTERM) { _ in }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    var environment = ProcessInfo.processInfo.environment
    environment["IRIS_SESSION"] = report.session
    process.environment = environment
    // The command's output is kept apart from the JSON on stdout.
    process.standardOutput = FileHandle.standardError
    var status: Int32 = 127
    var failure: Error?
    do {
        try process.run()
        // Waiting on another thread leaves this one free for the signals.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { process.waitUntilExit(); done.resume() }
        }
        status = process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
    } catch {
        failure = IrisError("cannot run \(command[0]): \(error.localizedDescription)")
    }

    let store = try await stopRecording(report.session)
    let state = store.readState()
    let still = (state?.duration ?? 0) > 1.5 && (store.readChanges() ?? []).isEmpty
    printJSON(RunReport(session: store.dir.path, command: command, exitStatus: status, duration: state?.duration ?? 0,
                        frames: state?.frames ?? 0, warning: still ? stillWarning : nil))
    if let failure { throw failure }
    if let renderIndex {
        try await renderCommand([store.dir.path] + Array(before[(renderIndex + 1)...]))
    }
    return status
}
