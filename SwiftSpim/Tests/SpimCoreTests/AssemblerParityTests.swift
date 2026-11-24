import XCTest
@testable import SpimCore

final class AssemblerParityTests: XCTestCase {
    let options = SpimOptions(loadExceptionHandler: false)

    func testIncrementalUndefinedReferenceAndScopedLabels() throws {
        let a = SourceInput(name: "a.s", text: ".text\n.globl main\nmain: j other\nagain: addu $0 $0 $0\n")
        let b = SourceInput(name: "b.s", text: ".text\n.globl other\nother: j again\nagain: syscall\n")
        XCTAssertThrowsError(try Assembler().assemble([a], options: options))
        let incomplete = try Assembler().assemble([a], options: options, allowUndefinedSymbols: true)
        XCTAssertEqual(incomplete.unresolvedSymbols, ["other"])
        let finished = try Assembler().assemble([a, b], options: options)
        XCTAssertTrue(finished.unresolvedSymbols.isEmpty)
        XCTAssertEqual(finished.instructions[0x00400000]?.word, 0x08100002)
        XCTAssertEqual(finished.instructions[0x00400008]?.word, 0x08100003)
        XCTAssertNil(finished.symbols["again"])
    }

    func testDataListSignedValuesAndQuotedPunctuation() throws {
        let source = SourceInput(name: "test.s", text: """
        .data
        text: .asciiz "#;,:()":2
        samples: .word 23,-1,+3
        end: .space 0
        """)
        let image = try Assembler().assemble([source], options: options)
        let text = try XCTUnwrap(image.symbols["text"])
        let samples = try XCTUnwrap(image.symbols["samples"])
        XCTAssertEqual((0..<14).map { image.data[text + UInt32($0)] }, Array("#;,:()\0#;,:()\0".utf8).map(Optional.some))
        XCTAssertEqual(samples % 4, 0)
        XCTAssertEqual((0..<12).map { image.data[samples + UInt32($0)] ?? 0 }, [23,0,0,0,255,255,255,255,3,0,0,0])
        XCTAssertEqual(image.symbols["end"], samples + 12)
    }

    func testNativeSpimOpcodesAndPseudoExpansion() throws {
        let source = SourceInput(name: "test.s", text: """
        .text
        start:
          li $t0, 0xffff0000
          li $t1, 0x11223344
          b next
          sll $0,$0,0
        next:
          cvt.d.w $f2,$f0
          syscall
        """)
        let image = try Assembler().assemble([source], options: options)
        let start = try XCTUnwrap(image.symbols["start"])
        let words = (0..<7).map { image.instructions[start + UInt32($0)*4]?.word }
        XCTAssertEqual(words, [0x3c08ffff,0x3c011122,0x34293344,0x04010002,0,0x462000a1,12])
    }
    func testSPIMDisplayWordsKeepExecutionOperands() throws {
        let source = SourceInput(name: "display.s", text: """
        .text
        break 3
        movn.d $f2,$f0,$2
        movn.s $f2,$f0,$2
        movz.d $f2,$f0,$2
        movz.s $f2,$f0,$2
        .word 0x46020092
        """)
        let image = try Assembler().assemble([source], options: options)
        let instructions = (0..<6).compactMap { image.instructions[0x0040_0000 + UInt32($0) * 4] }
        XCTAssertEqual(instructions.map(\.word), [0x0000000d, 0x46200093, 0x46000093, 0x46200092, 0x46000092, 0x46020092])
        XCTAssertEqual(instructions.map(\.executionWord), [0x0000180d, 0x46220093, 0x46020093, 0x46220092, 0x46020092, nil])
    }

    func testBareMachineAcceptsImmediateAliasesForHardwareOperations() throws {
        let options = SpimOptions(bareMachine: true, loadExceptionHandler: false, acceptPseudoInstructions: false)
        let source = SourceInput(name: "bare.s", text: "and $4,$2,1\nadd $4,2\n")
        let image = try Assembler().assemble([source], options: options)
        XCTAssertEqual(image.instructions[0x0040_0000]?.word, 0x30440001)
        XCTAssertEqual(image.instructions[0x0040_0004]?.word, 0x20840002)
    }

    func testSparseSegmentEndsDoNotShrinkAndBoundsHonorLegacySettings() throws {
        let source = SourceInput(name: "sparse.s", text: ".kdata 0x90000080\n.space 16\n.kdata 0x90000000\n.word 1\n")
        let image = try Assembler().assemble([source], options: options)
        XCTAssertEqual(image.kernelDataEnd, 0x9000_0090)
        XCTAssertEqual(image.data[0x9000_0000], 1)
        var constrained = options
        constrained.memoryLayout.userTextSize = 4
        XCTAssertThrowsError(try Assembler().assemble([.init(name: "text.s", text: "nop\nnop\n")], options: constrained))
    }

    func testBundledHandlerLoadsBeforeAnInputIsOpened() throws {
        let loaded = try Assembler().assemble([], allowUndefinedSymbols: true)
        XCTAssertEqual(loaded.symbols["__start"], 0x0040_0000)
        XCTAssertEqual(loaded.unresolvedSymbols, ["main"])
        XCTAssertNotNil(loaded.instructions[0x8000_0180])
    }

    func testOverlayInvalidatesEarlierRelocations() throws {
        let a = SourceInput(name: "a.s", text: ".ktext 0x80000180\nj missing\n")
        let b = SourceInput(name: "b.s", text: ".ktext 0x80000180\neret\n")
        let image = try Assembler().assemble([a, b], options: options)
        XCTAssertEqual(image.instructions[0x8000_0180]?.word, 0x4200_0018)
    }

    func testDirectiveExpressionPrecedenceAndConstants() throws {
        let source = SourceInput(name: "expr.s", text: """
        count = (2+3)*4
        .data
        start: .word count/2, 1+4*2, -1
        .space count/4
        end: .word 0
        """)
        let image = try Assembler().assemble([source], options: options)
        let start = try XCTUnwrap(image.symbols["start"])
        XCTAssertEqual(image.data[start], 10)
        XCTAssertEqual(image.data[start + 4], 9)
        XCTAssertEqual(image.data[start + 8], 255)
        XCTAssertEqual(image.symbols["end"], start + 20)
    }
    func testRecoveringAssemblerPreservesUpstreamALUWarningsAndPartialProgram() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tt.alu.bare", withExtension: "s", subdirectory: "Fixtures"))
        let source = SourceInput(name: url.path, text: try String(contentsOf: url))
        let bare = SpimOptions(bareMachine: true, loadExceptionHandler: false)
        let image = try Assembler().assemble([source], options: bare, recovering: true)
        XCTAssertEqual(image.diagnostics.count, 11)
        XCTAssertEqual(image.diagnostics.first?.line, 413)
        XCTAssertTrue(image.diagnostics.first?.spimDescription.contains("on line 414") == true)
        XCTAssertEqual(image.diagnostics.last?.message, "syntax error")
        XCTAssertEqual(image.diagnostics.last?.line, 1601)
        XCTAssertEqual(image.unresolvedSymbols, ["fail"])
        XCTAssertEqual(image.unresolvedInstructions[0x00400048], "fail")
        XCTAssertEqual(image.instructions[0x00400048]?.word, 0x14800000)
        XCTAssertNil(image.symbols["fail"])
        let machine = Machine(image: image, options: bare)
        _ = machine.run(maxSteps: 1000)
        XCTAssertEqual(machine.output, "Testing ADD\n")
        XCTAssertEqual(machine.pc, 0x00400048)
        guard case .fault(let message) = machine.status else { return XCTFail("Expected undefined instruction reference") }
        XCTAssertTrue(message.contains("bne $4, $0, 0 [fail-0x00400048]"))
    }

    func testRecoveringSyntaxErrorStopsOnlyTheCurrentInput() throws {
        let first = SourceInput(name: "first.s", text: ".text\n.globl main\nmain: addiu $v0,$zero,10\ninvalid $0\nlost: syscall\n")
        let second = SourceInput(name: "second.s", text: ".text\n.globl after\nafter: syscall\n")
        let image = try Assembler().assemble([first, second], options: options, recovering: true)
        XCTAssertNil(image.symbols["lost"])
        XCTAssertEqual(image.symbols["after"], 0x00400004)
        XCTAssertEqual(image.diagnostics.count, 1)
        XCTAssertEqual(Machine(image: image, options: options).run(), .halted(0))
    }

}
