import Foundation
import XCTest
@testable import SpimCore

final class ReviewRegressionTests: XCTestCase {
    private let options = SpimOptions(loadExceptionHandler: false)
    private func assemble(_ source: String, options: SpimOptions? = nil) throws -> ProgramImage {
        try Assembler().assemble([.init(name: "review.s", text: source)], options: options ?? self.options, recovering: true)
    }
    private func string(_ cpu: Machine, at address: UInt32) -> [UInt8] {
        var bytes: [UInt8] = []
        for offset in 0..<20_000 {
            let byte = cpu.peekByte(at: address + UInt32(offset))
            if byte == 0 { break }; bytes.append(byte)
        }
        return bytes
    }

    func testSemanticErrorsRetainFollowingInstructionsButSyntaxStopsTheInput() throws {
        for prefix in [".data\nx: .word 1\nx: .word 2\n", ".text\nseb $t0,$t1\n", ".text\ndiv $t0,$t1,0\n", ".text\n.asciiz \"x\"\n"] {
            let image = try assemble(prefix + ".text\n.globl __start\n__start: li $v0,10\nsyscall\n")
            XCTAssertFalse(image.diagnostics.isEmpty)
            XCTAssertNotNil(image.symbols["__start"])
            XCTAssertEqual(Machine(image: image, options: options).run(), .halted(0))
        }
        XCTAssertThrowsError(try assemble(".text\n.err\n.globl __start\n__start: syscall\n"))
    }

    func testEarlierForwardUseResolvesToLaterLocalDefinitionOnly() throws {
        let a = SourceInput(name: "a.s", text: ".text\n.globl __start\n__start: j helper\n")
        let b = SourceInput(name: "b.s", text: ".text\nhelper: li $v0,10\nsyscall\n")
        let forward = try Assembler().assemble([a,b], options: options, recovering: true)
        XCTAssertTrue(forward.unresolvedSymbols.isEmpty)
        XCTAssertEqual(Machine(image: forward, options: options).run(), .halted(0))
        let reverse = try Assembler().assemble([b,a], options: options, recovering: true)
        XCTAssertEqual(reverse.unresolvedSymbols, ["helper"])
    }

    func testInputBreakpointBypassSurvivesWaitingForInput() throws {
        let image = try assemble(".text\n.globl __start\n__start: li $v0,5\nread: syscall\nmove $s0,$v0\nli $v0,10\nsyscall\n")
        let cpu = Machine(image: image, options: options)
        cpu.breakpoints.insert(try XCTUnwrap(image.symbols["read"]))
        XCTAssertEqual(cpu.run(), .paused)
        XCTAssertEqual(cpu.run(), .waitingInput)
        cpu.provideInput("17\n")
        XCTAssertEqual(cpu.run(), .halted(0))
        XCTAssertEqual(cpu.registers[16], 17)
    }

    func testConsoleBytesAndEndOfInputAreServiceSpecific() throws {
        let raw = try assemble(".text\n.globl __start\n__start: li $a0,255\nli $v0,11\nsyscall\nli $a0,195\nsyscall\nli $a0,169\nsyscall\nli $v0,10\nsyscall\n")
        let output = Machine(image: raw, options: options)
        XCTAssertEqual(output.run(), .halted(0))
        XCTAssertEqual(output.outputBytes, [255,195,169])
        XCTAssertEqual(output.output, "�é")
        let input = try assemble(".text\n.globl __start\n__start: li $v0,12\nsyscall\nmove $s0,$v0\nli $v0,10\nsyscall\n")
        let byteCPU = Machine(image: input, options: options)
        byteCPU.provideInput(bytes: [233])
        XCTAssertEqual(byteCPU.run(), .halted(0))
        XCTAssertEqual(byteCPU.registers[16], 0xffffffe9)
        let eofCPU = Machine(image: input, options: options)
        eofCPU.endInput()
        XCTAssertEqual(eofCPU.run(), .halted(0))
        XCTAssertEqual(eofCPU.registers[16], 10)
    }

    func testLatin1SourceLiteralsPreserveTheirOriginalBytes() throws {
        let source = Data(Array("# Comment ".utf8) + [233] + Array("\n.data\nvalue: .asciiz \"".utf8) + [233] + Array("\"\n.text\n.globl __start\n__start: li $v0,10\nsyscall\n".utf8))
        let image = try Assembler().assemble([.init(name: "latin1.s", data: source)], options: options, recovering: true)
        let address = try XCTUnwrap(image.symbols["value"])
        XCTAssertEqual(image.data[address], 233)
        XCTAssertEqual(image.data[address+1], 0)
    }

    func testStackContainsInjectedEnvironmentAndLongArgumentsWithoutTruncation() throws {
        let configured = SpimOptions(loadExceptionHandler: false, arguments: ["prog",String(repeating:"x",count:5000)], environment: ["TEST=fixture"])
        let image = try assemble(".text\n.globl __start\n__start: syscall\n", options: configured)
        let cpu = Machine(image: image, options: configured)
        XCTAssertEqual(cpu.registers[4], 2)
        XCTAssertEqual(cpu.registers[29] & 3, 0)
        let argv = cpu.registers[5], envp = cpu.registers[6]
        XCTAssertEqual(string(cpu, at: try cpu.readWord(at: argv)), Array("prog".utf8))
        XCTAssertEqual(string(cpu, at: try cpu.readWord(at: argv+4)).count, 5000)
        XCTAssertEqual(try cpu.readWord(at: argv+8), 0)
        XCTAssertEqual(string(cpu, at: try cpu.readWord(at: envp)), Array("TEST=fixture".utf8))
        XCTAssertEqual(try cpu.readWord(at: envp+4), 0)
        XCTAssertEqual(try cpu.readWord(at: cpu.registers[29]), 2)
    }

    func testIncrementalInstallPreservesHeapGrownStackQueuedInputAndRuntimeText() throws {
        let source = SourceInput(name: "live.s", text: """
        .text
        .globl __start
        __start: li $a0,65536
        li $v0,9
        syscall
        move $s0,$v0
        li $t0,42
        sw $t0,0($s0)
        li $sp,0x7ffd0000
        sw $t0,0($sp)
        hold: nop
        li $v0,5
        syscall
        move $s1,$v0
        lw $s2,0($s0)
        li $a0,4
        li $v0,9
        syscall
        subu $s3,$v0,$s0
        li $v0,10
        syscall
        """)
        let first = try Assembler().assemble([source], options: options, recovering: true)
        let cpu = Machine(image: first, options: options)
        cpu.breakpoints.insert(try XCTUnwrap(first.symbols["hold"]))
        XCTAssertEqual(cpu.run(), .paused)
        cpu.provideInput("17\n")
        try cpu.writeWord(0x00401000, 0x24080009)
        let second = try Assembler().assemble([source,.init(name:"extra.s",text:".text\nextra: nop\n")], options: options, recovering:true)
        cpu.install(image: second)
        XCTAssertEqual(try cpu.readWord(at: 0x7ffd0000),42)
        XCTAssertEqual(cpu.liveInstructions[0x00401000]?.word,0x24080009)
        XCTAssertEqual(cpu.run(), .halted(0))
        XCTAssertEqual(cpu.registers[17],17)
        XCTAssertEqual(cpu.registers[18],42)
        XCTAssertEqual(cpu.registers[19],65536)
    }

    func testIncrementalInstallPreservesPendingBranchAndOpenFile() throws {
        let delayed = SpimOptions(delayedBranches:true,loadExceptionHandler:false)
        let source = SourceInput(name:"delay.s",text:".text\n.globl __start\n__start: b target\ndelay: li $t0,5\nli $v0,99\nsyscall\ntarget: li $v0,10\nsyscall\n")
        let image = try Assembler().assemble([source],options:delayed,recovering:true)
        let cpu = Machine(image:image,options:delayed)
        cpu.breakpoints.insert(try XCTUnwrap(image.symbols["delay"]))
        XCTAssertEqual(cpu.run(),.paused)
        let extra = SourceInput(name:"extra.s",text:".text\nextra: nop\n")
        cpu.install(image:try Assembler().assemble([source,extra],options:delayed,recovering:true))
        XCTAssertEqual(cpu.run(),.halted(0))
        XCTAssertEqual(cpu.registers[8],5)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        try Data([42]).write(to:directory.appendingPathComponent("f.bin"))
        let scoped = SpimOptions(loadExceptionHandler:false,fileRootURL:directory,restrictFileAccess:true)
        let fileSource = SourceInput(name:"file.s",text:".data\np: .asciiz \"f.bin\"\nbuf: .space 4\n.text\n.globl __start\n__start: la $a0,p\nli $a1,0\nli $a2,0\nli $v0,13\nsyscall\nmove $s0,$v0\nhold: nop\nmove $a0,$s0\nla $a1,buf\nli $a2,1\nli $v0,14\nsyscall\nlbu $s1,buf\nli $v0,10\nsyscall\n")
        let fileImage = try Assembler().assemble([fileSource],options:scoped,recovering:true)
        let fileCPU = Machine(image:fileImage,options:scoped)
        fileCPU.breakpoints.insert(try XCTUnwrap(fileImage.symbols["hold"]))
        XCTAssertEqual(fileCPU.run(),.paused)
        XCTAssertNotEqual(fileCPU.registers[16],.max)
        fileCPU.install(image:try Assembler().assemble([fileSource,extra],options:scoped,recovering:true))
        XCTAssertEqual(fileCPU.run(),.halted(0))
        XCTAssertEqual(fileCPU.registers[17],42)
    }

    func testPeekDoesNotConsumeDevicesAndTransmitterInterruptIsEdgeTriggered() throws {
        let opts = SpimOptions(mappedIO:true,loadExceptionHandler:false)
        let image = try assemble(".text\n.globl __start\n__start: b __start\n",options:opts)
        let cpu = Machine(image:image,options:opts)
        cpu.provideInput("x")
        _ = cpu.run(maxSteps:100)
        XCTAssertEqual(cpu.peekWord(at:0xffff0000)&1,1)
        XCTAssertEqual(cpu.peekWord(at:0xffff0004),120)
        XCTAssertEqual(cpu.peekWord(at:0xffff0000)&1,1)
        try cpu.writeWord(0xffff0008,2)
        XCTAssertNotEqual(cpu.coprocessor0[13]&0x400,0)
        cpu.coprocessor0[13] &= ~0x400
        _ = cpu.run(maxSteps:200)
        XCTAssertEqual(cpu.coprocessor0[13]&0x400,0)
        XCTAssertEqual(cpu.peekWord(at:0x00400000),image.instructions[0x00400000]?.word)
    }
    func testClosedStdinNulInputAndOversizedTransfersDoNotTouchHostHandles() throws {
        let source = try assemble(".text\n.globl __start\n__start: li $v0,12\nsyscall\nmove $s0,$v0\nli $v0,10\nsyscall\n")
        let input = Machine(image: source, options: options)
        input.provideInput(bytes: [0])
        XCTAssertEqual(input.run(), .halted(0))
        XCTAssertEqual(input.registers[16], 10)
        let twoSyscalls = try assemble(".text\n.globl __start\n__start: syscall\nsyscall\n")
        let closed = Machine(image: twoSyscalls, options: options)
        closed.registers[2] = 16; closed.registers[4] = 0
        closed.step()
        XCTAssertEqual(closed.registers[2], 0)
        closed.registers[2] = 14; closed.registers[4] = 0
        closed.registers[5] = 0x10010000; closed.registers[6] = 1
        closed.step()
        XCTAssertEqual(closed.registers[2], .max)
        let oversized = Machine(image: twoSyscalls, options: options)
        oversized.registers[2] = 15; oversized.registers[4] = 1
        oversized.registers[5] = 0x10010000; oversized.registers[6] = .max
        oversized.step()
        XCTAssertEqual(oversized.registers[2], .max)
        XCTAssertTrue(oversized.outputBytes.isEmpty)
    }

}
