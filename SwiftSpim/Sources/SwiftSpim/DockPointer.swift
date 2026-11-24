#if os(macOS)
import AppKit
import SwiftUI

/// Pane geometry in screen coordinates also works when the source is in an inspector window.
@MainActor final class DockTargets {
    private let views = NSHashTable<DockTargetView>.weakObjects()
    func register(_ view: DockTargetView) { views.add(view) }

    func containsWorkspaceWindow(at screenPoint: NSPoint) -> Bool {
        views.allObjects.contains { view in
            guard let window = view.window, window.isVisible else { return false }
            return window.frame.contains(screenPoint)
        }
    }

    func destination(at screenPoint: NSPoint) -> (DebugPanel, DockSide)? {
        for view in views.allObjects {
            guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else { continue }
            let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            let bounds = view.bounds
            guard bounds.contains(point) else { continue }
            let x = point.x - bounds.minX
            let y = point.y - bounds.minY
            let side: DockSide
            if y < 32 { side = .tab }
            else if x < bounds.width * 0.22 { side = .left }
            else if x > bounds.width * 0.78 { side = .right }
            else if y < bounds.height * 0.25 { side = .above }
            else if y > bounds.height * 0.75 { side = .below }
            else { side = .tab }
            return (view.panel, side)
        }
        return nil
    }
}

@MainActor final class DockTargetView: NSView {
    var panel = DebugPanel.text
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor struct DockTargetArea: NSViewRepresentable {
    let targets: DockTargets
    let activePanel: DebugPanel
    func makeNSView(context: Context) -> DockTargetView {
        let view = DockTargetView()
        targets.register(view)
        return view
    }
    func updateNSView(_ view: DockTargetView, context: Context) { view.panel = activePanel }
}

/// A single responder interprets the press as either a click or a move. Mixing
/// an AppKit-backed button with a separate SwiftUI drag gesture steals mouseDown.
@MainActor struct DockTabPointer: NSViewRepresentable {
    let click: () -> Void
    let drop: (NSPoint) -> Void

    final class HitView: NSView {
        var click: (() -> Void)?
        var drop: ((NSPoint) -> Void)?
        private var start = NSPoint.zero
        private var moving = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            moving = false
        }
        override func mouseDragged(with event: NSEvent) {
            let position = event.locationInWindow
            if !moving && hypot(position.x - start.x, position.y - start.y) >= 4 {
                moving = true
                NSCursor.closedHand.push()
            }
        }
        override func mouseUp(with event: NSEvent) {
            let position = event.locationInWindow
            if moving || hypot(position.x - start.x, position.y - start.y) >= 4 {
                if moving { NSCursor.pop() }
                moving = false
                if let window { drop?(window.convertPoint(toScreen: event.locationInWindow)) }
            } else { click?() }
        }
    }
    func makeNSView(context: Context) -> HitView { HitView() }
    func updateNSView(_ view: HitView, context: Context) {
        view.click = click
        view.drop = drop
    }
}
#endif
