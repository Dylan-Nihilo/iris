import Foundation
import AppKit
import ScreenCaptureKit

/// What the caller asked to record.
public struct TargetRequest {
    public var windowID: UInt32?
    public var app: String?
    public var title: String?
    public var display: Int?
    /// Global screen points, origin top left of the main display.
    public var region: CGRect?
    /// Record everything visible in the area instead of only the target application's windows.
    public var wholeScreen = false
    public init() {}
}

public struct CaptureTarget {
    public let filter: SCContentFilter
    /// Area to capture in the display's own points.
    public let sourceRect: CGRect
    /// The same area in global screen points.
    public let captureRect: CGRect
    public let scale: Double
    public let info: TargetInfo
    /// The window a window target was resolved to, and the display it is on.
    public let window: SCWindow?
    public let display: SCDisplay
    /// Whether only the target application is in the picture.
    public let isolated: Bool
    /// Whether the window is recorded by itself, because it is not on the visible desktop.
    public var alone = false
}

public struct WindowSummary: Codable {
    public var id: UInt32
    public var app: String
    public var bundleID: String
    public var title: String
    public var frame: Rect
    public var onScreen: Bool
}

public enum Targets {
    static func content() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            throw IrisError("screen recording is not permitted for this terminal. Grant it in System Settings › Privacy & Security › Screen & System Audio Recording, then restart the terminal. (\(error.localizedDescription))")
        }
    }

    /// Ordinary application windows, largest first.
    public static func windows() async throws -> [WindowSummary] {
        let content = try await content()
        return content.windows
            .filter { isOrdinary($0) }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            .map {
                WindowSummary(id: $0.windowID,
                              app: $0.owningApplication?.applicationName ?? "",
                              bundleID: $0.owningApplication?.bundleIdentifier ?? "",
                              title: $0.title ?? "",
                              frame: Rect($0.frame),
                              onScreen: $0.isOnScreen)
            }
    }

    static func isOrdinary(_ window: SCWindow) -> Bool {
        window.windowLayer == 0 && window.frame.width >= 120 && window.frame.height >= 90
            && window.owningApplication != nil
    }

    public static func resolve(_ request: TargetRequest) async throws -> CaptureTarget {
        let content = try await content()
        if request.windowID != nil || request.app != nil || request.title != nil {
            return try resolveWindow(request, content: content)
        }
        return try resolveDisplay(request, content: content)
    }

    static func resolveWindow(_ request: TargetRequest, content: SCShareableContent) throws -> CaptureTarget {
        var candidates = content.windows.filter { isOrdinary($0) }
        if let id = request.windowID {
            candidates = content.windows.filter { $0.windowID == id }
        }
        if let app = request.app?.lowercased() {
            candidates = candidates.filter {
                let name = $0.owningApplication?.applicationName.lowercased() ?? ""
                let bundle = $0.owningApplication?.bundleIdentifier.lowercased() ?? ""
                return name == app || bundle == app || name.contains(app) || bundle.contains(app)
            }
        }
        if let title = request.title?.lowercased() {
            candidates = candidates.filter { ($0.title ?? "").lowercased().contains(title) }
        }
        // Prefer what the viewer can see, then the largest.
        let onScreen = candidates.filter { $0.isOnScreen }
        if !onScreen.isEmpty { candidates = onScreen }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let app = window.owningApplication else {
            throw IrisError("no window matches; run `iris windows` to see what can be recorded")
        }
        guard let display = content.displays.max(by: {
            $0.frame.intersection(window.frame).area < $1.frame.intersection(window.frame).area
        }), display.frame.intersects(window.frame) else {
            throw IrisError("the window \"\(window.title ?? "")\" is not on any display")
        }
        var info = TargetInfo(kind: "window", app: app.applicationName, bundleID: app.bundleIdentifier,
                              title: window.title, windowID: window.windowID, displayID: display.displayID)
        // A display shows the desktop in view. A window on another one (or behind a full-screen
        // application) is not in that picture, so it is recorded by itself.
        if !window.isOnScreen {
            guard !request.wholeScreen else {
                throw IrisError("the window \"\(window.title ?? "")\" is not on the visible desktop, so there is no screen around it to record; leave out --whole-screen")
            }
            info.capture = "window"
            var target = make(filter: SCContentFilter(desktopIndependentWindow: window), display: display,
                              globalRect: window.frame, info: info, window: window, isolated: true)
            target.alone = true
            return target
        }
        let visible = window.frame.intersection(display.frame)
        let filter = request.wholeScreen
            ? SCContentFilter(display: display, excludingWindows: [])
            : isolating(app.processID, on: display, content: content)
        info.capture = request.wholeScreen ? "screen" : "application"
        return make(filter: filter, display: display, globalRect: visible, info: info, window: window, isolated: !request.wholeScreen)
    }

    /// A filter that shows one application alone: its menus, popovers and sheets are separate
    /// windows, and taking the whole application keeps them in the picture. It is written as
    /// "the display without everyone else" because naming the application itself makes macOS
    /// replace its window buttons with a sharing badge for as long as the recording runs.
    static func isolating(_ pid: pid_t, on display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let others = content.applications.filter { $0.processID != pid }
        return SCContentFilter(display: display, excludingApplications: others, exceptingWindows: [])
    }

    /// The same filter for the applications running now, or nil when none has come or gone
    /// since `known`. Applications launched during a recording are not excluded until then.
    static func refreshedIsolation(_ pid: pid_t, on display: SCDisplay, known: inout Set<pid_t>) async -> SCContentFilter? {
        guard let content = try? await content() else { return nil }
        let running = Set(content.applications.map(\.processID))
        guard running != known else { return nil }
        known = running
        guard let current = content.displays.first(where: { $0.displayID == display.displayID }) else { return nil }
        return isolating(pid, on: current, content: content)
    }

    static func resolveDisplay(_ request: TargetRequest, content: SCShareableContent) throws -> CaptureTarget {
        guard !content.displays.isEmpty else { throw IrisError("no display found") }
        let display: SCDisplay
        if let index = request.display {
            guard content.displays.indices.contains(index) else {
                throw IrisError("display \(index) does not exist; there are \(content.displays.count)")
            }
            display = content.displays[index]
        } else if let region = request.region,
                  let hit = content.displays.max(by: { $0.frame.intersection(region).area < $1.frame.intersection(region).area }) {
            display = hit
        } else {
            display = content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays[0]
        }
        var rect = display.frame
        var kind = "display"
        if let region = request.region {
            rect = region.intersection(display.frame)
            kind = "region"
            guard rect.width >= 64, rect.height >= 64 else {
                throw IrisError("the region is outside the display or smaller than 64 points")
            }
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let info = TargetInfo(kind: kind, app: nil, bundleID: nil, title: nil, windowID: nil, displayID: display.displayID)
        return make(filter: filter, display: display, globalRect: rect, info: info, window: nil, isolated: false)
    }

    static func make(filter: SCContentFilter, display: SCDisplay, globalRect: CGRect, info: TargetInfo,
                     window: SCWindow?, isolated: Bool) -> CaptureTarget {
        let rect = globalRect.integral
        let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        var scale = 2.0
        if let mode = CGDisplayCopyDisplayMode(display.displayID), mode.width > 0 {
            scale = Double(mode.pixelWidth) / Double(mode.width)
        }
        return CaptureTarget(filter: filter, sourceRect: local, captureRect: rect, scale: scale, info: info,
                             window: window, display: display, isolated: isolated)
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
