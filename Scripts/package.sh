#!/bin/sh
# Builds the release archive: one binary for Apple silicon and Intel, with its checksum.
#
#   Scripts/package.sh [dir]     writes dir/iris-macos-universal.tar.gz and .sha256 (default dist)
#
# The release workflow runs this on a tag; run it by hand to see what a release would hold.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-"$root/dist"}
name=iris-macos-universal

swift build -c release --package-path "$root" --arch arm64 --arch x86_64 --product iris >&2
bin="$root/.build/apple/Products/Release/iris"
archs=$(lipo -archs "$bin")
case "$archs" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "package.sh: built only $archs" >&2; exit 1 ;; esac

stage=$(mktemp -d)
trap 'rm -r "$stage"' EXIT
install -m 755 "$bin" "$stage/iris"
cp "$root/LICENSE" "$root/README.md" "$stage/"

mkdir -p "$out"
tar -czf "$out/$name.tar.gz" -C "$stage" iris LICENSE README.md
(cd "$out" && shasum -a 256 "$name.tar.gz" >"$name.tar.gz.sha256")
echo "$("$stage/iris" version), $archs"
cat "$out/$name.tar.gz.sha256"
