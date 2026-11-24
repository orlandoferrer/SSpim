#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SpimCore

enum Radix: String, CaseIterable, Identifiable {
    case hex = "Hexadecimal", decimal = "Decimal", binary = "Binary"
    var id: Self { self }
    func show(_ value: UInt32) -> String {
        switch self {
        case .hex: return String(format: "0x%08X", value)
        case .decimal: return String(Int32(bitPattern: value))
        case .binary: return String(value, radix: 2).leftPadded(to: 32)
        }
    }
    func register(_ value: UInt32) -> String {
        self == .hex ? String(value, radix: 16) : show(value)
    }
}
extension String {
    func leftPadded(to width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}
enum DebugPanel: String, CaseIterable, Identifiable, Codable {
    case integer = "Integer Registers", floating = "Floating-Point Registers"
    case text = "Text Segments", data = "Data Segments", console = "Console", messages = "Messages"
    var id: Self { self }
    var windowID: String {
        switch self {
        case .integer: return "integer"
        case .floating: return "floating"
        case .text: return "text"
        case .data: return "data"
        case .console: return "console"
        case .messages: return "messages"
        }
    }
}
enum Modal: String, Identifiable {
    case run, symbols, breakpoint, hit, export, print, about
    var id: String { rawValue }
}
struct FieldEdit: Identifiable {
    enum Target { case integer(Int), floating(Int), double(Int), memory(UInt32), cp0(Int), fcsr, pc, hi, lo }
    let id = UUID()
    let label: String
    let initial: String
    let target: Target
}
struct ProgramFile {
    let url: URL
    let input: SourceInput
}
@main @MainActor struct SwiftSpimApp: App {
    @NSApplicationDelegateAdaptor(DebuggerAppDelegate.self) private var appDelegate
    @StateObject private var debugger = Debugger()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup("SwiftSpim") {
            Workspace(debugger: debugger)
                .frame(minWidth: 780, minHeight: 520)
                .onOpenURL { debugger.load([$0], appending: true) }
                .task {
                    if debugger.machine == nil { debugger.launch(Array(CommandLine.arguments.dropFirst())) }
                    for panel in debugger.dock.floating.intersection(debugger.panels) { openWindow(id: panel.windowID) }
                }
        }
        .defaultSize(width: 1240, height: 800)
        .commands { DebugCommands(debugger: debugger) }
        Window("Console", id: "console") { FloatingPane(debugger: debugger, panel: .console) }
        .defaultSize(width: 620, height: 360)
        Window("Integer Registers Inspector", id: "integer") { FloatingPane(debugger: debugger, panel: .integer) }
        .defaultSize(width: 310, height: 500)
        Window("Floating-Point Registers Inspector", id: "floating") { FloatingPane(debugger: debugger, panel: .floating) }
        .defaultSize(width: 310, height: 500)
        Window("Text Segments Inspector", id: "text") { FloatingPane(debugger: debugger, panel: .text) }
        .defaultSize(width: 720, height: 420)
        Window("Data Segments Inspector", id: "data") { FloatingPane(debugger: debugger, panel: .data) }
        .defaultSize(width: 720, height: 420)
        Window("Messages Inspector", id: "messages") { FloatingPane(debugger: debugger, panel: .messages) }
        .defaultSize(width: 520, height: 260)
        Window("SwiftSpim Help", id: "help") { HelpPanel().frame(minWidth: 560, minHeight: 400) }
        .defaultSize(width: 680, height: 650)
        Settings { Preferences(debugger: debugger).padding(20).frame(width: 560) }
    }
}
@MainActor struct DebugCommands: Commands {
    @ObservedObject var debugger: Debugger
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Load File…") { debugger.chooseFiles(reinitialize: false) }.keyboardShortcut("o")
            Button("Reinitialize and Load File…") { debugger.chooseFiles(reinitialize: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
            Menu("Recent Files") {
                if debugger.recent.isEmpty { Text("No Recent Files") }
                ForEach(debugger.recent, id: \.self) { path in
                    Button(URL(fileURLWithPath: path).lastPathComponent) {
                        debugger.load([URL(fileURLWithPath: path)], appending: true)
                    }
                }
                Divider()
                Button("Clear Recent Files") { debugger.recent = []; debugger.savePreferences() }
                    .disabled(debugger.recent.isEmpty)
            }
        }
        CommandGroup(replacing: .printItem) {
            Button("Save Log…") { debugger.modal = .export }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Print…") { debugger.modal = .print }.keyboardShortcut("p")
        }
        CommandMenu("Simulator") {
            Button("Run / Continue") { debugger.run() }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: []).disabled(!debugger.mayExecute)
            Button("Single Step") { debugger.step() }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF10FunctionKey)!)), modifiers: []).disabled(!debugger.mayExecute)
            Button("Pause") { debugger.pause() }.disabled(!debugger.running)
            Button("Stop") { debugger.stop() }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: [.shift])
            Divider()
            Button("Set Run Parameters…") { debugger.modal = .run }
            Button("Show Symbols…") { debugger.modal = .symbols }
            Button("Add or Remove Breakpoint…") { debugger.modal = .breakpoint }.keyboardShortcut("b")
            Divider()
            Button("Clear Registers") { debugger.clearRegisters() }.disabled(debugger.running)
            Button("Reinitialize Simulator") { debugger.reinitializeSimulator() }
        }
        CommandMenu("Registers") {
            Picker("Display Format", selection: $debugger.registerRadix) { ForEach(Radix.allCases) { Text($0.rawValue).tag($0) } }
        }
        CommandMenu("Text Segment") {
            Toggle("User Text", isOn: $debugger.userText)
            Toggle("Kernel Text", isOn: $debugger.kernelText)
            Toggle("Source and Comments", isOn: $debugger.comments)
            Toggle("Instruction Values", isOn: $debugger.machineWords)
        }
        CommandMenu("Data Segment") {
            Toggle("User Data", isOn: $debugger.userData)
            Toggle("User Stack", isOn: $debugger.userStack)
            Toggle("Kernel Data", isOn: $debugger.kernelData)
            Picker("Display Format", selection: $debugger.dataRadix) { ForEach(Radix.allCases) { Text($0.rawValue).tag($0) } }
        }
        CommandGroup(after: .windowArrangement) {
            ForEach(DebugPanel.allCases) { panel in Toggle("Show " + panel.rawValue, isOn: debugger.show(panel)) }
            Divider()
            Menu("Open Separate Window") {
                ForEach(DebugPanel.allCases) { panel in
                    Button(panel.rawValue) {
                        debugger.float(panel)
                        openWindow(id: panel.windowID)
                    }
                }
            }
            Button("Tile Debugger Panels") { debugger.tileLayout() }
            Button("Restore Default Layout") { debugger.restoreLayout() }
        }
        CommandGroup(replacing: .help) {
            Button("SwiftSpim Help") { openWindow(id: "help") }.keyboardShortcut("?", modifiers: [.command])
            Link("Original SPIM Documentation", destination: URL(string: "https://spimsimulator.sourceforge.net/")!)
            Button("About SPIM…") { debugger.modal = .about }
        }
    }
}
#else
import Foundation

@main struct SwiftSpimApp {
    static func main() {
        print("SwiftSpim’s SwiftUI interface requires macOS. Use swiftspim-cli for the simulator on this platform.")
    }
}
#endif
