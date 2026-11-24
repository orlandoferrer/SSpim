#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SpimCore

@MainActor struct Workspace: View {
    @ObservedObject var debugger: Debugger
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 0) {
            if debugger.panels.subtracting(debugger.dock.floating).isEmpty {
                Button("Restore Debugger Panels") { debugger.restoreLayout() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DockTreeView(debugger: debugger, node: debugger.dock.root, path: [])
            }
            Divider()
            HStack {
                Circle().fill(debugger.running ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(debugger.statusLabel).lineLimit(1)
                Spacer()
                if let machine = debugger.machine { Text("PC \(Radix.hex.show(machine.pc))").monospacedDigit() }
                Text(debugger.files.map { $0.url.lastPathComponent }.joined(separator: ", ")).lineLimit(1)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { debugger.chooseFiles(reinitialize: false) } label: { Label("Load", systemImage: "folder") }
                Button { debugger.chooseFiles(reinitialize: true) } label: { Label("Reinitialize and Load File", systemImage: "folder.badge.plus") }
                Button { debugger.modal = .export } label: { Label("Save Log File", systemImage: "square.and.arrow.down") }
                Button { debugger.modal = .print } label: { Label("Print", systemImage: "printer") }
                Divider()
                Button { debugger.clearRegisters() } label: { Label("Clear Registers", systemImage: "tablecells") }.disabled(debugger.running)
            }
            ToolbarItemGroup(placement: .automatic) {
                Button { debugger.run() } label: { Label("Run", systemImage: "play.fill") }.keyboardShortcut("r").disabled(!debugger.mayExecute)
                Button { debugger.pause() } label: { Label("Pause", systemImage: "pause.fill") }.disabled(!debugger.running)
                Button { debugger.stop() } label: { Label("Stop", systemImage: "stop.fill") }.keyboardShortcut(".")
                Button { debugger.step() } label: { Label("Step", systemImage: "forward.end") }.keyboardShortcut("t").disabled(!debugger.mayExecute)
                Button { debugger.modal = .breakpoint } label: { Label("Breakpoint", systemImage: "octagon") }
                Button { debugger.reinitializeSimulator() } label: { Label("Reinitialize", systemImage: "arrow.counterclockwise") }
            }
        }
        .sheet(item: $debugger.modal) { modal in ModalView(debugger: debugger, modal: modal) }
        .sheet(item: $debugger.edit) { edit in EditView(debugger: debugger, edit: edit) }
        .alert("SwiftSpim", isPresented: Binding(get: { debugger.error != nil }, set: { if !$0 { debugger.error = nil } })) {
            Button("OK", role: .cancel) { debugger.error = nil }
        } message: { Text(debugger.error ?? "") }
        .onChange(of: debugger.registerRadix) { _ in debugger.savePreferences() }
        .onChange(of: debugger.dataRadix) { _ in debugger.savePreferences() }
        .onDisappear { debugger.savePreferences() }
        .onChange(of: debugger.panels.intersection(debugger.dock.floating)) { floating in
            for panel in floating { openWindow(id: panel.windowID) }
        }
    }
}
@MainActor struct ListingPanel: View {
    @ObservedObject var debugger: Debugger
    var body: some View {
        ScrollViewReader { reader in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(debugger.instructions, id: \.address) { row in
                        HStack(spacing: 12) {
                            Image(systemName: debugger.machine?.breakpoints.contains(row.address) == true ? "stop.circle.fill" : "circle")
                                .foregroundStyle(debugger.machine?.breakpoints.contains(row.address) == true ? Color.red : Color.secondary)
                                .onTapGesture { debugger.toggleBreakpoint(row.address) }
                                .accessibilityLabel("Toggle breakpoint at " + Radix.hex.show(row.address))
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { debugger.toggleBreakpoint(row.address) }
                            Text(Radix.hex.show(row.address)).foregroundStyle(.secondary)
                            if debugger.machineWords { Text(Radix.hex.show(debugger.machine?.instructionWord(at: row.address) ?? row.instruction.word)).foregroundStyle(.secondary) }
                            Text(SpimDisassembler.format(debugger.machine?.instructionWord(at: row.address) ?? row.instruction.word, at: row.address, delayedBranches: debugger.machineOptions.delayedBranches))
                                .frame(minWidth: 230, alignment: .leading)
                            if debugger.comments && !row.instruction.source.isEmpty {
                                Text("; \(row.instruction.line): \(row.instruction.source.split(whereSeparator: \.isWhitespace).joined(separator: " "))").foregroundStyle(.secondary)
                                    .help(row.instruction.filename)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(debugger.machine?.pc == row.address ? Color.accentColor.opacity(0.20) : .clear)
                        .id(row.address)
                        .contextMenu {
                            Button(debugger.machine?.breakpoints.contains(row.address) == true ? "Clear Breakpoint" : "Set Breakpoint") {
                                debugger.toggleBreakpoint(row.address)
                            }
                        }
                    }
                }.padding(.vertical, 3)
            }.onAppear {
                if let first = debugger.instructions.first?.address { reader.scrollTo(first, anchor: .topLeading) }
            }.onChange(of: debugger.machine?.pc) { address in
                // Following every run batch forces LazyVStack to materialize
                // thousands of intervening rows. Follow explicit debug stops.
                if let address, !debugger.running, debugger.machine?.status == .paused {
                    reader.scrollTo(address, anchor: UnitPoint(x: 0, y: 0.5))
                }
            }
        }.font(debugger.displayFont)
            .foregroundStyle(debugger.textColor).background(debugger.textBackground)
    }
}
@MainActor struct IntegerPanel: View {
    @ObservedObject var debugger: Debugger
    @State private var prior: [UInt32] = []
    @State private var changed = Set<Int>()
    var body: some View {
        ScrollView {
            if let cpu = debugger.machine {
                LazyVStack(alignment: .leading, spacing: 0) {
                    row("PC", cpu.pc, .pc)
                    row("EPC", cpu.coprocessor0[14], .cp0(14))
                    row("Cause", cpu.coprocessor0[13], .cp0(13))
                    row("BadVAddr", cpu.coprocessor0[8], .cp0(8))
                    row("Status", cpu.coprocessor0[12], .cp0(12))
                    Divider().padding(.vertical, 4)
                    row("HI", cpu.hi, .hi)
                    row("LO", cpu.lo, .lo)
                    Divider().padding(.vertical, 4)
                    ForEach(Array(cpu.registers.enumerated()), id: \.offset) { index, value in
                        row("R\(index) [\(index == 0 ? "r0" : index == 30 ? "s8" : MIPSListing.names[index])]", value, .integer(index), changed.contains(index))
                    }
                }.padding(6)
            }
        }.onChange(of: debugger.generation) { _ in
            if let cpu = debugger.machine {
                changed = Set(cpu.registers.indices.filter { $0 < prior.count && cpu.registers[$0] != prior[$0] })
                prior = cpu.registers
            }
        }.font(debugger.registerFont)
            .foregroundStyle(debugger.registerColor).background(debugger.registerBackground)
    }
    private func row(_ name: String, _ value: UInt32, _ target: FieldEdit.Target, _ changed: Bool = false) -> some View {
        let formatted = debugger.registerRadix.register(value)
        return HStack(spacing: 6) {
            Text(name.padding(toLength: 12, withPad: " ", startingAt: 0)).foregroundStyle(.secondary)
            Text("= " + formatted).foregroundStyle(changed && debugger.colorChangedRegisters ? debugger.changedRegisterColor : debugger.registerColor)
            Spacer(minLength: 0)
        }.padding(.horizontal, 4).padding(.vertical, 0).contentShape(Rectangle()).contextMenu {
            Button("Change Value…") { debugger.edit = FieldEdit(label: name, initial: Radix.hex.show(value), target: target) }
                .disabled(debugger.running)
        }.onTapGesture(count: 2) {
            guard !debugger.running else { return }
            debugger.edit = FieldEdit(label: name, initial: Radix.hex.show(value), target: target)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name + " " + formatted)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if !debugger.running { debugger.edit = FieldEdit(label: name, initial: Radix.hex.show(value), target: target) }
        }
    }
}
@MainActor struct FloatingPanel: View {
    @ObservedObject var debugger: Debugger
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ScrollView {
                if let cpu = debugger.machine {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text("FIR     = " + debugger.registerRadix.show(cpu.floatingControl[0]))
                        HStack {
                            Text("FCSR").foregroundStyle(.secondary)
                            Spacer()
                            Text(debugger.registerRadix.show(cpu.fcsr))
                        }.padding(.horizontal, 4).padding(.vertical, 3).contentShape(Rectangle()).contextMenu {
                            Button("Change Value…") { debugger.edit = FieldEdit(label: "FCSR", initial: Radix.hex.show(cpu.fcsr), target: .fcsr) }
                                .disabled(debugger.running)
                        }
                        Divider()
                        Text("Single Precision").font(.headline).padding(.vertical, 8)
                        ForEach(0..<cpu.floatingRegisters.count, id: \.self) { index in
                            let bits = cpu.floatingRegisters[index]
                            let text = String(Float(bitPattern: bits))
                            let edit = FieldEdit(label: "$f\(index)", initial: text, target: .floating(index))
                            HStack {
                                Text(edit.label).foregroundStyle(.secondary); Spacer(); Text(text)
                            }.padding(.horizontal, 4).padding(.vertical, 3).contentShape(Rectangle())
                                .contextMenu { Button("Change Value…") { debugger.edit = edit }.disabled(debugger.running) }
                                .onTapGesture(count: 2) { if !debugger.running { debugger.edit = edit } }
                        }
                        Text("Double Precision").font(.headline).padding(.vertical, 8)
                        ForEach(Array(stride(from: 0, to: 32, by: 2)), id: \.self) { index in
                            let text = String(cpu.doubleRegister(index))
                            HStack {
                                Text("$f\(index)").foregroundStyle(.secondary); Spacer(); Text(text)
                            }.padding(.horizontal, 4).padding(.vertical, 3).contentShape(Rectangle())
                                .contextMenu {
                                    Button("Change Value…") { debugger.edit = FieldEdit(label: "$f\(index)", initial: text, target: .double(index)) }.disabled(debugger.running)
                                }
                                .onTapGesture(count: 2) {
                                    if !debugger.running { debugger.edit = FieldEdit(label: "$f\(index)", initial: text, target: .double(index)) }
                                }
                        }
                    }.padding(6)
                }
            }.font(debugger.registerFont)
                .foregroundStyle(debugger.registerColor).background(debugger.registerBackground)
        }
    }
}
@MainActor struct MemoryPanel: View {
    @ObservedObject var debugger: Debugger
    var body: some View {
        ScrollViewReader { reader in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    TextField("Address or symbol", text: $debugger.jumpAddress)
                        .frame(maxWidth: 210).onSubmit {
                            if let address = debugger.number(debugger.jumpAddress) { reader.scrollTo(address & ~UInt32(15), anchor: .center) }
                        }
                    Picker("Format", selection: $debugger.dataRadix) {
                        ForEach(Radix.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(maxWidth: 145)
                    Spacer()
                }.padding(5)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(debugger.memoryRows) { row in
                            let address = row.address
                            VStack(alignment: .leading, spacing: 2) {
                                if let heading = row.heading {
                                    Text(heading).font(.caption.bold()).padding(.horizontal, 8)
                                }
                                if let description = row.zeroDescription {
                                    Button(description) { debugger.jumpAddress = Radix.hex.show(address) }
                                        .buttonStyle(.borderless).padding(.horizontal, 8)
                                } else {
                                HStack(spacing: 12) {
                                    Text(Radix.hex.show(address)).foregroundStyle(.secondary)
                                    ForEach(0..<4) { extra in
                                        let at = address &+ UInt32(extra * 4)
                                        let value = debugger.readWord(at: at)
                                        let edit = FieldEdit(label: "Memory \(Radix.hex.show(at))", initial: Radix.hex.show(value), target: .memory(at))
                                        Text(debugger.dataRadix.show(value)).frame(minWidth: 80, alignment: .leading)
                                            .contextMenu { Button("Change Value…") { debugger.edit = edit }.disabled(debugger.running) }
                                            .onTapGesture(count: 2) { if !debugger.running { debugger.edit = edit } }
                                            .accessibilityLabel("Memory " + Radix.hex.show(at) + ": " + debugger.dataRadix.show(value))
                                            .accessibilityAddTraits(.isButton)
                                            .accessibilityAction { if !debugger.running { debugger.edit = edit } }
                                    }
                                    Text(ascii(address)).foregroundStyle(.secondary)
                                }.padding(.horizontal, 8).padding(.vertical, 2)
                                }
                            }
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: true)
                            .id(address)
                        }
                    }.padding(.vertical, 4)
                }.onAppear {
                    if let first = debugger.memoryRows.first?.address { reader.scrollTo(first, anchor: .topLeading) }
                }.font(debugger.displayFont)
                    .foregroundStyle(debugger.textColor).background(debugger.textBackground)
            }
        }
    }
    private func ascii(_ at: UInt32) -> String {
        let bytes = (0..<16).map { i -> UInt8 in
            let byte = debugger.machine?.peekByte(at: at &+ UInt32(i)) ?? 0
            return (32...126).contains(byte) ? byte : 46
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
@MainActor struct ConsolePanel: View {
    @ObservedObject var debugger: Debugger
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Console").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { debugger.machine?.output = ""; debugger.refresh() }.buttonStyle(.borderless).font(.caption)
            }.padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            ConsoleTranscript(debugger: debugger)
            Divider()
            HStack {
                TextField("Program input", text: $debugger.input).onSubmit { debugger.sendInput() }
                Button("Send") { debugger.sendInput() }.disabled(debugger.machine == nil)
                if debugger.machineOptions.usesMappedIO {
                    Toggle("Append newline", isOn: $debugger.appendNewline).controlSize(.small)
                }
            }.padding(6)
        }.frame(minHeight: 100)
    }
}
@MainActor struct MessagesPanel: View {
    @ObservedObject var debugger: Debugger
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                Text(debugger.messages.joined(separator: "\n")).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6).id("end")
            }.onChange(of: debugger.messages) { _ in scroll.scrollTo("end", anchor: .bottom) }
        }.font(.system(.caption, design: .monospaced))
    }
}
#endif
