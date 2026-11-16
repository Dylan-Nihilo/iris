# Iris: notes for agents working on this repository

Iris is a macOS command-line screen recorder whose renders zoom on declared or observed
actions. `README.md` says what it is for; `iris guide` says how it is used.

## Commands

    swift build                        # debug build
    swift build -c release             # what Scripts/ use
    swift test                         # unit tests; no screen access needed
    Scripts/demo.sh [dir]              # end-to-end: records the self-operating demo window and renders it
    Scripts/install.sh --skill-file    # rewrite skills/iris-recording/SKILL.md from the guide

`Scripts/demo.sh` needs the Screen Recording permission for the launching application. Its
window opens behind the others and never takes the keyboard. `IRIS_DEMO_REAL=1` moves the
real pointer for about twenty seconds: use it only when nobody is working on the machine.

## Layout

    Sources/IrisCore/Recorder/   capture: targets, the background recorder, input sampling, change detection
    Sources/IrisCore/Render/     Timeline → ZoomPlan → CursorTrack / CameraTrack → Compositor → Production
                                 Overlays (captions, shortcut keys, pace) and Lettering (how they are drawn)
    Sources/IrisCore/Support/    arguments, models, session files, the guide
    Sources/iris/                the command line: one function per command
    Sources/iris-demo/           a window that operates itself, for end-to-end runs
    Tests/IrisCoreTests/         tests of the render decisions, on hand-built timelines
    skills/iris-recording/       the skill agents load; generated from the guide

## Conventions

- No dependencies beyond the system frameworks. `ffmpeg` is used only for GIF output and is
  looked up at run time.
- Every command prints JSON on stdout and errors on stderr with a non-zero exit status. A
  reply an agent must not miss goes into the JSON (`note`, `warning`), not only to stderr.
- Decisions about what the viewer sees (where to zoom, when, how the pointer moves) live in
  `Render/` and work on a `Timeline`, so they can be tested without recording anything. A
  change there comes with a test in `Tests/IrisCoreTests/RenderTests.swift`.
- Numbers that set the look belong in `ZoomPolicy` (`Render/Plan.swift`), `MotionPolicy`
  (`Render/Motion.swift`), `Overlays` (`Render/Overlays.swift`: how long words stay) or
  `Lettering` (`Render/Lettering.swift`: their sizes), each with a comment saying what it means.
- A mark is anything declared while recording: an action (`click`, `type`, `focus`, `wide`),
  or something for the viewer (`caption`, `keys`, `speed`). The second kind has no position
  and must stay out of the zoom plan and the pointer track.
- Times are seconds of recording time (pauses left out) until `TimeMap` turns them into
  video time; positions are 0 to 1 across the recorded picture, origin top left.
- The guide (`Support/Guide.swift`) is the single source of the skill file. After editing it,
  run `Scripts/install.sh --skill-file`; `GuideTests` fails when the two differ.
- After a change to rendering, render a recording and look at it (`iris sheet`, `iris frames`).
  A passing test does not say the video looks right.
- Recordings under `samples/` are not committed; they may show whatever was on the screen.
- The version is `Iris.version` (`Support/Version.swift`); a release is a tag `v<version>`.
- CI (`.github/workflows/ci.yml`) builds and runs the unit tests on macOS. It cannot record,
  so `Scripts/demo.sh` stays a check to run by hand.
