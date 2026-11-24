# Apple Silicon validation

Run from the extracted project root on an Apple Silicon Mac with a Swift 5.9+ toolchain:

```sh
uname -m                     # arm64
swift --version
swift test
./Scripts/build-app.sh
open dist/SwiftSpim.app
```

The bundle script requires a new destination; remove or rename a prior generated bundle yourself, or pass a different destination ending in `.app`.

## Smoke test

1. Launch the app, then load `Tests/SpimCoreTests/Fixtures/helloworld.s`. Confirm the text listing includes the user code and that the built-in startup handler is available.
2. Set a breakpoint at `main`. Run to the breakpoint, single-step, and observe PC and register changes. Continue and verify that the console prints `Hello World`, then the simulator stops.
3. Reinitialize, load `tt.core.s`, and supply the lines in `tt.in.txt` at the console prompts. Verify that no event-loop freeze occurs and that it reaches `Passed all tests`.
4. Toggle bare or delayed modes, open a separate pane, modify one register and one data word, and confirm the settings and panes behave across restarts.
5. Exercise Save Log and Print (use the system print dialog's PDF option if no printer is desired). Check that the output contains the selected panels.
6. Move the built app bundle outside the project directory, relaunch it, and repeat the Hello World test to confirm the copied exception-handler resource is found without relying on the project build directory.

## Current native validation

On November 23, 2026, the project compiled natively on Apple Silicon with Apple Swift 6.4.2 and the macOS 27.2 SDK. Desktop inspection recovered and the checklist was exercised:

- Loaded Hello World, stopped at `main`, single-stepped, continued, and observed `Hello World` and exit status zero.
- Reinitialized and loaded `tt.core.s`. The app waited for console input, resumed after the six fixture lines, and reached `Passed all tests`. Throttled UI updates and restricted automatic code scrolling fixed the initially observed timeout.
- Toggled bare/simple modes; verified dependent delay and pseudo controls. Changed delayed branches, quit, relaunched, and confirmed persistence before restoring the original setting.
- Opened a separate integer inspector, changed `$t0` to `0x12345678`, and confirmed the same value in the main window.
- In the final release, changed memory at `0x1001000c` to `0xcafebabe` and confirmed the displayed value. Register and memory editors expose accessibility actions as well as mouse gestures.
- Hid FP registers and selected Data; after a quit/relaunch, the pane visibility and active tab persisted. Restore Default Layout restored the register tab group.
- Exported all six panel selections to a text log and checked their headings and console pass marker.
- Used the system print dialog to save a 102-page core listing as PDF. PDFKit confirmed page count and integer/text/data/console headings plus `Passed all tests`.
- Launched a bundle from `/private/tmp`, outside the project, and completed the interactive core test using its bundled handler. The final release in `dist/SwiftSpim.app` also ran Hello World successfully.

## Post-review validation

Claude Code Opus 5.5 reviewed both the source and user manual; GPT-6.2 Astra assessed the findings. The decisions and closure ledger are in `Docs/Reviews/`.

- All 54 native tests pass (40 core and 14 debugger/layout/console).
- All seven original fixture comparisons, 29 focused regression comparisons, 4,758 instruction words and four memory layouts match the native original.
- The release app completed interactive `tt.core` after the six input lines, showing “Passed all tests” and exit status zero.
- Hello World stopped at `main`; Single Step moved PC to `0x00400028` and set `$v0` to 4; Continue printed `Hello World` and exited zero.
- Run Parameters Cancel discarded edits; reopening showed the prior empty values. Done accepted a new start/arguments draft.
- Console Dock Again, Data Float in Separate Window, and Arrange → Move → Below worked. The split layout survived quitting and relaunching. Dragging the register divider visibly changed the pane width.
- A console text-layout stall under runaway exception output was traced using a native CPU sample, then fixed with an explicit TextKit 1 stack. The new native console regression appends 100,000 lines and checks full contents, split UTF-8 repair and clearing.
- Native pointer drags verified Data → bottom split, Data → Text-header tab regrouping, and Data → outside the workspace opening an inspector.
- Register, code/data and console font sizes are now 14/15/15 points; Settings and the native screenshot confirmed the values.
- The final rebuilt release completed the six-input core test and visibly followed to “Passed all tests” in the small docked console, without redocking or resizing. A real 150-point NSHostingView regression checks that the pass-marker glyph lies inside both the scroll viewport and its host.

Logs and generated validation artifacts are under `.build/` and are ignored by Git. See `COMPATIBILITY.md` for the limits of these checks. This smoke test does not certify every QtSpim behavior.

In a restricted command environment, writable compiler caches may be needed:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache" \
swift test --disable-sandbox --cache-path "$PWD/.build/package-cache"
```

The bundle build and Launch Services launch were run outside the command sandbox, because nested SwiftPM sandbox creation and sandboxed Launch Services access failed. These environment restrictions do not establish an app defect.
