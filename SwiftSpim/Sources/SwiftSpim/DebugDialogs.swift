#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SpimCore

@MainActor struct ModalView: View {
    @ObservedObject var debugger: Debugger
    let modal: Modal
    @State private var draft: Debugger.RunParameters
    init(debugger: Debugger, modal: Modal) {
        self.debugger = debugger
        self.modal = modal
        _draft = State(initialValue: debugger.runParameters)
    }
    var title: String {
        switch modal {
        case .run: return "Run Parameters"
        case .symbols: return "Global Symbols"
        case .breakpoint: return "Set or Clear Breakpoint"
        case .hit: return "Breakpoint Reached"
        case .export: return "Save Log"
        case .print: return "Print"
        case .about: return "About SwiftSpim"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(title).font(.title2.bold())
            switch modal {
            case .run:
                TextField("Start address or label", text: $draft.address)
                TextField("Arguments (space-separated)", text: $draft.arguments)
                Text("Leave the address blank to use the simulator’s default entry point. These values are used on the next initialization.")
                    .font(.caption).foregroundStyle(.secondary)
            case .symbols:
                if let symbols = debugger.machine?.image.symbols, !symbols.isEmpty {
                    List(symbols.sorted { $0.key < $1.key }, id: \.key) { key, value in
                        HStack {
                            Text(key); Spacer(); Text(Radix.hex.show(value)).monospacedDigit()
                        }.textSelection(.enabled)
                    }.frame(height: 280)
                } else { Text("No symbols available.").foregroundStyle(.secondary) }
            case .breakpoint:
                TextField("Instruction address or label", text: $debugger.breakpointAddress)
                    .onSubmit { debugger.submitBreakpoint() }
                if let stops = debugger.machine?.breakpoints, !stops.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(stops.sorted(), id: \.self) { address in
                                HStack {
                                    Text(Radix.hex.show(address)).monospacedDigit()
                                    Spacer()
                                    Button("Clear") { debugger.toggleBreakpoint(address) }
                                }
                            }
                        }
                    }.frame(maxHeight: 200)
                }
            case .hit:
                Text("Execution stopped at \(Radix.hex.show(debugger.machine?.pc ?? 0)).")
            case .export, .print:
                Text("Choose which windows to include.").foregroundStyle(.secondary)
                ForEach(DebugPanel.allCases) { panel in
                    Toggle(panel.rawValue, isOn: Binding(get: { debugger.exports.contains(panel) }, set: { value in
                        if value { debugger.exports.insert(panel) } else { debugger.exports.remove(panel) }
                    }))
                }
            case .about:
                Text("A Swift and SwiftUI port of the SPIM MIPS32 simulator.")
                Text("Reference: QtSpim 9.1.24 (SVN r764)\nOriginal SPIM copyright © James R. Larus and contributors.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if modal == .hit {
                    Button("Abort") { debugger.modal = nil; debugger.stop() }.keyboardShortcut(.cancelAction)
                    Button("Single Step") { debugger.modal = nil; debugger.step() }
                    Button("Continue") { debugger.modal = nil; debugger.run() }.keyboardShortcut(.defaultAction)
                } else if modal == .symbols || modal == .about {
                    Button("Close") { debugger.modal = nil }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") {
                        if modal == .run { debugger.finishRunParameters(nil) }
                        else { debugger.modal = nil }
                    }.keyboardShortcut(.cancelAction)
                    Button(actionLabel) { commit() }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(20).frame(width: 460)
    }
    var actionLabel: String {
        switch modal {
        case .print: return "Print…"
        case .export: return "Choose File…"
        case .breakpoint: return "Toggle Breakpoint"
        default: return "Done"
        }
    }
    func commit() {
        switch modal {
        case .run:
            debugger.finishRunParameters(draft)
        case .breakpoint: debugger.submitBreakpoint()
        case .export:
            debugger.modal = nil
            Task { @MainActor in debugger.saveLog() }
        case .print:
            debugger.modal = nil
            Task { @MainActor in debugger.printLog() }
        default: debugger.modal = nil
        }
    }
}
@MainActor struct EditView: View {
    @ObservedObject var debugger: Debugger
    let edit: FieldEdit
    @State private var value: String
    init(debugger: Debugger, edit: FieldEdit) {
        self.debugger = debugger; self.edit = edit
        _value = State(initialValue: edit.initial)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change \(edit.label)").font(.title2.bold())
            TextField("Value", text: $value)
            HStack {
                Spacer()
                Button("Cancel") { debugger.edit = nil }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    debugger.edit = nil
                    debugger.apply(edit, value: value)
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 390)
    }
}
@MainActor struct Preferences: View {
    @ObservedObject var debugger: Debugger
    var body: some View {
        TabView {
            Form {
                HStack {
                    Button("Simple Machine") { debugger.configureBare(false) }
                    Button("Bare Machine") { debugger.configureBare(true) }
                }
                Toggle("Bare machine", isOn: Binding(
                    get: { debugger.options.bareMachine }, set: { debugger.options.bareMachine = $0 }))
                Toggle("Accept pseudo-instructions", isOn: $debugger.acceptPseudoInstructions)
                Toggle("Delayed branches", isOn: $debugger.options.delayedBranches)
                Toggle("Delayed loads", isOn: $debugger.options.delayedLoads)
                Toggle("Memory-mapped I/O", isOn: $debugger.options.mappedIO)
                Toggle("Little-endian memory", isOn: $debugger.options.littleEndian)
                Toggle("Quiet", isOn: $debugger.quiet)
                Stepper("Recent files: \(debugger.recentLimit)", value: $debugger.recentLimit, in: 0...30)
                Text("Machine options take effect on reinitialization or the next load.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding().tabItem { Text("Simulator") }
            Form {
                Toggle("Load exception handler", isOn: $debugger.options.loadExceptionHandler)
                Toggle("Use default exception handler", isOn: $debugger.useDefaultHandler)
                    .disabled(!debugger.options.loadExceptionHandler)
                HStack {
                    TextField("Custom exception handler path", text: $debugger.handlerPath)
                    Button("Choose…") { debugger.chooseHandler() }
                }.disabled(!debugger.options.loadExceptionHandler || debugger.useDefaultHandler)
                Divider()
                Toggle("Restrict guest file I/O to a selected folder", isOn: $debugger.options.restrictFileAccess)
                HStack {
                    Text(debugger.options.fileRootURL?.path ?? "No guest file folder selected")
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose File I/O Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false; panel.canChooseDirectories = true
                        if panel.runModal() == .OK { debugger.options.fileRootURL = panel.url; debugger.options.restrictFileAccess = true }
                    }
                    if debugger.options.fileRootURL != nil {
                        Button("Clear") { debugger.options.fileRootURL = nil }
                    }
                }
                Text("By default, file syscalls use host paths as in QtSpim. A selected folder confines guest paths to that folder; enabling the restriction without a folder disables file access.").font(.caption).foregroundStyle(.secondary)
            }.padding().tabItem { Text("Exceptions & I/O") }
            Form {
                Toggle("Highlight changed registers", isOn: $debugger.colorChangedRegisters)
                ColorPicker("Changed register color", selection: $debugger.changedRegisterColor)
                ColorPicker("Register text", selection: $debugger.registerColor)
                ColorPicker("Register background", selection: $debugger.registerBackground)
                fontPicker("Register font", selection: $debugger.registerFamily)
                Stepper("Register font size: \(Int(debugger.registerSize))", value: $debugger.registerSize, in: 9...30)
            }.padding().tabItem { Text("Registers") }
            Form {
                ColorPicker("Window text", selection: $debugger.textColor)
                ColorPicker("Window background", selection: $debugger.textBackground)
                ColorPicker("Console text", selection: $debugger.consoleColor)
                ColorPicker("Console background", selection: $debugger.consoleBackground)
                fontPicker("Window font", selection: $debugger.textFamily)
                fontPicker("Console font", selection: $debugger.consoleFamily)
                Stepper("Window font size: \(Int(debugger.textSize))", value: $debugger.textSize, in: 9...30)
                Stepper("Console font size: \(Int(debugger.consoleSize))", value: $debugger.consoleSize, in: 9...30)
            }.padding().tabItem { Text("Appearance") }
        }.frame(height: 330)
            .onChange(of: debugger.recentLimit) { _ in debugger.trimRecent(); debugger.savePreferences() }
            .onDisappear { debugger.savePreferences() }
    }
    func fontPicker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            Text("System Monospaced").tag("")
            ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
        }
    }
}
struct HelpPanel: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("SwiftSpim Help").font(.largeTitle.bold())
                section("Load a program", "Use File → Load File for a MIPS assembly source file. Load more files into the same session to resolve shared global symbols. Reinitialize and Load clears the simulator before opening another file. SwiftSpim assembles source text; it does not load compiled MIPS executables.")
                section("Run and debug", "Use Simulator → Run / Continue or Single Step. Click the breakpoint marker beside a text address, or enter an address or label in the breakpoint dialog. The highlighted row shows the current program counter. Double-click a register or memory word to edit its value while the simulator is paused.")
                section("Inspect the machine", "Registers and Data menus select binary, decimal, or hexadecimal views. The Text menu controls user/kernel instructions, encoded words, and source comments. The Data menu controls user data, the stack, and kernel data. Drag a pane tab onto another pane to group them, or onto its edge to split them. The Arrange menu also moves and floats panes. Dock Again returns a floating pane to its saved position. Tile Debugger Panels restores the standard tab groups.")
                section("Console input", "Enter input and press Return or Send. In memory-mapped I/O mode you can turn off Append newline to submit exact character sequences. Run resumes once input is supplied if it stopped to wait.")
                section("Simulator configuration", "Use Settings to choose the simple or bare machine, delay slots, memory-mapped I/O, and the bundled or custom exception handler. Reinitialize to apply new machine settings. File syscalls use host paths by default, as in QtSpim. Enable the optional file restriction and select a folder to confine guest files there; enabling the restriction without a folder disables host file access.")
                section("Save or print", "Use File → Save Log or Print to select which inspector data, messages, or console output to export.")
                Link("Original SPIM documentation", destination: URL(string: "https://spimsimulator.sourceforge.net/")!)
            }.padding(24).frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func section(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(detail).textSelection(.enabled)
        }
    }
}
#endif
