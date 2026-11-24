# SwiftSpim

SwiftSpim is a native **Swift and SwiftUI port of [QtSpim](https://spimsimulator.sourceforge.net/)** for Apple Silicon Macs. It uses the official [QtSpim/SPIM 9.1.24 source, SVN revision 764](https://sourceforge.net/p/spimsimulator/code/764/tree/) (August 2023) as the behavioral reference. The goal is a 1:1 functional port of the original application, not a clone of Qt's visual styling.

See the [user manual](usermanual.md) for debugger workflows, settings, console input, file access, printing, and CLI examples.

## Build and run

On an Apple Silicon Mac with macOS 13 or newer and a Swift 5.9 or newer toolchain, open this directory as a Swift package in Xcode and run the `SwiftSpim` scheme, or run:

```sh
swift run SwiftSpim
```

To build a local, unsigned macOS app bundle:

```sh
./Scripts/build-app.sh
open dist/SwiftSpim.app
```

Open a MIPS assembly file with **File → Load File**. Use the execution controls to run, pause or single-step. The application uses native debugger views for instructions, integer and floating-point registers, memory, and console I/O. As in QtSpim, editing assembly source happens in a separate editor.

The package also includes a command-line executable backed by the same engine, so its assembler and execution can be exercised independently of SwiftUI:

```sh
swift run swiftspim-cli -file Tests/SpimCoreTests/Fixtures/helloworld.s
swift run swiftspim-cli --help
```

## Verify compatibility

Run the Swift package tests with `swift test`. To compare against a locally built **upstream r764** SPIM binary, set `SPIM_REFERENCE` to that binary and `SPIM_EXCEPTION_FILE` to its `CPU/exceptions.s`, then run `./Scripts/compare-upstream.sh`. This comparison exercises upstream fixture programs with identical flags and input; it does not by itself verify the SwiftUI interface. With the same environment variables, run `./Scripts/compare-words.sh` and `./Scripts/compare-memory-layout.sh` to check encoded instruction words and legacy memory settings. Run `python3 Scripts/compare-regressions.py` for focused diagnostic, raw-byte I/O, stack ABI and option-order comparisons. The code/manual peer reviews and Astra decisions are in [Docs/Reviews](Docs/Reviews/).

See [compatibility status](Docs/COMPATIBILITY.md) for verified behavior and outstanding gaps. Full compatibility is not implied by the port title or by a successful build. Follow the [Apple Silicon validation checklist](Docs/MACOS-VALIDATION.md) for native UI testing.

## Upstream attribution

Original SPIM/QtSpim by James R. Larus and contributors. Upstream notices, the BSD conditions and disclaimer, and bundled-source provenance are in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt). Qt is not shipped or required for the SwiftUI port.
