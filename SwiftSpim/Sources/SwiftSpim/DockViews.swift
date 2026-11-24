#if os(macOS)
import SwiftUI
import AppKit

@MainActor extension Debugger {
    func dropPane(_ panel: DebugPanel, at point: NSPoint) {
        if let (target, side) = dockTargets.destination(at: point) {
            if panel != target { move(panel, to: target, side: side) }
        } else if !dockTargets.containsWorkspaceWindow(at: point) && !dock.floating.contains(panel) {
            pendingFloatLocations[panel] = point
            float(panel)
        }
    }
    func float(_ panel: DebugPanel) {
        panels.insert(panel)
        dock.floating.insert(panel)
        savePreferences()
    }
    func redock(_ panel: DebugPanel) {
        panels.insert(panel)
        dock.floating.remove(panel)
        dock.select(panel)
        savePreferences()
    }
    func move(_ panel: DebugPanel, to target: DebugPanel, side: DockSide) {
        dock.move(panel, to: target, side: side)
        panels.formUnion([panel, target])
        savePreferences()
    }
}

@MainActor struct DebugPanelContent: View {
    @ObservedObject var debugger: Debugger
    let panel: DebugPanel
    var body: some View {
        switch panel {
        case .integer: IntegerPanel(debugger: debugger)
        case .floating: FloatingPanel(debugger: debugger)
        case .text: ListingPanel(debugger: debugger)
        case .data: MemoryPanel(debugger: debugger)
        case .messages: MessagesPanel(debugger: debugger)
        case .console: ConsolePanel(debugger: debugger)
        }
    }
}

@MainActor private struct DockActions: View {
    @ObservedObject var debugger: Debugger
    let panel: DebugPanel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if debugger.dock.floating.contains(panel) {
            Button("Dock Again") { debugger.redock(panel) }
        } else {
            Button("Float in Separate Window") {
                debugger.float(panel)
                openWindow(id: panel.windowID)
            }
        }
        Menu("Move " + panel.rawValue) {
            ForEach(DebugPanel.allCases.filter { $0 != panel }) { target in
                Menu(target.rawValue) {
                    ForEach(DockSide.allCases, id: \.self) { side in
                        Button(side.rawValue) { debugger.move(panel, to: target, side: side) }
                    }
                }
            }
        }
        Button("Hide Pane") { debugger.show(panel).wrappedValue = false }
    }
}

@MainActor struct DockTreeView: View {
    @ObservedObject var debugger: Debugger
    let node: DockNode
    let path: [Bool]
    @State private var dragStartFraction: Double?
    private var visible: Set<DebugPanel> { debugger.panels.subtracting(debugger.dock.floating) }

    @ViewBuilder var body: some View {
        switch node {
        case let .tabs(group, selection):
            let available = group.filter(visible.contains)
            if let active = available.contains(selection) ? selection : available.first {
                GeometryReader { _ in
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            ForEach(available) { panel in
                                Button(tabName(panel)) {
                                    debugger.dock.select(panel)
                                    debugger.saveDock()
                                }
                                .buttonStyle(.borderless)
                                .font(.caption.weight(active == panel ? .semibold : .regular))
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(active == panel ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                .accessibilityAddTraits(active == panel ? .isSelected : [])
                                .overlay(DockTabPointer(click: {
                                    debugger.dock.select(panel)
                                    debugger.saveDock()
                                }, drop: { debugger.dropPane(panel, at: $0) }))
                                .contextMenu { DockActions(debugger: debugger, panel: panel) }
                            }
                            Spacer(minLength: 0)
                            Menu { DockActions(debugger: debugger, panel: active) } label: {
                                Image(systemName: "rectangle.split.3x1")
                            }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Arrange " + active.rawValue)
                        }.padding(.horizontal, 5).padding(.vertical, 2)
                        Divider()
                        DebugPanelContent(debugger: debugger, panel: active)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(DockTargetArea(targets: debugger.dockTargets, activePanel: active))
                }
            }
        case let .split(horizontal, fraction, first, second):
            let showFirst = first.panels.contains(where: visible.contains)
            let showSecond = second.panels.contains(where: visible.contains)
            if showFirst && showSecond {
                GeometryReader { geometry in
                    let extent = max(1, (horizontal ? geometry.size.width : geometry.size.height) - 5)
                    let firstExtent = extent * fraction
                    let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    layout {
                        DockTreeView(debugger: debugger, node: first, path: path + [false])
                            .frame(width: horizontal ? firstExtent : nil, height: horizontal ? nil : firstExtent)
                            .clipped()
                        Rectangle().fill(Color(nsColor: .separatorColor))
                            .frame(width: horizontal ? 5 : nil, height: horizontal ? nil : 5)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .onChanged { value in
                                    let start = dragStartFraction ?? fraction
                                    dragStartFraction = start
                                    let delta = horizontal ? value.translation.width : value.translation.height
                                    debugger.dock.root = debugger.dock.root.resized(path: path[...], fraction: start + delta / extent)
                                }.onEnded { _ in dragStartFraction = nil; debugger.saveDock() })
                            .accessibilityLabel("Resize panes")
                        DockTreeView(debugger: debugger, node: second, path: path + [true])
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                }
            } else if showFirst { DockTreeView(debugger: debugger, node: first, path: path + [false]) }
            else if showSecond { DockTreeView(debugger: debugger, node: second, path: path + [true]) }
        }
    }
    private func tabName(_ panel: DebugPanel) -> String {
        switch panel {
        case .integer: return "Int Regs [" + (debugger.registerRadix == .hex ? "16" : debugger.registerRadix == .binary ? "2" : "10") + "]"
        case .floating: return "FP Regs"
        case .text: return "Text"
        case .data: return "Data"
        default: return panel.rawValue
        }
    }
}

@MainActor struct FloatingPane: View {
    @ObservedObject var debugger: Debugger
    let panel: DebugPanel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(panel.rawValue).font(.caption)
                    .overlay(DockTabPointer(click: {}, drop: { debugger.dropPane(panel, at: $0) }))
                Spacer()
                Button("Dock Again") { debugger.redock(panel) }.buttonStyle(.borderless)
                Menu("Arrange") { DockActions(debugger: debugger, panel: panel) }.fixedSize()
            }.padding(5)
            Divider()
            DebugPanelContent(debugger: debugger, panel: panel)
        }.frame(minWidth: 240, minHeight: 130)
        .background(PaneWindowObserver(debugger: debugger, panel: panel))
    }
}

@MainActor final class DebuggerAppDelegate: NSObject, NSApplicationDelegate {
    static var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.terminating = true
        return .terminateNow
    }
}

@MainActor private struct PaneWindowObserver: NSViewRepresentable {
    @ObservedObject var debugger: Debugger
    let panel: DebugPanel
    class WindowView: NSView {
        var attached: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attached?(window) }
        }
    }
    @MainActor final class Coordinator {
        weak var window: NSWindow?
        var token: NSObjectProtocol?
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        let coordinator = context.coordinator
        view.attached = { [weak debugger] window in
            guard let debugger, coordinator.window !== window else { return }
            coordinator.window = window
            window.setFrameAutosaveName("SwiftSpim-" + panel.windowID)
            // Window-menu commands and restored scenes can open an inspector directly.
            DispatchQueue.main.async { [weak window] in
                if let window, let point = debugger.pendingFloatLocations.removeValue(forKey: panel) {
                    let origin = NSPoint(x: point.x - 30, y: point.y + 12)
                    window.setFrameTopLeftPoint(origin)
                    let screen = NSScreen.screens.first { $0.frame.contains(point) }
                    window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: true)
                }
                if window?.isVisible == true, !debugger.dock.floating.contains(panel) || !debugger.panels.contains(panel) {
                    debugger.float(panel)
                }
            }
            if let token = coordinator.token { NotificationCenter.default.removeObserver(token) }
            coordinator.token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard !DebuggerAppDelegate.terminating, debugger.dock.floating.contains(panel) else { return }
                    debugger.show(panel).wrappedValue = false
                }
            }
        }
        return view
    }
    func updateNSView(_ view: WindowView, context: Context) {
        guard let window = context.coordinator.window, window.isVisible,
              !debugger.panels.contains(panel) || !debugger.dock.floating.contains(panel) else { return }
        DispatchQueue.main.async {
            if !debugger.panels.contains(panel) || !debugger.dock.floating.contains(panel) { window.close() }
        }
    }
}
#endif
