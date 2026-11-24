#!/bin/bash
# Set SPIM_REFERENCE to a built CLI binary from upstream SVN revision 764.
# Set SPIM_EXCEPTION_FILE to that checkout's CPU/exceptions.s.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
: "${SPIM_REFERENCE:?Set SPIM_REFERENCE to the pinned upstream spim CLI}"
: "${SPIM_EXCEPTION_FILE:?Set SPIM_EXCEPTION_FILE to the pinned upstream CPU/exceptions.s}"
swift build --package-path "$root" --product swiftspim-cli
binary="$(swift build --package-path "$root" --show-bin-path)/swiftspim-cli"
fixtures="$root/Tests/SpimCoreTests/Fixtures"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
failed=0
printf '1\n2\n3\n4\n5\n6\n' >"$temp/mapped-input"
compare() {
  local name="$1"; shift
  local r=0 s=0 input="$fixtures/tt.in.txt"
  if [[ "$name" == tt.io ]]; then input="$temp/mapped-input"; fi
  "$SPIM_REFERENCE" -quiet "$@" -file "$fixtures/$name.s" <"$input" >"$temp/$name.oracle.all" 2>"$temp/$name.oracle.err" || r=$?
  "$binary" -quiet "$@" -file "$fixtures/$name.s" <"$input" >"$temp/$name.swift" 2>"$temp/$name.swift.err" || s=$?
  # Pinned CLI file mode normally writes only guest output. Keep it byte-exact
  # unless a configured reference does include the optional startup banner.
  if grep -q '^SPIM Version ' "$temp/$name.oracle.all"; then
    if grep -q '^Loaded:' "$temp/$name.oracle.all"; then
      sed '1,/^Loaded:/d' "$temp/$name.oracle.all" >"$temp/$name.oracle"
    else
      tail -n +5 "$temp/$name.oracle.all" >"$temp/$name.oracle"
    fi
  else
    cp "$temp/$name.oracle.all" "$temp/$name.oracle"
  fi
  # Compare without forcing a final newline on guest output.
  if [[ "$r" != "$s" ]] || ! diff -u "$temp/$name.oracle" "$temp/$name.swift" || ! diff -u "$temp/$name.oracle.err" "$temp/$name.swift.err"; then
    printf 'DIFF %s: reference exit %s, Swift exit %s\n' "$name" "$r" "$s"
    cat "$temp/$name.oracle.err" "$temp/$name.swift.err"
    failed=1
  else
    printf 'PASS %s\n' "$name"
  fi
}
compare tt.core -ef "$SPIM_EXCEPTION_FILE"
compare tt.le -ef "$SPIM_EXCEPTION_FILE"
compare tt.dir -ef "$SPIM_EXCEPTION_FILE"
compare tt.bare -delayed_branches -delayed_loads -noexception
compare tt.alu.bare -bare -noexception
compare tt.fpu.bare -bare -noexception
compare tt.io -mapped_io -ef "$SPIM_EXCEPTION_FILE"
exit "$failed"
