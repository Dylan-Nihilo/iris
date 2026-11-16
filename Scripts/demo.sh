#!/bin/sh
# Records the self-operating demo window and renders it: the whole agent workflow
# (start, declare each action, stop, render) with nobody at the keyboard.
#
#   Scripts/demo.sh [output directory] [extra options for `iris render`]
#
# The demo window opens behind the other windows and never takes the keyboard; pass
# IRIS_DEMO_FRONT=1 to watch it work, and IRIS_DEMO_THINK=3 to have it wait that many
# seconds between declaring an action and doing it, as an agent does.
#
# IRIS_DEMO_REAL=1 makes it work the way computer use does: it clicks with the real pointer
# (about twenty seconds; the pointer is put back afterwards). IRIS_DEMO_MARKS=0 leaves the
# declarations out, so the render has only what iris saw of the pointer to go by.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-"$root/samples/demo"}
[ $# -gt 0 ] && shift

swift build -c release --package-path "$root" >&2
bin="$root/.build/release"

rm -rf "$out"
log=$(mktemp)
marks=1
[ "${IRIS_DEMO_MARKS:-1}" = 0 ] && marks=
"$bin/iris-demo" ${marks:+--iris "$bin/iris"} ${IRIS_DEMO_FRONT:+--front} ${IRIS_DEMO_REAL:+--real-pointer} ${IRIS_DEMO_THINK:+--think "$IRIS_DEMO_THINK"} >"$log" &
demo=$!
trap 'kill "$demo" 2>/dev/null || true; rm -f "$log"' EXIT
until grep -q ready "$log"; do sleep 0.1; done

"$bin/iris" start --app iris-demo --wait 10 --name demo --out "$out" >&2
kill -USR1 "$demo"
status=0
wait "$demo" || status=$?
"$bin/iris" stop --render --format both "$@"
exit "$status"
