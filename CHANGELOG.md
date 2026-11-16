# Changelog

## 0.1.0 (2026-11-16)

The first release.

- Records a window, a display or a region in the background (`iris start`, `iris stop`,
  `iris pause`, `iris resume`, `iris run -- command`).
- Renders MP4 and GIF with a backdrop, a pointer drawn at render time, click rings, and a
  camera that zooms on every action, declared with `iris mark` or seen from the real pointer.
- Captions, shortcut keys and fast-forward (`iris caption`, `iris keys`, `iris speed`).
- Cuts the stretches where the picture stands still, and moves each declared action to the
  moment the picture answers.
- `iris plan`, `iris frames` and `iris sheet` to check a render; `iris doctor` to check the
  machine.
- `iris guide` for agents, and `iris skill` to install it as a skill for Claude Code or Codex.

Install with `brew install Dylan-Nihilo/tap/iris`, or take `iris-macos-universal.tar.gz`
below: one binary for Apple silicon and Intel, macOS 14 or later. It is not notarised, so a
copy downloaded with a browser has to be released from quarantine first
(`xattr -d com.apple.quarantine iris`); Homebrew and `curl` downloads run as they are.
