import Foundation
import XCTest
@testable import SpimCore

final class MachineParityTests: XCTestCase {
    private let text: UInt32 = 0x0040_0000
    private let data: UInt32 = 0x1001_0000

    private func machine(_ words: [UInt32], options: SpimOptions = .init(), bytes: [UInt32: UInt8] = [:]) -> Machine {
        let instructions = Dictionary(uniqueKeysWithValues: words.enumerated().map {
            (text + 4 * UInt32($0.offset), Instruction(word: $0.element))
        })
        return Machine(image: ProgramImage(instructions: instructions, data: bytes), options: options)
    }

    func testMemoryLayoutBoundsAndSparseStackGrowth() throws {
        var layout = SpimMemoryLayout()
        layout.userTextSize = 8
        layout.dataSize = 0x1_0000
        layout.dataLimit = 0x1_0008
        layout.stackSize = 0x1000
        layout.stackLimit = 0x2000
        layout.kernelDataSize = 8
        let cpu = machine([0x2402_0009, 12], options: .init(memoryLayout: layout))
        XCTAssertEqual(try cpu.readWord(at: text + 4), 12)
        XCTAssertThrowsError(try cpu.readWord(at: text + 8))
        XCTAssertEqual(try cpu.readWord(at: 0x9000_0004), 0)
        XCTAssertThrowsError(try cpu.readWord(at: 0x9000_0008))
        XCTAssertThrowsError(try cpu.readWord(at: data))
        cpu.registers[4] = 5
        cpu.step()
        cpu.step()
        XCTAssertEqual(cpu.registers[2], data)
        XCTAssertEqual(try cpu.readWord(at: data + 4), 0)
        XCTAssertThrowsError(try cpu.readWord(at: data + 8))
        XCTAssertEqual(try cpu.readWord(at: 0x7fff_effc), 0)
        try cpu.writeWord(0x1234abcd, at: 0x7fff_e004)
        XCTAssertEqual(try cpu.readWord(at: 0x7fff_e004), 0x1234abcd)
        XCTAssertThrowsError(try cpu.writeWord(42, at: 0x7fff_dffc))
        cpu.reset()
        XCTAssertEqual(try cpu.readWord(at: 0x7fff_e004), 0)
    }

    func testExecutionOverrideRetainsRawEncodingUntilTextWrite() throws {
        let entry = Instruction(word: 0, executionWord: 0x2408_0007) // addiu $t0,$zero,7
        let cpu = Machine(image: .init(instructions: [text: entry]))
        XCTAssertEqual(cpu.instructionWord(at: text), 0)
        XCTAssertEqual(try cpu.readWord(at: text), 0)
        cpu.step()
        XCTAssertEqual(cpu.registers[8], 7)
        cpu.reset()
        try cpu.writeWord(0, at: text) // Same display word; raw write removes assembler metadata.
        cpu.step()
        XCTAssertEqual(cpu.registers[8], 0)
    }

    func testSpimDefaultAndDelayedBranchEncoding() {
        let words: [UInt32] = [0x1000_0002, 0x2408_0001, 0x2409_0002, 0x240a_0003, 0x2402_000a, 12]
        let immediate = machine(words)
        XCTAssertEqual(immediate.run(), .halted(0))
        XCTAssertEqual(Array(immediate.registers[8...10]), [0, 2, 3])

        let delayed = machine(words, options: .init(delayedBranches: true))
        XCTAssertEqual(delayed.run(), .halted(0))
        XCTAssertEqual(Array(delayed.registers[8...10]), [1, 0, 3])
    }

    func testDelayLoadAndBreakpointResume() {
        // lw $t0, 0($a0); addu $t1, $zero, $t0; addu $t2, $zero, $t0
        let cpu = machine([0x8c88_0000, 0x0008_4821, 0x0008_5021, 0x2402_000a, 12],
                          options: .init(delayedLoads: true), bytes: [data: 42])
        cpu.registers[4] = data
        cpu.breakpoints.insert(text + 4)
        XCTAssertEqual(cpu.run(), .paused)
        XCTAssertEqual(cpu.pc, text + 4)
        XCTAssertEqual(cpu.registers[8], 0)
        XCTAssertEqual(cpu.run(), .halted(0))
        XCTAssertEqual(Array(cpu.registers[8...10]), [42, 0, 42])
    }

    func testFloatingPointRegisterWordsAndInputSuspension() {
        // add.d $f4, $f0, $f2, then read_int.
        let cpu = machine([0x4622_0100, 0x2402_0005, 12, 0])
        cpu.setDoubleRegister(0, 2.25)
        cpu.setDoubleRegister(2, 4.5)
        XCTAssertEqual(cpu.run(), .waitingInput)
        XCTAssertEqual(cpu.doubleRegister(4), 6.75)
        XCTAssertEqual(cpu.pc, text + 8)
        cpu.provideInput("-9\n")
        cpu.step()
        XCTAssertEqual(Int32(bitPattern: cpu.registers[2]), -9)
        XCTAssertEqual(cpu.pc, text + 12)
    }

    func testBranchDelayExceptionRecordsBranchAndFaultAddress() {
        let branch = Instruction(word: 0x1000_0001)
        let bad = Instruction(word: 0x8c88_0001) // lw $t0, 1($a0)
        let cpu = Machine(image: .init(instructions: [text: branch, text + 4: bad, 0x8000_0180: .init(word: 0)]),
                          options: .init(delayedBranches: true))
        cpu.registers[4] = data
        cpu.step()
        cpu.step()
        XCTAssertEqual(cpu.pc, 0x8000_0180)
        XCTAssertEqual(cpu.coprocessor0[8], data + 1)
        XCTAssertEqual(cpu.coprocessor0[13], 0x8000_0010)
        XCTAssertEqual(cpu.coprocessor0[14], text)
    }

    func testPinnedMappedIOFixtureWithReplacementHandler() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "tt.io", withExtension: "s", subdirectory: "Fixtures"))
        let input = SourceInput(name: fixture.lastPathComponent, text: try String(contentsOf: fixture, encoding: .utf8))
        let options = SpimOptions(mappedIO: true)
        let image = try Assembler().assemble([input], options: options)
        let cpu = Machine(image: image, options: options)
        cpu.provideInput("1\n2\n3\n4\n5\n6\n")
        XCTAssertEqual(cpu.run(maxSteps: 200_000), .halted(0))
        // The pinned command-line reference prints only its polling part for
        // this pre-fed input; record the observed reference rather than the
        // expectation described in the example's opening prompt.
        XCTAssertEqual(cpu.output, "SPIM IO Test.\nOnly runs with -mapped_io flag.\nPlease type 6 input lines:\n1\n2\n3\n")
    }

    func testGuestFileReadRequiresScopeAndRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([42]).write(to: root.appendingPathComponent("a"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("b").path,
                                                   withDestinationPath: root.appendingPathComponent("a").path)
        var options = SpimOptions()
        options.restrictFileAccess = true
        let cpu = machine([12, 12, 12, 12], options: options, bytes: [data: 97, data + 8: 98])
        cpu.registers[2] = 13; cpu.registers[4] = data; cpu.registers[5] = 0; cpu.registers[6] = 0
        cpu.step()
        XCTAssertEqual(cpu.registers[2], .max)
        cpu.guestDirectory = root
        cpu.registers[2] = 13; cpu.registers[4] = data + 8
        cpu.step()
        XCTAssertEqual(cpu.registers[2], .max)
        cpu.registers[2] = 13; cpu.registers[4] = data
        cpu.step()
        let fd = cpu.registers[2]
        XCTAssertNotEqual(fd, .max)
        cpu.registers[2] = 14; cpu.registers[4] = fd; cpu.registers[5] = data + 16; cpu.registers[6] = 1
        cpu.step()
        XCTAssertEqual(cpu.registers[2], 1)
        XCTAssertEqual(cpu.memory[data + 16], 42)
    }

    func testGuestFileOpenWalksDirectoriesWithoutFollowingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([42]).write(to: nested.appendingPathComponent("a"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path,
                                                  withDestinationPath: nested.path)
        for (path, allowed) in [("nested/a", true), ("alias/a", false), ("../nested/a", false)] {
            let bytes = Dictionary(uniqueKeysWithValues: (Array(path.utf8) + [0]).enumerated().map {
                (data + UInt32($0.offset), $0.element)
            })
            let cpu = machine([12], bytes: bytes)
            cpu.guestDirectory = root
            cpu.registers[2] = 13; cpu.registers[4] = data
            cpu.registers[5] = 0; cpu.registers[6] = 0
            cpu.step()
            XCTAssertEqual(cpu.registers[2] != .max, allowed, path)
        }
    }
    func testDefaultHostFileAccessAcceptsAbsolutePathsAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        let link = root.appendingPathComponent("link")
        try Data([42]).write(to: file)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: file.path)
        for url in [file, link] {
            let bytes = Dictionary(uniqueKeysWithValues: (Array(url.path.utf8) + [0]).enumerated().map {
                (data + UInt32($0.offset), $0.element)
            })
            let cpu = machine([12, 12], bytes: bytes)
            cpu.registers[2] = 13; cpu.registers[4] = data; cpu.registers[5] = 0; cpu.registers[6] = 0
            cpu.step()
            XCTAssertNotEqual(cpu.registers[2], .max)
            let descriptor = cpu.registers[2]
            cpu.registers[2] = 16; cpu.registers[4] = descriptor
            cpu.step()
            XCTAssertEqual(cpu.registers[2], 0)
        }
    }

}
