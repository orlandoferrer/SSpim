#!/bin/bash
# Compare all user and kernel text words independently of runtime output.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
: "${SPIM_REFERENCE:?Set SPIM_REFERENCE to the pinned upstream spim CLI}"
: "${SPIM_EXCEPTION_FILE:?Set SPIM_EXCEPTION_FILE to the pinned upstream CPU/exceptions.s}"
reference="$(cd "$(dirname "$SPIM_REFERENCE")" && pwd)/$(basename "$SPIM_REFERENCE")"
handler="$(cd "$(dirname "$SPIM_EXCEPTION_FILE")" && pwd)/$(basename "$SPIM_EXCEPTION_FILE")"
swift build --package-path "$root" --product swiftspim-cli
binary="$(swift build --package-path "$root" --show-bin-path)/swiftspim-cli"
fixture="$root/Tests/SpimCoreTests/Fixtures/tt.core.s"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
(cd "$temp"; "$reference" -quiet -ef "$handler" -full_dump -file "$fixture" >upstream.stdout 2>upstream.stderr)
awk '$1 ~ /^\[0x[0-9a-f]+\]$/ && $2 ~ /^0x[0-9a-f]+$/ { print substr($1, 2, 10), $2 }' "$temp/text.asm" \
    | LC_ALL=C sort >"$temp/oracle.words"
"$binary" -quiet -ef "$handler" --dump-instruction-words -file "$fixture" >"$temp/swift.words"
test -s "$temp/oracle.words"
diff -u "$temp/oracle.words" "$temp/swift.words"
printf 'Matched %s instruction words by address (user and kernel text).\n' "$(wc -l < "$temp/oracle.words" | tr -d ' ')"
