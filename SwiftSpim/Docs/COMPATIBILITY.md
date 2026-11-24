# Compatibility and verification

Reference: SPIM/QtSpim 9.1.24, official SourceForge SVN r764.

The goal is full functional parity. This is a development snapshot, not a certified replacement for QtSpim. A green unit test set does not substitute for matching results in the upstream suite or running the macOS UI.

## Acceptance checklist

- Assemble SPIM data directives, relocations, scoped symbols, pseudo-instructions, and diagnostics. Compare emitted words and data layout, not only successful execution.
- Compare integer, coprocessor and floating-point instructions, branch and load timing, HI/LO, FCSR, exceptions, handler startup and both endian modes.
- Check console input, mapped I/O registers, timers, and file syscalls. Host file access now follows QtSpim by default; an optional selected-directory restriction remains available.
- Check debugger load/reset, run/stop/step/continue, breakpoints, editable register and data values, source/disassembly display, symbol table, logging, printing, and settings on an Apple Silicon Mac.
- Test settings interactions, including delayed modes with breakpoints, and I/O pause/resume. Inspect the UI and its keyboard shortcuts with a real app run.

## Results recorded for this snapshot

- Historical ZIP baseline: the Swift package built on Linux with official Swift 5.9.2. All 26 unit tests passed, covering the official Hello World, instruction encoding, relocation, incremental symbols, branch and load timing, breakpoints, input suspension, endian handling, sparse segment limits, and scoped guest file I/O.
- Historical ZIP baseline: against the compiled upstream r764 Linux CLI, stdout and exit status matched for `tt.core`, `tt.le`, `tt.dir`, `tt.bare`, `tt.fpu.bare`, and `tt.io`. The MMIO comparison used six piped lines; both programs echoed only the first three for that specific run. This is not coverage of all interactive console or timer behavior.
- `tt.be` reached its own “Passed all tests” marker using the Swift CLI's `--big-endian` flag. No big-endian upstream host was used for a byte comparison.
- All 4,758 user and kernel `tt.core` text words matched the original by address in the `-full_dump` comparison. SPIM display words are stored separately from execution metadata when the original printer discards a break code or a conditional move operand. Self-modifying writes discard that hidden metadata.
- All eight legacy segment size/limit flags are wired into both app and CLI. Four oracle comparisons matched heap output exactly, including the terminal build defaults, rounding a requested initial size, the 64 KiB minimum user data segment, and a non-default run using all eight flags. The original Qt and terminal programs use different default text and data capacities; the port preserves that distinction. Invalid or unsafe capacity values are rejected rather than reproducing undefined behavior or crashes.
- The native `tt.alu.bare` comparison now matches stdout, stderr, and exit status byte for byte. Both programs retain a partial program after the syntax error, print the undefined `fail` symbol, run the initial valid instructions, and stop at the unresolved branch. Immediate and shift warnings do not abort the recovering assembler. The core library also retains a strict assembly mode for callers that want thrown errors.
- The ARM macOS app compiles against the Apple SDK in debug and release. Native UI validation now includes loading/reset, Hello World breakpoints/step/continue, interactive `tt.core` completion, separate register inspection and editing, simple/bare preferences, all-panel log export, and 102-page PDF printing. Final-release memory editing, active-tab/pane restoration, and simulator-preference persistence across relaunch also passed. See the native validation record below.
- Guest file I/O now uses host paths and native POSIX flags by default, as in QtSpim. The optional selected-directory mode rejects traversal and symlinks; enabling restriction without a folder disables file opens. The CLI offers `--guest-directory` and `--no-file-io`; the last file-policy option wins.

`compare-upstream.sh` now compares stderr as well as stdout and exit status. All seven comparisons pass against the native r764 build. `compare-words.sh` and `compare-memory-layout.sh` independently test machine words and memory option behavior.

## Native validation — November 23, 2026

- Host: Apple Silicon (`arm64`), macOS 27.2.1, Apple Swift 6.4.2, macOS 27.2 SDK.
- Found and fixed guest file opening on Darwin: combining `O_NOFOLLOW_ANY` and `O_NOFOLLOW` returns `EINVAL` even for a regular file. Both platforms now walk directory descriptors with `openat` and reject symlinks at each guest path component.
- Added coverage for valid nested file access, intermediate symlink rejection, and parent-directory traversal rejection.
- All 54 native XCTest tests pass: 40 core tests and 14 debugger/layout/console tests. The latest test log is `.build/final-hosted-tests.log` (generated and ignored by Git).
- Built the original r764 CLI natively from the supplied source archive. All seven fixtures now match stdout, stderr and exit status. The native word comparison matches all 4,758 `tt.core` words, and all four legacy memory-layout comparisons pass.
- `bash Scripts/build-app.sh` built `dist/SwiftSpim.app`; its executable is an arm64 Mach-O. The bundle contains the exception-handler resource and upstream notices. Launch Services accepted the launch outside the command sandbox, and a running process was observed.
- Desktop access recovered, allowing direct comparison with the installed macOS QtSpim 9.1.24. The default layout now uses tabbed registers, tabbed Text/Data, bottom messages, and a separate console. Native core execution initially exposed excessive list rebuilding; throttled UI refresh and following only explicit debug stops resolved the observed timeout.
- The relocated bundle in `/private/tmp` completed `tt.core` with interactive input and “Passed all tests.” Native log export contained all six panel sections. Print-to-PDF produced 102 pages with integer registers, text, data, console, and the pass marker confirmed through PDFKit.
- Claude Code Opus 5.5 reviewed the code and manual. GPT-6.2 Astra assessed all findings and coverage comments; decisions and closure evidence are retained in `Docs/Reviews/`. Review fixes cover assembler recovery, raw-byte I/O and EOF, stack environment layout, incremental loading, timer sampling, debugger execution state and docking. All 29 focused differential regression cases match the native original byte for byte.
- The SwiftUI workspace now supports tab groups, edge splits, adjustable dividers, floating panes and redocking, with persisted layout. Native accessibility actions verified console redocking, floating the Data pane, and splitting Data below Text. After recovery of native coordinate input, dragging the divider visibly resized the register pane. Native pointer drags verified tab-to-edge splitting, tab-to-header regrouping and dropping outside the workspace window to float a pane. Memory rows remain compact and aligned at the larger font sizes.
- The post-review release completed interactive `tt.core` with all six input lines, “Passed all tests” and exit status zero. Hello World stopped at `main`, single-stepped with the expected PC/register change, then continued to output and exit zero. A TextKit 2 console stall observed with a manually selected entry and runaway exception output was fixed using TextKit 1; native tests verify 100,000 lines plus split UTF-8 output without truncation and the final pass marker inside a constrained docked viewport. The rebuilt release visibly followed to the pass marker without redocking or resizing. These finite checks do not certify every QtSpim behavior.

## macOS UI comparison

Reference images were found in [Keio University’s macOS QtSpim lecture screenshots](https://web.sfc.keio.ac.jp/~rdv/keio/sfc/teaching/architecture/computer-architecture-2011/lec05-sim.html). The installed macOS QtSpim 9.1.24 was also opened for direct screenshot and accessibility-tree comparison. The [official r764 QtSpim sources](https://sourceforge.net/p/spimsimulator/code/764/tree/QtSpim/) confirm the default tab grouping and original F5/F10/Shift-F5 shortcuts.

| Area | Original Swift snapshot | Current Swift UI |
| --- | --- | --- |
| Registers | Integer and floating panels stacked; broad spacing | Compact register rows in Int/FP tabs |
| Code and memory | Text and Data stacked into short panes | Text/Data tabs with a larger inspection area |
| Messages | Small panel in the right column | Message area across the bottom |
| Console | Embedded in the main layout | Separate console window |
| Toolbar | Reduced action set | Load/reinitialize-load, log, print, clear-register and execution controls |
| Keyboard | Cmd aliases only | Original F5/F10/Shift-F5 plus Cmd aliases |

The current UI retains native SwiftUI controls and system icons. Floating inspectors share simulator state with the main window. Pane headers support drag placement and the Arrange menu provides equivalent tab/split commands. The default fonts are 14-point registers and 15-point code, data and console, as requested during native validation; all are adjustable in Settings.
