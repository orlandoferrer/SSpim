#!/bin/bash
# Validate positive non-default legacy segment flags against upstream r764.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
: "${SPIM_REFERENCE:?Set SPIM_REFERENCE to the pinned upstream spim CLI}"
: "${SPIM_EXCEPTION_FILE:?Set SPIM_EXCEPTION_FILE to the pinned upstream CPU/exceptions.s}"
swift build --package-path "$root" --product swiftspim-cli
binary="$(swift build --package-path "$root" --show-bin-path)/swiftspim-cli"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
cat >"$temp/heap.s" <<'ASM'
.text
.globl main
main:
  li $v0, 9
  li $a0, 9
  syscall
  move $a0, $v0
  li $v0, 1
  syscall
  li $v0, 11
  li $a0, 32
  syscall
  li $v0, 9
  li $a0, 4
  syscall
  move $a0, $v0
  li $v0, 1
  syscall
  li $v0, 10
  syscall
ASM
run_case() {
    local name="$1"; shift
    "$SPIM_REFERENCE" -quiet -ef "$SPIM_EXCEPTION_FILE" "$@" -file "$temp/heap.s" >"$temp/upstream"
    "$binary" -quiet -ef "$SPIM_EXCEPTION_FILE" "$@" -file "$temp/heap.s" >"$temp/swift"
    diff -u "$temp/upstream" "$temp/swift"
    printf 'PASS %s (%s)\n' "$name" "$(cat "$temp/swift")"
}
run_case terminal-default
run_case rounded-initial -sd 65537 -ld 65600
run_case minimum-data -sd 1 -ld 65552
run_case custom-all-eight -st 300000 -sd 131072 -ld 1300000 -ss 128000 -ls 300000 -skt 131072 -skd 128000 -lkd 1300000
