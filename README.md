# SSpim

SSpim contains SwiftSpim, a native Swift simulator and SwiftUI debugger port of [QtSpim](https://spimsimulator.sourceforge.net/) for Apple Silicon Macs. The behavioral reference is QtSpim/SPIM 9.1.24, official SourceForge SVN r764.

The Swift package is in [`SwiftSpim/`](SwiftSpim/). Start with the [user manual](SwiftSpim/usermanual.md), [project README](SwiftSpim/README.md), [compatibility record](SwiftSpim/Docs/COMPATIBILITY.md), and [native validation record](SwiftSpim/Docs/MACOS-VALIDATION.md).

```sh
cd SwiftSpim
swift test
bash Scripts/build-app.sh
open dist/SwiftSpim.app
```

The goal is full functional parity. The compatibility record documents the tested scope and remaining differences; the port is not certified as a complete replacement.

Original SPIM/QtSpim by James R. Larus and contributors. Upstream BSD-style notices are preserved in [THIRD_PARTY_NOTICES.txt](SwiftSpim/THIRD_PARTY_NOTICES.txt). A license for new SwiftSpim contributions has not been selected. Qt is not required or shipped.
