import Foundation
import AppKit
import IrisCore

let usage = """
iris — screen recordings that zoom on what matters, for people and for agents

Recording
  iris windows                       list windows that can be recorded, as JSON
  iris start [target] [options]      begin recording in the background and return at once
      --app NAME | --title TEXT | --window-id N     record one application window
      --display N [--region x,y,w,h]                record a display, or part of it (screen points)
      --whole-screen                 with a window target, include whatever overlaps it
      --wait SECONDS                 give a window that is still opening this long to appear
      --name NAME   --out DIR   --fps 60   --max-duration 1800
  iris mark [options]                declare where the viewer should look right now
      --x N --y N | --rect x,y,w,h   the point or region; with neither, the pointer position
      --space screen|window|norm     what the numbers mean (default screen points)
      --ref WxH                      size of the screenshot the numbers were measured in
      --kind click|focus|type|wide   click shows a click, type follows text into a field, wide asks
                                     for the full view; a region alone means focus
      --caption TEXT                 words shown under the picture while the camera is there
      --zoom 2.0   --hold 2.5   --at SECONDS   --label TEXT
  iris caption TEXT [--hold S]       show a line of words from now on; an empty text clears it
  iris keys cmd+shift+p [--hold S]   show the shortcut you are about to press
  iris speed 4                       run the video four times faster from here; `iris speed 1` ends it
  iris pause | iris resume           leave a stretch out of the recording
  iris stop [--render ...]           finish; with --render, produce the video straight away
  iris status                        state of the current recording
  iris run [start options] [--render [render options]] -- command ...
                                     record while a command runs, then stop; the command finds
                                     the session in IRIS_SESSION, and its exit status is iris's

Producing the video
  iris render [session] [options]    compose the final video with zooms, pointer and backdrop
      --out FILE   --format mp4|gif|both   --fps 60   --width 1920   --aspect auto|16:9|…
      --background NAME|#hex|FILE|wallpaper   --padding 0.06   --radius 14   --shadow 0.6
      --zoom 2.0 | --no-zoom   --cursor-size 1.5 | --no-cursor   --no-clicks
      --motion-blur 0.6   --idle-max 1.5 | --keep-idle   --gif-width 800   --gif-fps 15
      --no-outro                       do not hold the last picture while the camera pulls back
      --no-sync                        show declared actions when they were declared, not when the picture answers
      --pointer auto|declared|system   declared draws a pointer from the declared clicks alone
      --focus auto|declared|visual     visual zooms on what changes when nothing was declared
      --no-captions   --no-keys   --no-speed   --caption-size 1.0
  iris plan [session]                print the zoom plan the render would follow, as JSON
  iris frames [session] --at 1.5,4   save composed still frames for a quick look
  iris sheet [session]               save one image of the whole video, frame by frame with times
      --count 12   --columns 4   --tile-width 480   --out FILE

  iris guide                         how an agent records with iris, step by step
  iris skill [--claude] [--codex] [--dir DIR]
                                     install that guide as a skill for Claude Code, for Codex, or
                                     under DIR; with no option, print the skill file
  iris doctor                        whether this machine can record: permissions, ffmpeg, a running recording
  iris version

Every command acts on the most recent session unless a session directory is given.
"""

func run() async -> Int32 {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty else { print(usage); return 0 }
    let command = arguments.removeFirst()
    do {
        switch command {
        case "windows": try await windowsCommand(arguments)
        case "start": try await startCommand(arguments)
        case "mark": try markCommand(arguments)
        case "caption": try captionCommand(arguments)
        case "keys": try keysCommand(arguments)
        case "speed": try speedCommand(arguments)
        case "run": return try await runCommand(arguments)
        case "pause": try await signalCommand(arguments, signal: SIGUSR1, expect: "paused")
        case "resume": try await signalCommand(arguments, signal: SIGUSR2, expect: "recording")
        case "stop": try await stopCommand(arguments)
        case "status": try statusCommand(arguments)
        case "render": try await renderCommand(arguments)
        case "plan": try await planCommand(arguments)
        case "frames": try await framesCommand(arguments)
        case "sheet": try await sheetCommand(arguments)
        case "guide": print(Guide.text)
        case "skill": try skillCommand(arguments)
        case "doctor": try doctorCommand(arguments)
        case "version", "--version", "-v": print("iris \(Iris.version)")
        case "help", "--help", "-h": print(usage)
        default:
            FileHandle.standardError.write(Data("iris: unknown command \"\(command)\"\n\n\(usage)\n".utf8))
            return 2
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("iris: \(error)\n".utf8))
        return 1
    }
}

// The recorder and the window list talk to the window server, which insists on the main
// thread; everything else runs as ordinary async work.
let first = CommandLine.arguments.dropFirst().first
if first == "_record" {
    MainActor.assumeIsolated {
        do {
            try recordDaemonCommand(Array(CommandLine.arguments.dropFirst(2)))
        } catch {
            FileHandle.standardError.write(Data("iris: \(error)\n".utf8))
            exit(1)
        }
    }
}
if first == "windows" { MainActor.assumeIsolated { _ = NSApplication.shared } }
Task { exit(await run()) }
dispatchMain()
