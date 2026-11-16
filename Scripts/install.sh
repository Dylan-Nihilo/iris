#!/bin/sh
# Builds iris and puts it on the PATH.
#
#   Scripts/install.sh [--prefix DIR] [--claude-skill] [--codex-skill] [--skill-file]
#
#   --prefix DIR     where the binary goes (default ~/.local/bin)
#   --claude-skill   link the recording skill into ~/.claude/skills
#   --codex-skill    link the recording skill into ${CODEX_HOME:-~/.codex}/skills
#   --skill-file     only rewrite skills/iris-recording/SKILL.md from `iris skill`
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
prefix="$HOME/.local/bin"
claude=; codex=; only_skill=
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix=$2; shift ;;
    --claude-skill) claude=1 ;;
    --codex-skill) codex=1 ;;
    --skill-file) only_skill=1 ;;
    *) echo "install.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

swift build -c release --package-path "$root" >&2
bin="$root/.build/release/iris"
skill="$root/skills/iris-recording"

# The skill file in the repository is the one the binary writes.
"$bin" skill >"$skill/SKILL.md.new"
mv "$skill/SKILL.md.new" "$skill/SKILL.md"
[ -n "$only_skill" ] && exit 0

mkdir -p "$prefix"
install -m 755 "$bin" "$prefix/iris"
echo "installed $prefix/iris"

link() {
  mkdir -p "$1"
  ln -sfn "$skill" "$1/iris-recording"
  echo "linked $1/iris-recording -> $skill"
}
[ -n "$claude" ] && link "$HOME/.claude/skills"
[ -n "$codex" ] && link "${CODEX_HOME:-$HOME/.codex}/skills"
case ":$PATH:" in *":$prefix:"*) ;; *) echo "note: $prefix is not on your PATH" >&2 ;; esac
