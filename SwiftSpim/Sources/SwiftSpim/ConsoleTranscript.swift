#if os(macOS)
import AppKit
import SwiftUI
import SpimCore

/// Append changes directly to text storage, retaining the at-most-three-byte
/// UTF-8 prefix that may be completed by the guest's next output operation.
@MainActor struct ConsoleTranscript: NSViewRepresentable {
    @ObservedObject var debugger: Debugger

    final class Coordinator {
        weak var machine: Machine?
        var byteCount = 0
        var pending = 0
        var pendingCharacters = 0
        var font: NSFont?
        var color: NSColor?
        let storage = NSTextStorage()
        var followScheduled = false
        var followsTail = true
        var observers: [NSObjectProtocol] = []
        var settled = false
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(state: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 480, height: 120))
    }

    func makeScrollView(state: Coordinator) -> NSScrollView {
        let initial = NSRect(x: 0, y: 0, width: 480, height: 180)
        let scroll = NSScrollView(frame: initial)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        // Construct the TextKit 1 stack explicitly. The default NSTextView
        // initializer opts into TextKit 2 on current macOS versions.
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        layout.backgroundLayoutEnabled = false
        state.storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: initial.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let text = NSTextView(frame: initial, textContainer: container)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 7, height: 6)
        text.setAccessibilityLabel("Program output")
        scroll.documentView = text
        state.observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main
        ) { [weak state, weak scroll, weak text] _ in
            MainActor.assumeIsolated {
                guard let scroll, let text, let event = NSApp.currentEvent,
                      [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) else { return }
                state?.followsTail = scroll.documentVisibleRect.maxY >= text.frame.maxY - 4
            }
        })
        text.postsFrameChangedNotifications = true
        state.observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: text, queue: .main
        ) { [weak state, weak scroll] _ in
            MainActor.assumeIsolated {
                if let state, let scroll { Self.followEnd(scroll, state: state) }
            }
        })
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        updateTranscript(scroll, state: context.coordinator)
    }

    func updateTranscript(_ scroll: NSScrollView, state: Coordinator) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let storage = state.storage
        let font = NSFont(name: debugger.consoleFamily, size: debugger.consoleSize)
            ?? .monospacedSystemFont(ofSize: debugger.consoleSize, weight: .regular)
        let color = NSColor(debugger.consoleColor)
        let style: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if state.font != font || state.color != color {
            storage.addAttributes(style, range: NSRange(location: 0, length: storage.length))
            state.font = font; state.color = color
        }
        view.backgroundColor = NSColor(debugger.consoleBackground)
        let machine = debugger.machine
        let bytes = machine?.outputBytes ?? []
        if state.machine !== machine || bytes.count < state.byteCount {
            storage.mutableString.setString("")
            state.machine = machine
            state.byteCount = 0; state.pending = 0; state.pendingCharacters = 0
            state.followsTail = true
        }
        let finished: Bool
        switch machine?.status {
        case .halted, .fault: finished = true
        default: finished = false
        }
        let justFinished = finished && !state.settled
        state.settled = finished
        guard state.byteCount != bytes.count else {
            if justFinished { Self.followEnd(scroll, state: state) }
            return
        }
        let from = state.byteCount - state.pending
        let tail = incompleteUTF8Prefix(bytes[from...])
        let split = bytes.count - tail
        let completed = String(decoding: bytes[from..<split], as: UTF8.self)
        let pending = String(decoding: bytes[split...], as: UTF8.self)
        let replace = NSRange(location: storage.length - state.pendingCharacters, length: state.pendingCharacters)
        storage.replaceCharacters(in: replace, with: NSAttributedString(string: completed + pending, attributes: style))
        state.byteCount = bytes.count
        state.pending = tail
        state.pendingCharacters = (pending as NSString).length
        Self.followEnd(scroll, state: state)
    }

    private static func followEnd(_ scroll: NSScrollView, state: Coordinator) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if state.followsTail && !state.followScheduled {
            state.followScheduled = true
            DispatchQueue.main.async { [weak scroll, weak view, weak state] in
                guard let state else { return }
                defer { state.followScheduled = false }
                guard state.followsTail, let scroll, let view, scroll.documentView === view,
                      let layout = view.layoutManager, let container = view.textContainer,
                      state.storage.length > 0 else { return }
                // TextKit 1 can lay out just the tail. Its final line rectangle
                // is available before AppKit updates the scroll document frame.
                let last = NSRange(location: state.storage.length - 1, length: 1)
                if state.settled { layout.ensureLayout(for: container) }
                else { layout.ensureLayout(forCharacterRange: last) }
                let glyphs = layout.glyphRange(forCharacterRange: last, actualCharacterRange: nil)
                let lastGlyph = layout.boundingRect(forGlyphRange: glyphs, in: container)
                let documentHeight = max(lastGlyph.maxY, layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
                let tail = ceil(documentHeight + 2 * view.textContainerInset.height)
                if tail > view.frame.height { view.setFrameSize(NSSize(width: view.frame.width, height: tail)) }
                let bottom = max(0, view.frame.maxY - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    private func incompleteUTF8Prefix(_ bytes: ArraySlice<UInt8>) -> Int {
        let suffix = bytes.suffix(3)
        guard let lead = suffix.lastIndex(where: { $0 & 0xc0 != 0x80 }) else { return 0 }
        let size: Int
        switch suffix[lead] {
        case 0xc2...0xdf: size = 2
        case 0xe0...0xef: size = 3
        case 0xf0...0xf4: size = 4
        default: return 0
        }
        let available = bytes.endIndex - lead
        return available < size ? available : 0
    }
}
#endif
