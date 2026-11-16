import Foundation
import ApplicationServices
import CoreGraphics
import IrisCore

struct DoctorReport: Encodable {
    var version: String
    var system: String
    /// Whether the application that launched iris may record the screen.
    var screenRecording: Bool
    /// Whether it may post real mouse and keyboard events. Only computer use needs it.
    var accessibility: Bool
    var ffmpeg: String?
    /// The session being recorded right now, if any.
    var recording: String?
    /// Whether `iris start` can work as things are.
    var ready: Bool
    var advice: [String]
}

/// The first executable of this name on the PATH.
func executable(_ name: String) -> String? {
    (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        .map { "\($0)/\(name)" }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// `iris doctor`: whether this machine, and the application iris was launched from, can
/// record; and what to do about it when not. It asks for nothing and changes nothing.
func doctorCommand(_ raw: [String]) throws {
    try Args(raw).finish()
    let screen = CGPreflightScreenCaptureAccess()
    let accessibility = AXIsProcessTrusted()
    let ffmpeg = executable("ffmpeg")
    var recording: String?
    if let store = SessionStore.current(), let state = store.readState(),
       ["recording", "paused", "starting"].contains(state.status), isAlive(state.pid) {
        recording = store.dir.path
    }
    var advice: [String] = []
    if !screen {
        advice.append("Grant Screen & System Audio Recording to the application that launches iris (the terminal, or the agent's desktop app) in System Settings › Privacy & Security, then restart that application.")
    }
    if !accessibility {
        advice.append("Accessibility is not granted. Only an agent that posts real mouse or keyboard events needs it; declared marks do not.")
    }
    if ffmpeg == nil {
        advice.append("ffmpeg is not on the PATH, so GIF output is unavailable (`brew install ffmpeg`). MP4 works without it.")
    }
    if let recording {
        advice.append("A recording is running in \(recording); `iris stop` it before starting another.")
    }
    printJSON(DoctorReport(version: Iris.version, system: ProcessInfo.processInfo.operatingSystemVersionString,
                           screenRecording: screen, accessibility: accessibility, ffmpeg: ffmpeg,
                           recording: recording, ready: screen && recording == nil, advice: advice))
}
