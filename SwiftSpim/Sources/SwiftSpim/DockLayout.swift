#if os(macOS)
import Foundation

enum DockSide: String, CaseIterable, Codable {
    case tab = "As Tab", left = "To Left", right = "To Right", above = "Above", below = "Below"
}

indirect enum DockNode: Codable, Equatable {
    case tabs([DebugPanel], selected: DebugPanel)
    case split(horizontal: Bool, fraction: Double, first: DockNode, second: DockNode)

    var panels: [DebugPanel] {
        switch self {
        case let .tabs(panels, _): return panels
        case let .split(_, _, first, second): return first.panels + second.panels
        }
    }

    var isValid: Bool {
        switch self {
        case let .tabs(panels, selected): return panels.contains(selected)
        case let .split(_, fraction, first, second):
            return (0.05...0.95).contains(fraction) && first.isValid && second.isValid
        }
    }

    func removing(_ panel: DebugPanel) -> DockNode? {
        switch self {
        case let .tabs(panels, selected):
            let remaining = panels.filter { $0 != panel }
            guard let first = remaining.first else { return nil }
            return .tabs(remaining, selected: remaining.contains(selected) ? selected : first)
        case let .split(horizontal, fraction, first, second):
            let a = first.removing(panel), b = second.removing(panel)
            if let a, let b { return .split(horizontal: horizontal, fraction: fraction, first: a, second: b) }
            return a ?? b
        }
    }

    func changingGroup(containing panel: DebugPanel, _ transform: (DockNode) -> DockNode) -> DockNode {
        switch self {
        case let .tabs(panels, _): return panels.contains(panel) ? transform(self) : self
        case let .split(horizontal, fraction, first, second):
            return .split(horizontal: horizontal, fraction: fraction,
                          first: first.changingGroup(containing: panel, transform),
                          second: second.changingGroup(containing: panel, transform))
        }
    }

    func resized(path: ArraySlice<Bool>, fraction: Double) -> DockNode {
        guard case let .split(horizontal, old, first, second) = self else { return self }
        guard let right = path.first else {
            return .split(horizontal: horizontal, fraction: min(0.95, max(0.05, fraction)), first: first, second: second)
        }
        return .split(horizontal: horizontal, fraction: old,
                      first: right ? first : first.resized(path: path.dropFirst(), fraction: fraction),
                      second: right ? second.resized(path: path.dropFirst(), fraction: fraction) : second)
    }
}

struct DockLayout: Codable, Equatable {
    var root: DockNode
    // Floating panels keep their dock position so that Dock Again restores their tab group.
    var floating: Set<DebugPanel>

    static var standard: DockLayout {
        let registers = DockNode.tabs([.integer, .floating], selected: .integer)
        let segments = DockNode.tabs([.text, .data], selected: .text)
        return DockLayout(root: .split(horizontal: false, fraction: 0.80,
            first: .split(horizontal: true, fraction: 0.23, first: registers, second: segments),
            second: .tabs([.messages, .console], selected: .messages)), floating: [.console])
    }

    var isValid: Bool {
        root.isValid && root.panels.count == DebugPanel.allCases.count && Set(root.panels) == Set(DebugPanel.allCases)
    }

    mutating func select(_ panel: DebugPanel) {
        root = root.changingGroup(containing: panel) { .tabs($0.panels, selected: panel) }
    }

    mutating func move(_ panel: DebugPanel, to target: DebugPanel, side: DockSide) {
        guard panel != target, let reduced = root.removing(panel) else { return }
        floating.remove(panel)
        floating.remove(target)
        root = reduced.changingGroup(containing: target) { group in
            if side == .tab { return .tabs(group.panels + [panel], selected: panel) }
            let new = DockNode.tabs([panel], selected: panel)
            let before = side == .left || side == .above
            return .split(horizontal: side == .left || side == .right, fraction: 0.5,
                          first: before ? new : group, second: before ? group : new)
        }
    }
}
#endif
