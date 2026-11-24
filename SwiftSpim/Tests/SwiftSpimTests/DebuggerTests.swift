#if os(macOS)
import XCTest
import AppKit
import SwiftUI
import SpimCore
@testable import SwiftSpim

final class DockLayoutTests: XCTestCase {
    @MainActor func testMovingAcrossGroupsAndPersistingSplit() async throws {
        // A hidden native window supplies screen conversion without stealing focus.
        let window = NSWindow(contentRect: NSRect(x: 100, y: 120, width: 250, height: 140),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let pointer = DockTabPointer.HitView(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        window.contentView?.addSubview(pointer)
        var clicks = 0
        var dropped: NSPoint?
        pointer.click = { clicks += 1 }
        pointer.drop = { dropped = $0 }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                            clickCount: 1, pressure: 1))
        }
        let origin = NSPoint(x: 15, y: 10), destination = NSPoint(x: 160, y: 70)
        pointer.mouseDown(with: try event(.leftMouseDown, origin))
        pointer.mouseUp(with: try event(.leftMouseUp, origin))
        XCTAssertEqual(clicks, 1)
        pointer.mouseDown(with: try event(.leftMouseDown, origin))
        pointer.mouseDragged(with: try event(.leftMouseDragged, destination))
        pointer.mouseUp(with: try event(.leftMouseUp, destination))
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(dropped, window.convertPoint(toScreen: destination))
        var layout = DockLayout.standard
        layout.move(.integer, to: .text, side: .tab)
        layout.move(.data, to: .integer, side: .below)
        layout.move(.messages, to: .console, side: .left)
        layout.root = layout.root.resized(path: [], fraction: 0.72)
        layout.floating.insert(.data)
        layout.select(.integer)
        XCTAssertTrue(layout.isValid)
        XCTAssertTrue(layout.floating.contains(.data))
        XCTAssertFalse(layout.floating.contains(.console))
        XCTAssertEqual(try JSONDecoder().decode(DockLayout.self, from: JSONEncoder().encode(layout)), layout)
        for panel in DebugPanel.allCases {
            for target in DebugPanel.allCases where target != panel {
                for side in DockSide.allCases {
                    layout.move(panel, to: target, side: side)
                    XCTAssertTrue(layout.isValid)
                }
            }
        }
    }
}

final class DebuggerTests: XCTestCase {
    @MainActor private func withDebugger(_ body: (Debugger, URL) async throws -> Void) async throws {
        let suite = "swiftspim-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        let debugger = Debugger(defaults: defaults, environment: { ["TEST=fixture"] })
        debugger.options.loadExceptionHandler = false
        try await body(debugger, dir)
    }

    @MainActor func testRunParameterDraftOnlyCommitsOnDone() async throws {
        try await withDebugger { debugger, _ in
            debugger.arguments = "original"
            let original = debugger.runParameters
            var draft = original
            draft.address = "main"
            draft.arguments = "one two"
            debugger.modal = .run
            debugger.finishRunParameters(nil)
            XCTAssertNil(debugger.modal)
            XCTAssertEqual(debugger.runParameters, original)
            debugger.modal = .run
            debugger.finishRunParameters(draft)
            XCTAssertNil(debugger.modal)
            XCTAssertEqual(debugger.runParameters, draft)
        }
    }

    @MainActor func testCustomHandlerAllowsExtendedAssemblyWithBareUserCode() async throws {
        try await withDebugger { debugger, dir in
            let handler = dir.appendingPathComponent("handler.s")
            let source = dir.appendingPathComponent("guest.s")
            try ".text\n.globl __start\n__start: li $t0,0x12345678\n".write(to: handler, atomically: true, encoding: .utf8)
            try ".text\n.globl main\nmain: addiu $v0,$0,10\nsyscall\n".write(to: source, atomically: true, encoding: .utf8)
            debugger.configureBare(true)
            debugger.options.delayedBranches = false
            debugger.options.delayedLoads = false
            debugger.options.loadExceptionHandler = true
            debugger.useDefaultHandler = false
            debugger.handlerPath = handler.path
            debugger.load([source], appending: false)
            let machine = try XCTUnwrap(debugger.machine)
            XCTAssertTrue(machine.options.bareMachine)
            XCTAssertFalse(machine.options.acceptPseudoInstructions)
            XCTAssertFalse(machine.options.delayedBranches)
            XCTAssertFalse(machine.options.delayedLoads)
            XCTAssertTrue(machine.image.diagnostics.isEmpty)
            debugger.step()
            debugger.step()
            XCTAssertEqual(machine.registers[8], 0x12345678)
        }
    }

    @MainActor func testContinueFromInputBreakpointCompletesSyscallOnce() async throws {
        try await withDebugger { debugger, dir in
            let url = dir.appendingPathComponent("read.s")
            try ".text\n.globl __start\n__start: li $v0,5\nread_here: syscall\nmove $s0,$v0\nli $v0,10\nsyscall\n".write(to: url, atomically: true, encoding: .utf8)
            debugger.load([url], appending: false)
            let machine = try XCTUnwrap(debugger.machine)
            let address = try XCTUnwrap(machine.image.symbols["read_here"])
            debugger.toggleBreakpoint(address)
            debugger.run()
            for _ in 0..<100 where debugger.running { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(debugger.modal, .hit)
            XCTAssertEqual(machine.pc, address)
            debugger.modal = nil
            debugger.run()
            for _ in 0..<100 where debugger.running { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(machine.status, .waitingInput)
            debugger.input = "43"
            debugger.sendInput()
            for _ in 0..<100 where debugger.running { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertNil(debugger.modal)
            XCTAssertEqual(machine.status, .halted(0))
            XCTAssertEqual(machine.registers[16], 43)
        }
    }

    @MainActor func testPCEditKeepsArgvAndReloadTracksMostRecentURL() async throws {
        try await withDebugger { debugger, dir in
            let main = dir.appendingPathComponent("a.s"), helper = dir.appendingPathComponent("b.s")
            try ".text\n.globl __start\n__start: nop\nentry: move $t0,$a0\n".write(to: main, atomically: true, encoding: .utf8)
            try ".text\nhelper: nop\n".write(to: helper, atomically: true, encoding: .utf8)
            debugger.recentLimit = 0
            debugger.load([main, helper], appending: true)
            let machine = try XCTUnwrap(debugger.machine)
            debugger.load([main], appending: true)
            XCTAssertTrue(machine === debugger.machine)
            debugger.arguments = "one two"
            let address = try XCTUnwrap(machine.image.symbols["entry"])
            debugger.apply(.init(label: "PC", initial: "", target: .pc), value: String(address))
            debugger.step()
            XCTAssertEqual(machine.registers[8], 3)
            XCTAssertEqual(machine.arguments, [main.path, "one", "two"])
            XCTAssertTrue(debugger.recent.isEmpty)
        }
    }

    @MainActor func testEffectiveConsoleModeAndSourceFailureVisibility() async throws {
        try await withDebugger { debugger, dir in
            let source = dir.appendingPathComponent("p.s")
            try ".text\n.globl __start\n__start: addiu $2,$0,5\nsyscall\n".write(to: source, atomically: true, encoding: .utf8)
            debugger.quiet = true
            debugger.options.bareMachine = true
            debugger.options.mappedIO = true
            debugger.appendNewline = false
            debugger.load([source], appending: false)
            debugger.step()
            debugger.step()
            XCTAssertEqual(debugger.machine?.status, .waitingInput)
            debugger.input = "17"
            debugger.sendInput()
            XCTAssertEqual(debugger.machine?.registers[2], 17)
            XCTAssertEqual(debugger.machine?.output, "17\n")
            debugger.useDefaultHandler = false
            debugger.options.loadExceptionHandler = true
            debugger.reinitializeSimulator()
            XCTAssertNil(debugger.machine)
            XCTAssertTrue(debugger.messages.last(where: { $0.contains("Choose a custom exception handler") }) != nil)
        }
    }

    @MainActor func testStepTerminationRestartsWhileRepeatedRunKeepsExitPC() async throws {
        let suite = "swiftspim-run-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".s")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        let debugger = Debugger(defaults: defaults, environment: { [] })
        debugger.options.loadExceptionHandler = false
        try ".text\n.globl __start\n__start: addiu $t0,$t0,1\nli $v0,10\nsyscall\n".write(to: url, atomically: true, encoding: .utf8)
        debugger.load([url], appending: false)
        let machine = try XCTUnwrap(debugger.machine)
        debugger.step()
        debugger.step()
        debugger.step()
        XCTAssertEqual(machine.status, .halted(0))
        XCTAssertTrue(debugger.mayExecute)
        debugger.step()
        XCTAssertEqual(machine.registers[8], 2)
        debugger.run()
        for _ in 0..<100 where debugger.running { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(machine.status, .halted(0))
        let exit = machine.pc
        debugger.run()
        for _ in 0..<100 where debugger.running { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(machine.pc, exit)
        XCTAssertEqual(machine.registers[8], 2)
        XCTAssertEqual(machine.status, .halted(0))
    }

    @MainActor func testRunSamplesPendingInterruptAtQtBatchBoundaries() async throws {
        try await withDebugger { debugger, dir in
            let url = dir.appendingPathComponent("pending.s")
            for (iterations, expectedHandler) in [(2_000, UInt32(0)), (60_000, UInt32(1))] {
                let source = """
                .text
                .globl __start
                __start: li $t0,0x101
                mtc0 $t0,$12
                li $t0,0x100
                mtc0 $t0,$13
                li $t1,\(iterations)
                count_loop: addiu $t1,$t1,-1
                bnez $t1,count_loop
                li $v0,10
                syscall
                .ktext 0x80000180
                handler: li $s0,1
                li $v0,10
                syscall
                """
                try source.write(to: url, atomically: true, encoding: .utf8)
                debugger.load([url], appending: false)
                let machine = try XCTUnwrap(debugger.machine)
                debugger.run()
                let limit = ProcessInfo.processInfo.systemUptime + 5
                while debugger.running && ProcessInfo.processInfo.systemUptime < limit {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                XCTAssertEqual(machine.status, .halted(0))
                XCTAssertEqual(machine.registers[16], expectedHandler)
            }
        }
    }

    @MainActor func testRunLoopRemainsInterruptibleDuringInfiniteGuest() async throws {
        let suite = "swiftspim-pause-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".s")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        let debugger = Debugger(defaults: defaults, environment: { [] })
        debugger.options.loadExceptionHandler = false
        try ".text\n.globl __start\n__start: addiu $t0,$t0,1\nj __start\nnop\n".write(to: url, atomically: true, encoding: .utf8)
        debugger.load([url], appending: false)
        let machine = try XCTUnwrap(debugger.machine)
        debugger.run()
        try await Task.sleep(nanoseconds: 35_000_000)
        debugger.pause()
        let paused = machine.instructionCount
        XCTAssertGreaterThan(paused, 0)
        XCTAssertFalse(debugger.running)
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(machine.instructionCount, paused)
    }

    @MainActor func testLaunchAndDockPreferencesRoundTrip() async throws {
        let suite = "swiftspim-layout-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let debugger = Debugger(defaults: defaults, environment: { [] })
        XCTAssertEqual(debugger.registerSize, 14)
        XCTAssertEqual(debugger.textSize, 15)
        XCTAssertEqual(debugger.consoleSize, 15)
        debugger.launch(["-NSDocumentRevisionsDebugMode", "YES", "-nopseudo", "-asm", "-noexception"])
        XCTAssertNil(debugger.error)
        XCTAssertFalse(debugger.acceptPseudoInstructions)
        XCTAssertFalse(debugger.options.bareMachine)
        debugger.move(.messages, to: .data, side: .left)
        debugger.float(.data)
        debugger.show(.floating).wrappedValue = false
        let restored = Debugger(defaults: defaults, environment: { [] })
        XCTAssertEqual(restored.dock, debugger.dock)
        XCTAssertFalse(restored.panels.contains(.floating))
        restored.redock(.data)
        XCTAssertFalse(restored.dock.floating.contains(.data))
        XCTAssertTrue(restored.dock.isValid)
        let outside = NSPoint(x: 900, y: 500)
        restored.dropPane(.integer, at: outside)
        XCTAssertTrue(restored.dock.floating.contains(.integer))
        XCTAssertEqual(restored.pendingFloatLocations[.integer], outside)

        defaults.set(1, forKey: "compactLayoutVersion")
        defaults.set("Courier", forKey: "registerFamily")
        defaults.set(10.0, forKey: "registerSize")
        defaults.set("Menlo", forKey: "textFamily")
        defaults.set(11.0, forKey: "textSize")
        defaults.set("", forKey: "consoleFamily")
        defaults.set(13.0, forKey: "consoleSize")
        let migrated = Debugger(defaults: defaults, environment: { [] })
        XCTAssertEqual(migrated.registerSize, 14)
        XCTAssertEqual(migrated.textSize, 11)
        XCTAssertEqual(migrated.textFamily, "Menlo")
        XCTAssertEqual(migrated.consoleSize, 15)
        defaults.set(10.0, forKey: "registerSize")
        XCTAssertEqual(Debugger(defaults: defaults, environment: { [] }).registerSize, 10)
    }

    @MainActor func testGuestStandardErrorRemainsVisibleInQuietMode() async throws {
        try await withDebugger { debugger, dir in
            let source = dir.appendingPathComponent("stderr.s")
            try ".data\nmsg: .asciiz \"bad input\"\n.text\n.globl __start\n__start: li $v0,15\nli $a0,2\nla $a1,msg\nli $a2,9\nsyscall\nli $v0,10\nsyscall\n".write(to: source, atomically: true, encoding: .utf8)
            debugger.quiet = true
            debugger.load([source], appending: false)
            let machine = try XCTUnwrap(debugger.machine)
            for _ in 0..<20 where machine.status != .halted(0) { debugger.step() }
            XCTAssertEqual(machine.status, .halted(0))
            XCTAssertEqual(machine.output, "")
            XCTAssertTrue(debugger.messages.contains("bad input"))
        }
    }

    @MainActor func testConsoleTranscriptAppendsLongOutputAndRepairsSplitUTF8() async throws {
        try await withDebugger { debugger, dir in
            let url = dir.appendingPathComponent("output.s")
            try ".text\n.globl __start\n__start: nop\n".write(to: url, atomically: true, encoding: .utf8)
            debugger.load([url], appending: false)
            let machine = try XCTUnwrap(debugger.machine)
            let transcript = ConsoleTranscript(debugger: debugger)
            let state = transcript.makeCoordinator()
            let scroll = transcript.makeScrollView(state: state)
            let view = try XCTUnwrap(scroll.documentView as? NSTextView)
            XCTAssertNil(view.textLayoutManager)
            let block = Array(String(repeating: "01234567890 abcdefghijklmnopqrstuvwxyz\n", count: 2_000).utf8)
            for _ in 0..<50 {
                machine.outputBytes.append(contentsOf: block)
                transcript.updateTranscript(scroll, state: state)
                await Task.yield()
            }
            machine.outputBytes.append(0xc3)
            transcript.updateTranscript(scroll, state: state)
            XCTAssertTrue(view.string.hasSuffix("�"))
            machine.outputBytes.append(0xa9)
            transcript.updateTranscript(scroll, state: state)
            XCTAssertEqual(view.string, String(decoding: machine.outputBytes, as: UTF8.self))
            for _ in 0..<100 where state.followScheduled { try await Task.sleep(nanoseconds: 1_000_000) }
            let layout = try XCTUnwrap(view.layoutManager)
            let container = try XCTUnwrap(view.textContainer)
            let last = NSRange(location: state.storage.length - 1, length: 1)
            let glyph = layout.glyphRange(forCharacterRange: last, actualCharacterRange: nil)
            let lastRect = layout.boundingRect(forGlyphRange: glyph, in: container)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            XCTAssertTrue(scroll.documentVisibleRect.intersects(lastRect), "Last output line should be visible")
            machine.output = ""
            transcript.updateTranscript(scroll, state: state)
            XCTAssertEqual(view.string, "")
        }
    }

    @MainActor func testDockedConsoleShowsPassMarkerInConstrainedWindow() async throws {
        try await withDebugger { debugger, _ in
            debugger.options.loadExceptionHandler = true
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("SpimCoreTests/Fixtures/tt.core.s")
            debugger.load([fixture], appending: false)
            let machine = try XCTUnwrap(debugger.machine)
            let size = NSSize(width: 570, height: 150)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            let host = NSHostingView(rootView: ConsolePanel(debugger: debugger).frame(width: size.width, height: size.height).clipped())
            window.contentView = host
            window.setContentSize(size)
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            @MainActor func settleRun() async throws {
                let limit = ProcessInfo.processInfo.systemUptime + 5
                while debugger.running && ProcessInfo.processInfo.systemUptime < limit {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
            }
            debugger.run()
            for line in ["17", "1717", "17.18", "1700.18", "17.18e10", "1700.18e10"] {
                try await settleRun()
                XCTAssertEqual(machine.status, .waitingInput)
                debugger.input = line
                debugger.sendInput()
            }
            try await settleRun()
            XCTAssertEqual(machine.status, .halted(0))
            try await Task.sleep(nanoseconds: 150_000_000)
            host.layoutSubtreeIfNeeded()
            func transcript(in view: NSView) -> NSTextView? {
                if let text = view as? NSTextView, text.string.contains("Passed all tests") { return text }
                return view.subviews.lazy.compactMap { transcript(in: $0) }.first
            }
            let text = try XCTUnwrap(transcript(in: host))
            let scroll = try XCTUnwrap(text.enclosingScrollView)
            let layout = try XCTUnwrap(text.layoutManager)
            let container = try XCTUnwrap(text.textContainer)
            let marker = (text.string as NSString).range(of: "Passed all tests", options: .backwards)
            let glyph = layout.glyphRange(forCharacterRange: marker, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyph, in: container)
                .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let actual = text.convert(center, to: host)
            XCTAssertTrue(scroll.documentVisibleRect.contains(center), "marker \(rect); visible \(scroll.documentVisibleRect)")
            XCTAssertTrue(host.bounds.contains(actual), "marker in host \(actual); bounds \(host.bounds); scroll frame \(scroll.frame)")
        }
    }

    @MainActor func testMemoryAndTextLogIncludeZeroRangesAndRuntimeInstructions() async throws {
        try await withDebugger { debugger, dir in
            let source = dir.appendingPathComponent("words.s")
            try ".data\nempty: .space 128\n.text\n.globl __start\n__start: nop\n".write(to: source, atomically: true, encoding: .utf8)
            debugger.load([source], appending: false)
            let machine = try XCTUnwrap(debugger.machine)
            let address: UInt32 = 0x00400010
            try machine.writeWord(0x24080007, at: address)
            debugger.jumpAddress = Radix.hex.show(address)
            debugger.exports = [.text, .data]
            let output = debugger.exportText()
            XCTAssertTrue(output.contains("zero-filled"))
            XCTAssertTrue(output.contains("0x00400010\t0x24080007"))
            XCTAssertEqual(debugger.readWord(at: address), 0x24080007)
            XCTAssertTrue(debugger.instructions.contains { $0.address == address && $0.instruction.source.isEmpty })
        }
    }
}
#endif
