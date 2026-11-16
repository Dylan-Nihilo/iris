import Foundation
import IrisCore

struct StopReport: Encodable {
    var session: String
    var status: String
    var duration: Double
    var frames: Int
    var warning: String?
}

let stillWarning = "nothing changed in the picture during the whole recording; check with `iris sheet` that it shows the window, and that the window was not minimized or left on a desktop that is not in view"

func stopCommand(_ raw: [String]) async throws {
    let renderIndex = raw.firstIndex(of: "--render")
    let own = renderIndex.map { Array(raw[..<$0]) } ?? raw
    let args = Args(own)
    try args.finish()
    let store = try await stopRecording(args.positionals.first)
    let state = store.readState()
    // A picture that never changed is a window that was minimized, out of view and not drawing,
    // or the wrong one. Say so now; the render would only show it later.
    let still = (state?.duration ?? 0) > 1.5 && (store.readChanges() ?? []).isEmpty
    printJSON(StopReport(session: store.dir.path, status: "finished", duration: state?.duration ?? 0, frames: state?.frames ?? 0,
                         warning: still ? stillWarning : nil))
    if let renderIndex {
        try await renderCommand([store.dir.path] + Array(raw[(renderIndex + 1)...]))
    }
}

let renderFlags: Set<String> = ["no-zoom", "no-cursor", "no-clicks", "keep-idle", "no-outro", "no-sync",
                                "no-captions", "no-keys", "no-speed"]

/// Reads the options shared by `render`, `plan` and `frames`.
func renderOptions(_ args: inout Args) throws -> RenderOptions {
    var options = RenderOptions()
    if let fps = try args.int("fps") { options.fps = min(max(fps, 5), 120) }
    if let width = try args.int("width") { options.style.width = min(max(width, 320), 7680) }
    if let aspect = args.string("aspect"), aspect != "auto" {
        let parts = aspect.split(whereSeparator: { $0 == ":" || $0 == "x" || $0 == "/" }).compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw IrisError("--aspect looks like 16:9, or auto") }
        options.style.aspect = parts[0] / parts[1]
    }
    if let background = args.string("background") { options.style.background = background }
    if let padding = try args.double("padding") { options.style.padding = min(max(padding, 0), 0.3) }
    if let radius = try args.double("radius") { options.style.radius = max(radius, 0) }
    if let shadow = try args.double("shadow") { options.style.shadow = min(max(shadow, 0), 1) }
    if let size = try args.double("cursor-size") { options.style.cursorSize = min(max(size, 0.5), 5) }
    if args.flag("no-cursor") { options.style.showCursor = false }
    if args.flag("no-clicks") { options.style.showClicks = false }
    if let blur = try args.double("motion-blur") { options.style.motionBlur = min(max(blur, 0), 1) }
    if let zoom = try args.double("zoom") { options.zoom.zoom = min(max(zoom, 1), options.zoom.maxZoom) }
    if args.flag("no-zoom") { options.zoom.enabled = false }
    if let hold = try args.double("hold") { options.zoom.clickHold = max(hold, 0.3) }
    if let idle = try args.double("idle-max") { options.idleMax = max(idle, 0.2) }
    if args.flag("keep-idle") { options.idleMax = nil }
    if args.flag("no-outro") { options.outro = 0 }
    if args.flag("no-sync") { options.syncMarks = false }
    if args.flag("no-captions") { options.captions = false }
    if args.flag("no-keys") { options.keys = false }
    if args.flag("no-speed") { options.speed = false }
    if let size = try args.double("caption-size") { options.style.captionSize = min(max(size, 0.5), 3) }
    if let pointer = args.string("pointer") {
        guard let source = PointerSource(rawValue: pointer) else { throw IrisError("--pointer is one of auto, declared, system") }
        options.pointer = source
    }
    if let focus = args.string("focus") {
        guard let source = FocusSource(rawValue: focus) else { throw IrisError("--focus is one of auto, declared, visual") }
        options.focus = source
    }
    return options
}

struct RenderReport: Encodable {
    var session: String
    var outputs: [String]
    var width: Int
    var height: Int
    var fps: Int
    var duration: Double
    var recorded: Double
    var idleRemoved: Double
    var zooms: Int
    var captions: Int
    var pointer: String
    var focus: String
}

func renderCommand(_ raw: [String]) async throws {
    var args = Args(raw, flags: renderFlags)
    let options = try renderOptions(&args)
    let out = args.string("out")
    let format = args.string("format") ?? (out?.lowercased().hasSuffix(".gif") == true ? "gif" : "mp4")
    let gifWidth = try args.int("gif-width") ?? 800
    let gifFPS = try args.int("gif-fps") ?? 15
    try args.finish()
    guard ["mp4", "gif", "both"].contains(format) else { throw IrisError("--format is one of mp4, gif, both") }
    let store = try SessionStore.resolve(args.positionals.first)
    let production = try await Production(store: store, options: options)

    let base: URL
    if let out {
        base = URL(fileURLWithPath: (out as NSString).expandingTildeInPath).deletingPathExtension()
    } else {
        base = store.dir.appendingPathComponent(production.info.name)
    }
    func report(_ what: String) -> (Double) -> Void {
        var lastShown = -1
        return { fraction in
            let percent = Int(fraction * 100)
            if percent / 10 != lastShown / 10 || fraction >= 1 {
                lastShown = percent
                FileHandle.standardError.write(Data("\(what) \(percent)%\n".utf8))
            }
        }
    }
    let started = Date()
    var outputs: [String] = []
    if format != "gif" {
        let video = base.appendingPathExtension("mp4")
        try await production.export(to: video, progress: report("rendering"))
        outputs.append(video.path)
    }
    if format != "mp4" {
        // A GIF is its own render, at its own size and pace, rather than a copy of the video.
        var small = options
        small.fps = min(max(gifFPS, 2), 50)
        small.style.width = min(max(gifWidth, 160), options.style.width)
        let gif = base.appendingPathExtension("gif")
        try await Production(store: store, options: small).exportGIF(to: gif, progress: report("rendering gif"))
        outputs.append(gif.path)
    }
    FileHandle.standardError.write(Data(String(format: "rendered in %.1fs\n", Date().timeIntervalSince(started)).utf8))
    printJSON(RenderReport(session: store.dir.path, outputs: outputs, width: production.compositor.width,
                           height: production.compositor.height, fps: options.fps, duration: production.duration,
                           recorded: production.info.duration ?? 0, idleRemoved: production.map.removed,
                           zooms: production.plan.segments.count, captions: production.overlays.count,
                           pointer: production.pointer.rawValue,
                           focus: production.focus.rawValue))
}

struct PlanReport: Encodable {
    var session: String
    var duration: Double
    var recorded: Double
    var kept: [Interval]
    var pointer: String
    var focus: String
    var zooms: [ZoomSegment]
    var overlays: [Overlay]
    var fast: [Pace]
}

func planCommand(_ raw: [String]) async throws {
    var args = Args(raw, flags: renderFlags)
    let options = try renderOptions(&args)
    try args.finish()
    let store = try SessionStore.resolve(args.positionals.first)
    let production = try await Production(store: store, options: options)
    printJSON(PlanReport(session: store.dir.path, duration: production.duration, recorded: production.info.duration ?? 0,
                         kept: production.map.kept, pointer: production.pointer.rawValue, focus: production.focus.rawValue,
                         zooms: production.plan.segments, overlays: production.overlays, fast: production.fast))
}

struct FramesReport: Encodable {
    var session: String
    var frames: [String]
}

func framesCommand(_ raw: [String]) async throws {
    var args = Args(raw, flags: renderFlags)
    let options = try renderOptions(&args)
    let at = args.string("at")
    let count = try args.int("count") ?? 6
    let out = args.string("out")
    try args.finish()
    let store = try SessionStore.resolve(args.positionals.first)
    let production = try await Production(store: store, options: options)
    var times: [Double]
    if let at {
        times = at.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !times.isEmpty else { throw IrisError("--at takes moments in seconds, like 1.5,4") }
    } else {
        // Without moments named: an even spread, plus the height of every zoom.
        times = (0..<max(count, 1)).map { (Double($0) + 0.5) / Double(max(count, 1)) * production.duration }
        times += production.plan.segments.flatMap { $0.keys.map { $0.at + 0.6 } }
        times.sort()
    }
    let dir = out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? store.dir.appendingPathComponent("frames")
    let written = try await production.stills(at: times, to: dir)
    printJSON(FramesReport(session: store.dir.path, frames: written.map(\.path)))
}

struct SheetReport: Encodable {
    var session: String
    var sheet: String
    var duration: Double
    var times: [Double]
}

func sheetCommand(_ raw: [String]) async throws {
    var args = Args(raw, flags: renderFlags)
    var options = try renderOptions(&args)
    let count = min(max(try args.int("count") ?? 12, 1), 60)
    let columns = try args.int("columns") ?? (count <= 4 ? count : count <= 12 ? 4 : 5)
    let tile = min(max(try args.int("tile-width") ?? 480, 120), 1920)
    let out = args.string("out")
    try args.finish()
    // Tiles are small; drawing them at twice their size is plenty.
    options.style.width = min(options.style.width, tile * 2)
    let store = try SessionStore.resolve(args.positionals.first)
    let production = try await Production(store: store, options: options)
    let times = (0..<count).map { (Double($0) + 0.5) / Double(count) * production.duration }
    let url = out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? store.dir.appendingPathComponent("sheet.png")
    try await production.sheet(at: times, columns: columns, tileWidth: tile, to: url)
    printJSON(SheetReport(session: store.dir.path, sheet: url.path, duration: production.duration,
                          times: times.map { ($0 * 100).rounded() / 100 }))
}
