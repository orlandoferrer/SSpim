import Foundation
import XCTest
@testable import SpimCore

final class SpimCoreTests: XCTestCase {
    private func fixture(_ name: String, ext: String = "s") throws -> SourceInput {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return SourceInput(name: "\(name).\(ext)", text: try String(contentsOf: url, encoding: .utf8))
    }

    func testBundledHelloWorld() throws {
        let image = try Assembler().assemble([fixture("helloworld")])
        XCTAssertNotNil(image.symbols["main"])
        XCTAssertNotNil(image.symbols["__start"], "Use the upstream startup and exception handler")
        let machine = Machine(image: image)
        machine.run(maxSteps: 1_000)
        XCTAssertEqual(machine.output, "Hello World")
        XCTAssertEqual(machine.status, .halted(0))
    }

    func testExecutionUsesMIPSMachineWords() {
        let base: UInt32 = 0x0040_0000
        let words: [UInt32] = [
            0x2408_0028, // addiu $t0, $zero, 40
            0x2504_0002, // addiu $a0, $t0, 2
            0x2402_0001, // addiu $v0, $zero, 1
            0x0000_000c, // syscall
            0x2402_000a, // addiu $v0, $zero, 10
            0x0000_000c  // syscall
        ]
        var image = ProgramImage()
        for (offset, word) in words.enumerated() {
            image.instructions[base &+ UInt32(offset * 4)] = Instruction(word: word)
        }
        image.symbols["main"] = base
        let machine = Machine(image: image, options: .init(loadExceptionHandler: false))
        machine.run(maxSteps: 25)
        XCTAssertEqual(machine.registers[0], 0)
        XCTAssertEqual(machine.registers[4], 42)
        XCTAssertEqual(machine.status, .halted(0))
        XCTAssertEqual(machine.output, "42")
    }

    func testLittleAndBigEndianMemoryImage() throws {
        let source = SourceInput(name: "bytes.s", text: """
        .data
        value: .word 0x01020304
        .text
        .globl main
        main: syscall
        """)
        for little in [true, false] {
            let image = try Assembler().assemble([source], options: .init(littleEndian: little, loadExceptionHandler: false))
            let address = try XCTUnwrap(image.symbols["value"])
            let bytes = (0..<4).map { image.data[address &+ UInt32($0)] ?? 0 }
            XCTAssertEqual(bytes, little ? [4, 3, 2, 1] : [1, 2, 3, 4])
        }
    }

    private func machine(words: [UInt32], options: SpimOptions = .init(loadExceptionHandler: false),
                         data: [UInt32: UInt8] = [:]) -> Machine {
        let base: UInt32 = 0x0040_0000
        let instructions = Dictionary(uniqueKeysWithValues: words.enumerated().map {
            (base + UInt32($0.offset) * 4, Instruction(word: $0.element))
        })
        return Machine(image: ProgramImage(instructions: instructions, data: data, symbols: ["main": base]), options: options)
    }

    func testDelayedJumpAndBreakpointContinue() {
        // The jump's delay slot adds 1, the unreachable instructions add 4 and 8.
        let words: [UInt32] = [0x0810_0004, 0x2484_0001, 0x2484_0004, 0x2484_0008, 0x2402_000a, 0x0000_000c]
        for delay in [false, true] {
            let m = machine(words: words, options: .init(delayedBranches: delay, loadExceptionHandler: false))
            m.breakpoints = [0x0040_0010]
            m.run(maxSteps: 10)
            XCTAssertEqual(m.pc, 0x0040_0010)
            XCTAssertEqual(m.registers[4], delay ? 1 : 0)
            XCTAssertEqual(m.status, .paused)
            m.run(maxSteps: 10)
            XCTAssertEqual(m.status, .halted(0))
        }
    }

    func testInputSuspendsAndResumesSameInstruction() {
        let m = machine(words: [
            0x2402_0005, // read_int
            0x0000_000c,
            0x0040_2021, // addu $a0,$v0,$zero
            0x2402_0001, // print_int
            0x0000_000c,
            0x2402_000a, 0x0000_000c
        ])
        m.run(maxSteps: 10)
        XCTAssertEqual(m.status, .waitingInput)
        XCTAssertEqual(m.pc, 0x0040_0004)
        m.provideInput("-700\n")
        m.run(maxSteps: 20)
        XCTAssertEqual(m.output, "-700")
        XCTAssertEqual(m.status, .halted(0))
    }

    func testLoadDelayPreservesTheOldRegisterForOneInstruction() {
        let words: [UInt32] = [
            0x2408_0007, // addiu $t0,$zero,7
            0x3c09_1001, // lui $t1,0x1001
            0x8d28_0000, // lw $t0,0($t1)
            0x0100_5021, // addu $t2,$t0,$zero
            0x0100_5821, // addu $t3,$t0,$zero
            0x2402_000a, 0x0000_000c
        ]
        for delay in [false, true] {
            let m = machine(words: words, options: .init(delayedLoads: delay, loadExceptionHandler: false),
                            data: [0x1001_0000: 42])
            m.run(maxSteps: 20)
            XCTAssertEqual(m.status, .halted(0))
            XCTAssertEqual(m.registers[10], delay ? 7 : 42)
            XCTAssertEqual(m.registers[11], 42)
        }
    }

    func testHeapStartsAtMinimumDataSizeWithBundledHandler() throws {
        var options = SpimOptions()
        XCTAssertTrue(options.memoryLayout.setLegacyOption("-sd", bytes: 1))
        XCTAssertTrue(options.memoryLayout.setLegacyOption("-ld", bytes: 65_552))
        let source = SourceInput(name: "heap.s", text: """
        .text
        .globl main
        main:
          li $a0, 9
          li $v0, 9
          syscall
          move $s0, $v0
          li $a0, 4
          li $v0, 9
          syscall
          move $s1, $v0
          li $v0, 10
          syscall
        """)
        let m = Machine(image: try Assembler().assemble([source], options: options), options: options)
        m.run(maxSteps: 100)
        XCTAssertEqual(m.status, .halted(0))
        XCTAssertEqual(m.registers[16], 0x1001_0000)
        XCTAssertEqual(m.registers[17], 0x1001_000c)
    }

    func testPinnedUpstreamMachineWordsAndRelocation() throws {
        let source = SourceInput(name: "pinned-words.s", text: """
        .text
        .globl main
        main:
            li $t0, 0x12345678
            li $t1, -7
            beq $t0, $t1, done
            move $a0, $t1
        done:
            addiu $v0, $zero, 10
            syscall
        """)
        // Observed via print <address> in official SPIM r764, no exception handler.
        let expected: [UInt32] = [
            0x3c01_1234, 0x3428_5678, 0x3c01_ffff, 0x3429_fff9,
            0x1109_0002, 0x0009_2021, 0x2402_000a, 0x0000_000c
        ]
        let image = try Assembler().assemble([source], options: .init(loadExceptionHandler: false))
        XCTAssertEqual(image.instructions.keys.sorted().compactMap { image.instructions[$0]?.word }, expected)
        XCTAssertEqual(image.symbols["done"], 0x0040_0018)
    }

    func testDisassembly() {
        XCTAssertEqual(SpimDisassembler.format(0, at: 0x0040_0000), "nop")
        XCTAssertEqual(SpimDisassembler.format(0x2504_0002, at: 0x0040_0000), "addiu $4, $8, 2")
        XCTAssertEqual(SpimDisassembler.format(0x1100_fffe, at: 0x0040_0010, delayedBranches: true),
                       "beq $8, $0, 0x0040000c")
    }
}
