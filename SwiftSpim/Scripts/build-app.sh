#!/bin/bash
# Build an unsigned local app bundle with the Apple Silicon Xcode toolchain.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    printf '%s\n' 'Run this script on an Apple Silicon Mac with Xcode or the Swift command-line tools.' >&2
    exit 1
fi
out="${1:-$root/dist/SwiftSpim.app}"
if [[ "$out" != *.app || -e "$out" ]]; then
    printf 'Expected a new .app destination, got %s\n' "$out" >&2
    exit 1
fi
configuration="${SWIFTSPIM_CONFIGURATION:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
    printf '%s\n' 'SWIFTSPIM_CONFIGURATION must be release or debug.' >&2
    exit 1
fi
swift build --package-path "$root" --arch arm64 -c "$configuration" --product SwiftSpim
bin="$(swift build --package-path "$root" --arch arm64 -c "$configuration" --show-bin-path)"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
cp "$bin/SwiftSpim" "$out/Contents/MacOS/SwiftSpim"
cp -R "$bin/SwiftSpim_SpimCore.bundle" "$out/Contents/Resources/"
cp "$root/THIRD_PARTY_NOTICES.txt" "$out/Contents/Resources/"
cp "$root/Docs/Info.plist" "$out/Contents/Info.plist"
printf 'Built %s\n' "$out"
