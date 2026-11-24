# SwiftSpim user manual

SwiftSpim is a Swift simulator and SwiftUI debugger for MIPS32 assembly programs on Apple Silicon Macs. It is a port of [SPIM/QtSpim](https://spimsimulator.sourceforge.net/), using QtSpim 9.1.24, SourceForge SVN revision 764, as its compatibility reference.

This manual describes the application and its auxiliary command-line simulator. See [COMPATIBILITY.md](Docs/COMPATIBILITY.md) for the current verification scope and remaining differences. SwiftSpim's port designation does not certify that every program or interaction is identical to QtSpim.

## 1. Build and launch

### Requirements

- An Apple Silicon Mac: `uname -m` should report `arm64`.
- macOS 13 or newer.
- Xcode or the Swift command-line tools, with Swift 5.9 or newer.

In Terminal, change to the extracted `SwiftSpim` directory containing `Package.swift`:

```sh
cd /path/to/SwiftSpim
swift test
bash Scripts/build-app.sh
open dist/SwiftSpim.app
```

The script creates a local app bundle. It does not install it in `/Applications`. Keep its `Contents` directory intact when moving the bundle. The exception-handler source is embedded in the simulator, and the app bundle also includes the handler resource and upstream notices. A local build is not a notarized distribution.

The script requires a destination that does not already exist. For another build, choose a new name:

```sh
bash Scripts/build-app.sh "$PWD/dist/SwiftSpim-next.app"
open dist/SwiftSpim-next.app
```

To make a debug bundle:

```sh
SWIFTSPIM_CONFIGURATION=debug bash Scripts/build-app.sh "$PWD/dist/SwiftSpim-debug.app"
```

You can also open this folder as a Swift package in Xcode and run the `SwiftSpim` executable scheme, or start it directly from Terminal:

```sh
swift run SwiftSpim
```

## 2. First run: Hello World

1. Launch SwiftSpim.
2. Choose **File → Reinitialize and Load File…** (`⇧⌘O`).
3. Select `Tests/SpimCoreTests/Fixtures/helloworld.s` from the project.
4. Select the **Text** tab. It shows instruction addresses, machine words, disassembly, and source comments. Startup and exception-handler instructions also appear when the default handler is enabled.
5. Choose **Simulator → Run / Continue** (`F5`) or click the Run triangle.
6. If the Console is hidden, choose **Window → Show Console**.
7. The console should display `Hello World`, and the status bar should eventually show **Exited (0)**.

On Mac keyboards that use the function row for media or system controls, hold `fn` or the Globe key with `F5` or `F10`, or use the menu/toolbar action.

For another clean run, use **Reinitialize and Load File…** again. For a restart that keeps existing memory and output, use **Clear Registers**, then Run. Pressing F5 alone after a completed Run is not a general restart command; see Section 5.

### Write your own source

SwiftSpim assembles source files; it does not load compiled MIPS executables or include a source editor. Write and save `.s` files in an external plain-text editor. For example:

```asm
.data
message: .asciiz "Hello from SwiftSpim\n"
.text
.globl main
main:
    li $v0, 4
    la $a0, message
    syscall
    li $v0, 10
    syscall
```

Load this with the default exception handler enabled. After editing a file, save it externally, then reload it. Source is read as UTF-8 when possible; legacy non-UTF-8 inputs use a Latin-1 interpretation that preserves their literal byte values.

## 3. Find your way around

The standard layout has tabbed register and segment panes, messages across the bottom, and a separate console:

| Area | Purpose |
| --- | --- |
| **Int Regs** / **FP Regs** | General-purpose and special CPU registers, or floating-point state. The integer-tab title includes its display base. |
| **Text** / **Data** | Live instructions and source, or memory words and ASCII bytes. |
| **Messages** | Assembly diagnostics, load/reset notices, runtime diagnostics, and guest standard-error output. |
| **Console** | Guest standard output and program input. |
| Status bar | Execution state, current PC, and loaded filenames. |

Click a pane's tab/header to select it. Drag dividers to resize areas. The defaults use 14-point Courier for registers and 15-point Courier for instruction/data text. The console uses a 15-point system monospaced font. Fonts and colors are adjustable in Settings.

**Registers → Display Format** selects hexadecimal, signed decimal, or binary integer values. The **Text Segment** menu selects user/kernel text, source/comments, and instruction values. The **Data Segment** menu selects user data, stack, kernel data, and its display format. These choices change presentation, not the stored bits: hexadecimal `ffffffff` and signed decimal `-1` represent the same word.

The layout, selected tabs, pane visibility, and floating-pane arrangement are remembered. See Section 10 for moving, floating, and redocking panes.

## 4. Load one or more files

### Load File (`⌘O`)

**File → Load File…** adds source to the current set of inputs. You can select several files. Loading a file already in the set rereads that file from disk.

SwiftSpim reassembles the input set and installs the changes into the live machine. It preserves the current execution state, including PC, registers, heap, stack capacity, queued input, open guest files, breakpoints, console output, and runtime changes that are not replaced by changed source. Newly assembled definitions and changed source data can update memory and code.

Use this command to add a supporting source file or resolve a forward reference. Use a clean reinitialize/load cycle when switching exercises or when you want all state reset. Loading a file after an exit does not itself rewind the PC.

### Reinitialize and Load File (`⇧⌘O`)

This command clears the simulator and current source set, then opens the file chooser. The reset occurs **before** the chooser opens. Cancelling the chooser leaves a fresh machine; it does not restore the prior program.

### Recent Files

**File → Recent Files** lists recently loaded paths. Selecting one uses normal Load behavior. **Clear Recent Files** removes entries without deleting source files. Settings controls the maximum list length.

### Multi-file symbols and load order

Declare shared definitions explicitly for predictable linkage:

```asm
# helper.s
.text
.globl helper
helper:
    # ...
    jr $ra
```

Use `.globl` or `.global` to export a definition. `.extern` and `.comm` also participate in global-symbol handling. Conventional startup names such as `main`, `__start`, and `__eoth` are treated as global. Ordinary local labels can be reused in separate files.

SPIM has an important load-order rule: an unresolved reference from an earlier input can resolve to a local definition in a later input. That does not export the local definition for subsequent inputs. Loading the defining local file first and the referencing file afterward can therefore leave the reference unresolved. An explicit `.globl helper` avoids depending on this asymmetry.

If several inputs define the same local label, its unqualified name is omitted from the debugger's visible symbol table. Use an unambiguous global name or numeric address for breakpoints/navigation. Adding a second independent program to the first can produce duplicate global definitions such as `main`; use **Reinitialize and Load File…** when changing programs.

### Diagnostics and partial assembly

Read Messages after loading. Semantic errors and warnings can leave following instructions assembled. A syntax error can stop parsing the current input while leaving earlier instructions and other loaded inputs available. A fatal directive such as `.err`, or an unreadable file, can prevent the load.

A “Loaded” message does not prove that the entire source assembled successfully. Undefined references may remain until another file is loaded; execution stops if it reaches an instruction with an unresolved reference.

## 5. Run, stop, and restart

| Action | Shortcut | Behavior |
| --- | --- | --- |
| **Run / Continue** | `F5`; toolbar also supports `⌘R` | Starts execution or continues from the current debug stop. |
| **Single Step** | `F10`; toolbar also supports `⌘T` | Executes one machine instruction and refreshes state. |
| **Pause** | Simulator menu or toolbar | Interrupts an active run for inspection. |
| **Stop** | `⇧F5`; toolbar also supports `⌘.` | Stops at the current PC and clears the current breakpoint bypass. |
| **Add or Remove Breakpoint…** | `⌘B` | Toggles a breakpoint by address or symbol. |

The PC identifies the next instruction to execute. Its row is highlighted when visible. A pseudo-instruction can expand into multiple machine instructions, so one step need not advance to the next source line. Branch and load delays also affect the order in which changes become visible.

### Break at `main`

1. Reinitialize and load `helloworld.s`.
2. Choose **Simulator → Add or Remove Breakpoint…** (`⌘B`).
3. Enter `main` and choose **Toggle Breakpoint**.
4. Run. **Breakpoint Reached** reports the stop address.
5. Choose **Single Step** to execute the instruction there, **Continue** to resume, or **Abort** to stop.

You can also click the marker beside an instruction or choose **Set Breakpoint** / **Clear Breakpoint** from its context menu. An active marker is red. The dialog lists current breakpoints with **Clear** buttons; entering an existing address toggles it off.

Breakpoint addresses must be word-aligned. Numeric input accepts decimal, hexadecimal prefixed with `0x`, or binary prefixed with `0b`; available labels are also accepted. An unprefixed number is decimal even when the pane displays hexadecimal.

**Abort does not clear the breakpoint or rewind the program.** At a breakpoint, Abort leaves PC unchanged and re-arms the stop at that address. The next Run can hit the same breakpoint again; choose Continue, single-step past it, or clear it.

### Re-run deliberately

- **Clean run:** Reinitialize and Load File, then Run. This clears runtime state and reloads source.
- **Restart with existing data/output:** Clear Registers, then Run. This resets CPU state and uses the configured entry point, while retaining data, console output, breakpoints, queued input, and open guest files. Rebuilding the argument/environment stack can overwrite its previous stack bytes.
- **Continue a stopped program:** Run after Pause or Stop keeps the current PC. It does not start again from `main`.

After a terminal result reached by **Run**, another Run retries the current PC. If PC is still on an exit syscall, it can simply exit again. After a terminal result reached by **Single Step**, the next Run/Step reapplies the configured entry and argument-stack setup. That entry setup does not clear other general registers or program data. Use the explicit restart commands above when you want a predictable initial state.

### What each control preserves

“Keep” means the control does not clear that state. An ensuing program run can change it normally.

| Control | PC and CPU registers | Program code/data | Console output |
| --- | --- | --- | --- |
| Pause | Keep current PC/registers | Keep | Keep |
| Stop / breakpoint Abort | Keep current PC/registers | Keep | Keep |
| Clear Registers | Reset registers and PC to zero; next execution selects the entry point | Keep; next entry setup rewrites argument/environment stack bytes | Keep |
| Load File | Keep live CPU state | Apply assembled additions/changes; preserve other runtime state | Keep |
| Reinitialize Simulator | Fresh machine | Remove loaded user sources; recreate startup/handler as configured | Clear |
| Reinitialize and Load File | Fresh machine | Reset, then assemble chosen sources | Clear |

| Control | Queued guest input | Open guest files and closed standard-stream state | Breakpoints |
| --- | --- | --- | --- |
| Pause | Keep | Keep | Keep |
| Stop / Abort | Keep | Keep | Keep; clear the current one-instruction bypass |
| Clear Registers | Keep | Keep | Keep |
| Load File | Keep | Keep | Keep |
| Either Reinitialize command | Clear | Close/reset | Clear |

These controls retain the Run Parameters fields and selected settings; reinitialization applies the current machine settings. They do not clear Messages history. The unsent text in the console input field is separate from bytes already queued for the guest.

## 6. Symbols, entry point, and arguments

**Simulator → Show Symbols…** opens names and addresses from the assembled image, including unambiguous local labels. Use a symbol or numeric address for a breakpoint, run address, or memory jump.

**Simulator → Set Run Parameters…** accepts an optional **Start address or label** and **Arguments (space-separated)**. **Done** commits the changes. **Cancel** or Escape discards the draft.

Set these values before the first Run/Step of a fresh machine. To apply changed parameters after execution has begun, commit them, then Clear Registers or Reinitialize and Load File before running.

A blank start address uses `__start`, normally supplied by the standard exception handler. It does not automatically select `main` when no startup handler is loaded. Without that handler, define an appropriate `__start` in your program or set the start field explicitly to `main` or its numeric address. An entry point of zero with no valid exception code leads to a fault rather than an automatic search for instructions. Starting directly at `main` skips the startup `jal` that sets `$ra`; for examples that finish with `jr $ra`, leave the start field blank or choose `__start`.

The GUI splits arguments on whitespace; shell-style quotation marks do not group text containing spaces. `argv[0]` is the full path of the most recently successfully loaded or reloaded source file, followed by your arguments. In a multi-file session this may be a helper file rather than the file containing `main`.

The guest stack contains the argument and inherited host-environment strings and pointer arrays. `$a0`, `$a1`, and `$a2` provide the corresponding argument count, argument-vector pointer, and environment-vector pointer. Initial stack addresses can therefore vary with launch environment and argument lengths.

Editing PC explicitly before the first execution retains that address while the argument/environment stack is prepared. Use a valid, aligned instruction address. A later manual PC edit redirects execution from the current state; it is not a data or register reset.

## 7. Console input and output

Choose **Window → Show Console** to reveal the console. By default it floats in a separate window; it can also be docked.

Enter a value in **Program input**, then press Return or **Send**. Outside effective memory-mapped I/O mode, submission always appends a newline and echoes the submitted text. A previous MMIO **Append newline** choice does not alter ordinary syscall input.

If a running program paused to wait for input, Send resumes it automatically. If you reached the input instruction by single-stepping, Send completes that request without starting an unrestricted run. After deliberately pressing Stop, use Run to continue; input can be queued while stopped.

**Clear** removes the displayed standard-output transcript. It does not clear memory, reset CPU state, or discard queued input. Guest standard error appears in Messages, separately from Console output.

The GUI decodes output bytes as UTF-8 for display. Invalid byte sequences can appear as replacement characters; the CLI preserves raw output bytes for redirection and binary comparisons.

### An interactive test program

Load `Tests/SpimCoreTests/Fixtures/tt.core.s`, Run, and provide the six lines from `tt.in.txt` in order:

```text
17
1717
17.18
1700.18
17.18e10
1700.18e10
```

This fixture deliberately exercises exceptions. Its successful completion marker is `Passed all tests`.

### Memory-mapped I/O

Enable **Memory-mapped I/O** in Settings, reinitialize, and load a polling program written for that mode. Device I/O is effective only when **Bare machine is off**, even if the MMIO preference is checked.

The effective MMIO console offers **Append newline**. Turn it off to send exact character sequences. A polling program may remain Running while waiting for input; submit characters while it runs. Echo depends on the guest program. Ordinary blocking syscall input and polling device input are different paths, so select the mode expected by the exercise.

## 8. Inspect and edit values

Pause or stop before editing. Number fields accept decimal, `0x` hexadecimal, `0b` binary, and available symbols unless noted otherwise.

### Integer and floating-point registers

The integer pane shows PC, EPC, Cause, BadVAddr, Status, HI, LO, and all 32 general-purpose registers. Double-click a row, or choose **Change Value…** from its context menu, enter a value, and **Apply**. Register 0 remains zero. Changed general registers can be highlighted using Settings.

The FP pane shows FIR, FCSR, single-precision registers, and double-precision register pairs. Scroll to the required section. Double-click a floating-point value or choose its **Change Value…** action. Enter a numeric value such as `1.5` or `-2e3`; lowercase `0x` enters raw 32-bit or 64-bit bits. Double values occupy paired registers in the configured guest byte order. FCSR is editable through its context menu; FIR is displayed.

### Live memory and zero-filled ranges

The Data pane shows user data, the used stack range, and kernel data, with segment headings and bounds. A normal row contains four 32-bit words and the corresponding ASCII bytes. Printable ASCII appears as text and other bytes as dots.

Long zero-filled areas are shown as compressed address ranges rather than thousands of identical rows. Click a compressed range to reveal its first row, or enter an address or symbol in **Address or symbol** and press Return to reveal and navigate to its aligned 16-byte row. The segment filters still control the normal segment listing.

Navigation can also inspect an instruction address, such as `main`, or a device-register address. The memory inspector reads live instruction words and device state without consuming input or acknowledging a device read. Editing a word at an instruction address changes executable code; the Text pane and log reflect live words, including instructions created at runtime. Runtime-written instructions may have no original source annotation.

Double-click a word or choose **Change Value…** to write it. The write must target valid mapped memory; invalid or unaligned writes produce a diagnostic. A memory/device edit has the effects of a simulator write, unlike a side-effect-free inspection.

## 9. Configure the simulator

Open **SwiftSpim → Settings…** (`⌘,`). Close Settings after editing so preferences are saved. For machine configuration changes, a clean Reinitialize and Load File cycle avoids mixing an old execution state with new options.

| Section | Controls |
| --- | --- |
| **Simulator** | Simple/bare presets, bare flag, pseudo permission, independent branch/load delays, MMIO, byte order, Quiet, recent-file limit. |
| **Exceptions & I/O** | Default/custom handler and optional guest-file restriction. |
| **Registers** | Changed-register highlighting, colors, font, size. |
| **Appearance** | Instruction/data and console colors, fonts, sizes. |

### Presets and independent controls

**Simple Machine** sets bare mode off, enables pseudo-instructions, and turns branch/load delays off. **Bare Machine** sets bare mode on, disables pseudo-instructions, and turns both delays on.

The individual checkboxes remain independent after choosing a preset: you can change delays separately rather than having bare mode silently force them back on. Bare mode still imposes the assembler's bare-instruction restrictions. MMIO polling remains inactive in bare mode.

**Quiet** suppresses routine load/reset, stop, breakpoint, and exit notices and optional CPU exception diagnostics. It does not suppress guest standard output, guest standard error, assembler diagnostics, undefined-symbol reports, or terminal fault reasons. Status still shows the current execution state. A handler's own output remains guest output even in Quiet mode.

### Exception handler

For introductory programs, enable **Load exception handler** and **Use default exception handler**. The bundled handler supplies startup code and default exception handling.

To use your own assembly handler, enable loading, turn off **Use default exception handler**, and choose its file. An empty custom path produces an actionable error; it does not silently fall back to the default. To load no handler, turn off **Load exception handler**. Reinitialize and load after changing these options.

### Guest file access

By default, guest file syscalls use host paths with the Mac user's existing permissions. Relative paths resolve against the process working directory, not automatically beside the `.s` file. Use an absolute path or a selected guest directory for a predictable location.

Enable **Restrict guest file I/O to a selected folder** and choose **Choose File I/O Folder…** to confine new opens. Choosing a folder also enables the restriction. Restricted guest paths must be relative to that folder; absolute paths, `..` traversal, symlinks within the guest path, and non-regular files are rejected.

Restriction enabled without a folder disables host file opens. **Clear** removes the selected folder. Turn restriction off to return to host-path behavior. Reinitialize before testing a changed policy so earlier open handles are also closed.

### Recover preferences

Layout, recent files, colors, fonts, display choices, and saved simulator options are stored in macOS preferences. Run Parameters, queued program input, and the running machine are session state rather than saved checkpoints.

To recover only the layout, choose **Window → Restore Default Layout**. For a broader reset, quit all instances of the bundled app, then run this in Terminal:

```sh
defaults delete org.swiftspim.local
```

This removes that bundle's saved preferences and recent-file list; it does not delete assembly sources. Relaunch and configure any desired options again. A development executable started through Xcode or `swift run` can use a different preferences domain; resetting the bundle domain does not promise to reset every development launch configuration.

## 10. Arrange, float, and dock panes

**Window → Show Integer Registers**, **Show Text Segments**, and the other **Show …** items control pane visibility. **Window → Open Separate Window → [pane]** floats the selected pane. The automatically listed inspector-window titles, such as **Integer Registers Inspector**, also open/focus floating inspectors; they are distinct from the visibility toggles.

### Drag a pane

Drag its tab/header onto another pane:

- Drop on the header or central area to group it **As Tab**.
- Drop near the left or right content edge to split panes side by side.
- Drop near the upper or lower content edge to split above/below. The header itself is a tab-group target.

Drag a divider to adjust the split. Drop a docked tab outside the workspace window to float it there. A floating pane's header is also draggable back into the main layout.

### Use the Arrange menu

The pane's Arrange control, shown as a split-rectangle icon in a docked header, offers:

- **Float in Separate Window**, or **Dock Again** for a floating pane.
- **Move [pane] → [target] → As Tab / To Left / To Right / Above / Below**.
- **Hide Pane**.

**Dock Again** returns a floating pane to its retained dock group. Closing a floating pane hides it; use its **Show …** item to reveal it again. All views share one simulator state.

**Tile Debugger Panels** restores the standard groups and makes both register and segment panes visible. **Restore Default Layout** also restores all pane visibility, including Messages and Console. The standard arrangement floats Console and docks Messages below the register/segment groups. These commands change layout, not the program or machine settings.

Dock groups, selections, split proportions, floating state, and pane visibility are saved; floating windows also remember their geometry.

## 11. Save logs and print

### Save Log (`⇧⌘S`)

Choose **File → Save Log…**, select the desired sections, choose **Choose File…**, and save a plain-text report. Available sections are integer registers, floating-point registers, text, data, console, and messages.

Integer reports include PC, EPC, Cause, BadVAddr, Status, HI, LO, and all general registers. FP reports include FIR, FCSR, singles with bits, and double pairs. Text reports use current instruction words and disassembly, including self-modifying code. Data reports include segment bounds and compressed zero ranges.

Text/data region filters and numeric formats affect the report where applicable. The text report includes words and source even if their display toggles are off in the pane. A report is not saved source or a resumable machine snapshot.

### Print or save PDF (`⌘P`)

Choose **File → Print…**, select sections, then **Print…**. Inspect the native macOS preview and choose a printer, or use **PDF** to save a PDF without a physical printer. Large instruction listings can span many pages. For only program output, select Console and deselect other sections.

## 12. Syscall reference

Place the service number in `$v0`, its arguments in the listed registers, then execute `syscall`. A result in `$v0` replaces the service number. Buffers and strings must occupy valid guest memory.

| `$v0` | Service | Arguments | Result/effect |
| --- | --- | --- | --- |
| 1 | Print integer | `$a0`: signed 32-bit value | Write decimal text to guest stdout. |
| 2 | Print float | `$f12`: single | Write a decimal representation with eight fractional digits. |
| 3 | Print double | Pair starting at `$f12` | Write a double representation with up to 18 significant digits. |
| 4 | Print string | `$a0`: NUL-terminated byte string | Write the bytes before the first NUL to stdout. |
| 5 | Read integer | Console/stdin input | `$v0`: parsed integer. |
| 6 | Read float | Console/stdin input | `$f0`: single result. |
| 7 | Read double | Console/stdin input | Pair starting at `$f0`: double result. |
| 8 | Read string | `$a0`: buffer; `$a1`: buffer capacity | Copy at most capacity minus one bytes, then NUL-terminate. Retain a newline if it fits. |
| 9 | Allocate data (`sbrk`) | `$a0`: nonnegative byte count | `$v0`: old heap end; allocation rounds to word alignment and obeys data/stack limits. |
| 10 | Exit | None | Halt with status zero. |
| 11 | Print character | `$a0`: character byte | Write its low eight bits to stdout. |
| 12 | Read character | Console/stdin input | `$v0`: a byte, using SPIM's signed-character result for bytes above 127. |
| 13 | Open | `$a0`: NUL-terminated path; `$a1`: native flags; `$a2`: creation mode | `$v0`: guest descriptor, or `-1` on failure. |
| 14 | Read file | `$a0`: descriptor; `$a1`: buffer; `$a2`: byte count | `$v0`: bytes read, zero at EOF, or `-1` for a file-operation error. No NUL is appended. |
| 15 | Write file | `$a0`: descriptor; `$a1`: buffer; `$a2`: byte count | `$v0`: bytes written, or `-1` on failure. |
| 16 | Close | `$a0`: descriptor | `$v0`: zero on success, or `-1` on failure. |
| 17 | Exit with code | `$a0`: status | Halt with that status; the CLI returns it to the host process. |

Read-integer/float/double operations use a line, up to their input bound of 255 bytes. For read-string, capacity one writes only a NUL and consumes no input; nonpositive capacity writes nothing. File read/write are byte operations and do not add line endings. File read and write (services 14 and 15) return `-1` for a buffer range that crosses the end of a mapped segment or wraps the address space. Invalid addresses in print-string and read-string (services 4 and 8) can raise a simulated memory exception.

At CLI EOF, no artificial input line is inserted. Numeric reads with no remaining bytes produce zero, read-string produces an empty NUL-terminated string when capacity permits, file read returns zero, and read-character returns the newline byte (`10`). Reading an actual NUL byte with service 12 also returns `10`. A final partial line is processed before subsequent EOF reads.

Descriptors 0, 1, and 2 represent guest stdin, stdout, and stderr. In the GUI, stdin comes from submitted console input, stdout goes to Console, and stderr goes to Messages. They are virtual guest streams: guest close does not close the application's own UI or host diagnostic handles. Do not assume an opened guest descriptor equals a particular host OS descriptor.

Open flags are the host's POSIX constants. Linux numeric values are not interchangeable with macOS values. File access also follows the optional restriction described above. There is no fixed 4 MiB read/write limit; valid buffer addresses, mapped capacities, available memory, and host file-operation behavior still apply. Heap allocation failure reports a capacity/run error rather than simulating a CP0 arithmetic/address exception.

## 13. Exceptions, faults, and Help

A simulated CPU exception records state in CP0 and vectors to `0x80000180`. **EPC** identifies the faulting location (or branch location for an exception in its delay slot); **Cause** identifies the exception and relevant pending-interrupt/delay information; **BadVAddr** records an applicable bad address. Inspect these alongside PC and the instruction listing.

The standard handler prints its exception information and often skips the faulting instruction before continuing. Some conditions terminate instead. A custom handler controls its own response. If no valid instruction is present at the exception vector, execution faults there; turning handler loading off does not disable CPU exception vectoring.

**Fault:** in the status bar means the simulator cannot continue that execution path, for example because it reached missing code, an unresolved reference, an unknown syscall, or a capacity error. Read Messages for the reason. Fix the source/settings, choose a valid entry, and restart deliberately rather than repeatedly executing the same bad PC. Quiet can hide optional CPU exception notices but preserves terminal fault diagnostics.

The **Help** menu provides **SwiftSpim Help** (`⌘?`), **Original SPIM Documentation**, and **About SPIM…**. The documentation link opens the original project's material; instruction and syscall availability should still be checked against SPIM's supported MIPS32 subset rather than an unrelated MIPS implementation.

## 14. Launch the app with SPIM options

Pass launch options to a new instance using `open -n --args`, or invoke the bundle executable directly. From the project folder:

```sh
open -n "$PWD/dist/SwiftSpim.app" --args -asm -file "/absolute/path/main.s"

"$PWD/dist/SwiftSpim.app/Contents/MacOS/SwiftSpim" \
  -mapped_io -file "/absolute/path/io.s" "/absolute/path/helpers.s"
```

In the **app**, everything after `-file` / `-f` is a source-file path, not guest arguments. Enter guest arguments through Run Parameters. A positional first filename also begins the app's source-file list. Use absolute source and handler paths when launching through `open` so resolution does not depend on its process working directory.

The app accepts:

- `-asm` / `-a`, `-bare` / `-b`.
- `-pseudo` / `-p`, `-nopseudo` / `-np`.
- `-delayed_branches` / `-db`, `-delayed_loads` / `-dl`.
- `-mapped_io` / `-mio`, `-nomapped_io` / `-nmio`.
- `-exception` / `-e` (also `-trap` / `-t`), `-noexception` / `-ne` (also `-notrap` / `-nt`).
- `-exception_file` / `-ef` (also `-trap_file` / `-tf`) followed by a handler path.
- `-quiet` / `-q`, `-noquiet` / `-nq`.
- The segment switches in Section 15, then `-file` / `-f` followed by sources.

Options are applied left to right. Launch `-asm` turns bare mode and both delays off; launch `-bare` turns bare mode and both delays on and enables Quiet. Unlike the **Settings preset buttons**, those launch switches leave pseudo permission independent; use `-pseudo` or `-nopseudo` explicitly when needed. A later `-exception` enables handler loading but retains an earlier custom handler selection; choose **Use default exception handler** in Settings to return to the bundled handler.

A successful file load saves simulator preferences such as bare mode, delays, MMIO, pseudo permission, handler choice, and Quiet. Thus a launch configuration can affect later normal launches. Inspect Settings to undo it, or use preference recovery. Segment capacities are session launch configuration and are not saved as preferences. GUI Run Parameters are not a replacement for the launch source list.

The app does not accept the auxiliary CLI's `--pc`, `--big-endian`, `--guest-directory`, `--no-file-io`, `--max-steps`, or `--dump-instruction-words` options. Use its Run Parameters and Settings for the corresponding GUI choices where available.

## 15. Use the command-line simulator

The CLI shares the assembler and simulator with the app and is useful for terminal runs, redirection, and comparisons. It is separate from the GUI launch parser. Examples assume a shell in the project folder:

```sh
swift run swiftspim-cli --help
swift run swiftspim-cli -file Tests/SpimCoreTests/Fixtures/helloworld.s
swift run swiftspim-cli -quiet -file Tests/SpimCoreTests/Fixtures/tt.core.s \
  < Tests/SpimCoreTests/Fixtures/tt.in.txt
```

Place simulator options before the first program filename. After `-file PROGRAM`, subsequent tokens are guest arguments, including `PROGRAM` as `argv[0]`. A positional program filename without `-file` has the same argument-boundary role:

```sh
swift run swiftspim-cli -quiet -file myprogram.s first-argument second-argument
```

Unlike the app, the CLI does not interpret these trailing tokens as more source files. Shell quotation can pass a guest argument containing spaces. The standard handler is embedded, so the built CLI executable can use it without an adjacent resource bundle.

| Option | Purpose |
| --- | --- |
| `-asm`, `-bare` | Select extended/bare mode and reset both delay flags off/on. `-bare` also enables Quiet. Pseudo permission remains independently controlled. |
| `-pseudo`, `-nopseudo` | Set pseudo permission; bare-mode restrictions still apply. |
| `-exception`, `-noexception` | Enable/disable the selected exception handler. |
| `-ef FILE` | Select a custom exception handler and enable loading. Later `-exception` retains that file. |
| `-delayed_branches`, `-delayed_loads` | Enable the respective delay behavior. |
| `-mapped_io`, `-nomapped_io` | Select MMIO; effective polling also requires non-bare mode. |
| `-quiet`, `-noquiet` | Suppress/enable optional startup and CPU exception notices; preserve guest output and errors. |
| `--big-endian` | Use big-endian guest memory; little-endian is the default. |
| `--pc ADDRESS` | Set a numeric decimal or `0x` hexadecimal entry. This CLI field does not accept a symbol. |
| `--dump-instruction-words` | Assemble without running; print sorted address/word pairs. Use `-quiet` to omit an optional Loaded notice. |
| `--guest-directory DIRECTORY` | Restrict guest host-file opens to that directory. |
| `--no-file-io` | Disable guest host-file opens and clear an earlier guest-directory selection. |
| `--max-steps COUNT` | Set the instruction budget; default 10,000,000. |

All options are processed left to right. A later `-asm` or `-bare` changes earlier delay choices but does not reset pseudo permission. A later file-policy option wins: `--no-file-io` after `--guest-directory` disables opens; a subsequent `--guest-directory` enables scoped access again.

Without startup-handler code, define `__start` or specify a numeric entry. For example, for bare source deliberately placed at `0x00400000`:

```sh
swift run swiftspim-cli -bare -noexception --pc 0x00400000 -file bare-program.s
swift run swiftspim-cli --guest-directory "$PWD/guest-files" -file file-example.s
swift run swiftspim-cli --no-file-io -file console-only.s
swift run swiftspim-cli --max-steps 50000000 -file long-program.s
```

Read stderr as well as stdout. For SPIM compatibility, some guest runtime failures finish the CLI with status zero while reporting a diagnostic. Host invocation/load errors and instruction-budget errors can return nonzero. Exit status alone does not prove correct guest execution.

### Segment switches

Both frontends accept positive decimal byte counts:

| Long / short form | Setting |
| --- | --- |
| `-stext` / `-st` | Initial user text capacity. |
| `-sdata` / `-sd` | Initial user data capacity. |
| `-ldata` / `-ld` | User data growth limit. |
| `-sstack` / `-ss` | Initial stack capacity. |
| `-lstack` / `-ls` | Stack growth limit. |
| `-sktext` / `-skt` | Initial kernel text capacity. |
| `-skdata` / `-skd` | Initial kernel data capacity. |
| `-lkdata` / `-lkd` | Kernel data growth limit. |

Initial sizes are rounded where required, and initial user data has a 64 KiB minimum. Unsafe sizes are rejected. GUI defaults use 256 KiB user text/data, while the CLI uses the upstream terminal defaults of 64 KiB text and 128 KiB data. Growth limits are separate from initial capacities.

The auxiliary CLI is not a copy of SPIM's terminal command interpreter. Its interactive simulator REPL and legacy `-assemble`, `-dump`, and `-full_dump` output-file modes are outside this interface. Use the GUI debugger for interactive inspection and `--dump-instruction-words` for address/word output.

## 16. Troubleshooting and verification

| Symptom | Check |
| --- | --- |
| Run/Step is unavailable | Load a source file; pause a current run before stepping. |
| Run immediately exits again | PC may still be on the exit syscall. Clear Registers then Run, or reinitialize/load for a clean restart. |
| Program output is missing | Use **Show Console**; check Messages for guest stderr and runtime faults. |
| Program appears stuck | Check Waiting for input, MMIO/bare configuration, and loops. Pause to inspect PC. |
| Undefined symbol | Check spelling, diagnostics, shared `.globl` declarations, and source load order. |
| Modified source seems ignored | Save externally, then reload; use a clean reinitialize/load cycle when comparing fresh executions. |
| Address/breakpoint rejected | Use an available label or aligned numeric address; prefix hexadecimal with `0x`. |
| No-handler run faults at zero/vector | Define `__start` or configure the entry point; provide exception code if the program needs it. |
| Wrong pseudo/delay behavior | Check individual settings and option order; presets and launch switches have distinct effects. |
| Guest file open fails | Check path, process working directory, permissions, native flags, and the selected restriction policy. |
| A pane is missing or crowded | Use its **Show …** item, resize dividers, or Restore Default Layout. |
| Register 0 does not change | It is fixed at zero. |
| CLI budget exceeded | Check for a loop or increase `--max-steps` for an intentionally long run. |
| Build destination exists | Choose a new `.app` destination. |

### Run the local tests

```sh
swift test
```

The [native validation checklist](Docs/MACOS-VALIDATION.md) covers application interactions. The [compatibility record](Docs/COMPATIBILITY.md) distinguishes tested behavior from remaining work.

### Build and compare the upstream reference

Obtain the official [r764 source tree](https://sourceforge.net/p/spimsimulator/code/764/tree/) using SourceForge's source snapshot or an SVN client. For example, with `svn` installed:

```sh
svn checkout -r 764 https://svn.code.sf.net/p/spimsimulator/code/ spim-r764
```

With the C++ command-line tools, `make`, `flex`, and `bison` available, build the terminal reference in its `spim` folder. No system installation is required for these comparisons:

```sh
upstream_dir="/absolute/path/to/spim-r764"
make -C "$upstream_dir/spim" -j4
export SPIM_REFERENCE="$upstream_dir/spim/spim"
export SPIM_EXCEPTION_FILE="$upstream_dir/CPU/exceptions.s"
```

Return to the SwiftSpim project directory and run:

```sh
bash Scripts/compare-upstream.sh
bash Scripts/compare-words.sh
bash Scripts/compare-memory-layout.sh
swift build --product swiftspim-cli
python3 Scripts/compare-regressions.py
```

The scripts compare selected fixture output/diagnostics/status, instruction words, segment settings, and focused runtime/assembler cases against that reference. They do not certify every UI action, timing path, malformed input, or guest program.

## Attribution

SPIM/QtSpim was created by James R. Larus and contributors. SwiftSpim retains the upstream copyright conditions and disclaimer in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt). Qt is not shipped or required by the SwiftUI application. See the repository's licensing information for the terms applying to its additional contributions.
