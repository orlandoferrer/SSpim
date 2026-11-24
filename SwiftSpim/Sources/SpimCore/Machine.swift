import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// An independently resettable instance of the SPIM virtual machine.
public final class Machine {
    public var registers = Array(repeating: UInt32(0), count: 32)
    public var floatingRegisters = Array(repeating: UInt32(0), count: 32)
    public var coprocessor0 = Array(repeating: UInt32(0), count: 32)
    public var coprocessor0Control = Array(repeating: UInt32(0), count: 32)
    public var floatingControl = Array(repeating: UInt32(0), count: 32)
    public var fcsr: UInt32 = 0
    public var pc: UInt32 = 0
    public var hi: UInt32 = 0
    public var lo: UInt32 = 0
    public var memory: [UInt32: UInt8] = [:]
    public private(set) var image: ProgramImage
    public private(set) var options: SpimOptions
    public var breakpoints: Set<UInt32> = []
    public var outputBytes: [UInt8] = []
    public var stderrBytes: [UInt8] = []
    private var closedGuestDescriptors: Set<UInt32> = []
    public var output: String {
        get { String(decoding: outputBytes, as: UTF8.self) }
        set { outputBytes = Array(newValue.utf8) }
    }
    public private(set) var diagnosticOutput = ""
    public private(set) var codeRevision: UInt64 = 0
    public private(set) var status: MachineStatus = .ready
    public private(set) var instructionCount: UInt64 = 0
    public var arguments: [String] = []
    public var startAddress: UInt32?
    public var guestDirectory: URL?

    private enum AccessError: Error {
        case exception(UInt32, UInt32?)
    }
    private struct OpenFile {
        let handle: FileHandle
        let readable: Bool
        let writable: Bool
    }
    private var files: [UInt32: OpenFile] = [:]
    private var nextFD: UInt32 = 3
    private var code: [UInt32: UInt32] = [:]
    private var executionWords: [UInt32: UInt32] = [:]
    private var textTop: UInt32 = 0
    private var kernelTextTop: UInt32 = 0
    private var stackBottom: UInt32 = 0
    private var kernelDataTop: UInt32 = 0
    private var input: [UInt8] = []
    private var inputEnded = false
    private var terminalErrorBytes: [UInt8] = []
    private var runtimeCodeWrites: Set<UInt32> = []
    private var mmSenderWasReady = true
    private var ioPollCount: UInt64 = 0
    private var logicalStepsRemaining = 0
    private var stepsUntilIOPoll = 100
    private var sampleAtBoundary = true
    private var heap: UInt32 = 0
    private var pendingBranch: UInt32?
    private var pendingLoad: (Int, UInt32, Bool)?
    private var nextLoad: (Int, UInt32, Bool)?
    private var breakpointSkip: UInt32?
    private var mmReceiverIRQ = false
    private var mmSenderIRQ = false
    private var mmReceiverReady = false
    private var mmReceiverValue: UInt8 = 0
    private var mmReceiverAvailableAt: UInt64 = 0
    private var mmSenderValue: UInt8 = 0
    private var mmSenderAvailableAt: UInt64 = 0
    private var timerMark = ProcessInfo.processInfo.systemUptime

    public init(image: ProgramImage, options: SpimOptions = .init()) {
        self.image = image
        self.options = options
        self.startAddress = options.startAddress
        self.arguments = options.arguments
        self.guestDirectory = options.fileRootURL
        reset()
    }

    public func reset() {
        registers = Array(repeating: 0, count: 32)
        floatingRegisters = Array(repeating: 0, count: 32)
        coprocessor0 = Array(repeating: 0, count: 32)
        coprocessor0[12] = 0x3000ff10
        coprocessor0[16] = options.littleEndian ? 0 : 0x80000
        coprocessor0Control = Array(repeating: 0, count: 32)
        floatingControl = Array(repeating: 0, count: 32)
        floatingControl[0] = 0x9800
        memory = image.data
        code = image.instructions.mapValues { $0.word }
        executionWords = image.instructions.compactMapValues(\.executionWord)
        let layout = options.memoryLayout
        textTop = 0x00400000 + min(layout.userTextSize, 0x0fc00000)
        kernelTextTop = 0x80000000 + min(layout.kernelTextSize, 0x10000000)
        // SPIM reserves the small-data region even for an empty source, but
        // landing exactly on its initial end does not grow it until there is
        // a real allocation or data write to account for.
        let defaultDataStart: UInt32 = options.bareMachine ? 0x10000000 : 0x10010000
        let hasUserBytes = image.data.keys.contains { (0x10000000..<0x7f000000).contains($0) }
        let userEnd = image.dataEnd == defaultDataStart && !hasUserBytes ? 0x10000000 : image.dataEnd
        heap = initialDataTop(base: 0x10000000, size: max(65_536, layout.dataSize),
                              end: userEnd, ceiling: 0x7f000000)
        let lastKernelByte = image.data.keys.lazy.filter { (0x90000000..<0xffff0000).contains($0) }.max()
        kernelDataTop = initialDataTop(base: 0x90000000, size: layout.kernelDataSize,
                                      end: max(image.kernelDataEnd, lastKernelByte.map { $0 + 1 } ?? 0),
                                      ceiling: 0xffff0000)
        stackBottom = 0x80000000 - min(aligned(layout.stackSize), 0x6fffffff)
        pc = defaultEntryPoint
        hi = 0; lo = 0; fcsr = 0; output = ""; instructionCount = 0
        pendingBranch = nil; pendingLoad = nil; nextLoad = nil
        breakpointSkip = nil; input = []; inputEnded = false; files = [:]; nextFD = 3
        diagnosticOutput = ""; stderrBytes = []; terminalErrorBytes = []; closedGuestDescriptors = []
        runtimeCodeWrites = []; codeRevision &+= 1; mmSenderWasReady = true
        ioPollCount = 0; logicalStepsRemaining = 0; stepsUntilIOPoll = 100; sampleAtBoundary = true
        mmReceiverIRQ = false; mmSenderIRQ = false
        mmReceiverReady = false; mmReceiverValue = 0; mmReceiverAvailableAt = 0
        mmSenderValue = 0; mmSenderAvailableAt = 0
        timerMark = ProcessInfo.processInfo.systemUptime
        registers[28] = 0x10008000
        status = .ready
        configureStack()
    }

    public func clearRegisters() {
        registers = Array(repeating: 0, count: 32)
        registers[28] = 0x10008000
        registers[29] = 0x7fffeffc
        floatingRegisters = Array(repeating: 0, count: 32)
        coprocessor0 = Array(repeating: 0, count: 32)
        coprocessor0[12] = 0x3000ff10
        coprocessor0[16] = options.littleEndian ? 0 : 0x80000
        coprocessor0Control = Array(repeating: 0, count: 32)
        floatingControl = Array(repeating: 0, count: 32)
        floatingControl[0] = 0x9800
        hi = 0; lo = 0; fcsr = 0; pc = 0
        pendingBranch = nil; pendingLoad = nil; nextLoad = nil
        breakpointSkip = nil; status = .ready
    }

    private var defaultEntryPoint: UInt32 {
        if let startAddress { return startAddress }
        if let address = image.symbols["__start"] { return address }
        if options.strictEntryPoint { return 0 }
        return image.symbols["main"] ?? image.instructions.keys.filter { $0 < 0x80000000 }.min() ?? 0x00400000
    }

    public func setRunParameters(address: UInt32?, arguments: [String]) {
        startAddress = address
        self.arguments = arguments
        pc = defaultEntryPoint
        configureStack()
    }

    public func prepareToExecute() {
        switch status {
        case .halted, .fault: status = .paused
        default: break
        }
    }

    private func configureStack() {
        var cursor: UInt32 = 0x7fffffff
        var environmentPointers: [UInt32] = [], argumentPointers: [UInt32] = []
        func pushString(_ text: String) -> UInt32? {
            let bytes = Array(text.utf8) + [UInt8(0)]
            guard UInt64(bytes.count) <= UInt64(cursor),
                  growStack(to: cursor - UInt32(bytes.count)) else { return nil }
            for byte in bytes.reversed() { memory[cursor] = byte; cursor -= 1 }
            return cursor + 1
        }
        for value in options.environment {
            guard let address = pushString(value) else { status = .fault("Stack segment exhausted while copying environment"); return }
            environmentPointers.append(address)
        }
        for value in arguments {
            guard let address = pushString(value) else { status = .fault("Stack segment exhausted while copying arguments"); return }
            argumentPointers.append(address)
        }
        cursor = ((cursor & ~UInt32(3)) - 4) & ~UInt32(7)
        let vectorBytes = UInt64(environmentPointers.count + argumentPointers.count + 3) * 4
        guard vectorBytes <= UInt64(cursor), growStack(to: cursor - UInt32(vectorBytes)) else {
            status = .fault("Stack segment exhausted while building argument vectors"); return
        }
        func push(_ value: UInt32) -> UInt32 {
            try? store(value, at: cursor, size: 4)
            let address = cursor; cursor -= 4
            return address
        }
        _ = push(0)
        for address in environmentPointers.reversed() { registers[6] = push(address) }
        _ = push(0)
        for address in argumentPointers.reversed() { registers[5] = push(address) }
        registers[4] = UInt32(argumentPointers.count)
        registers[29] = cursor
        try? store(registers[4], at: cursor, size: 4)
    }

    public func provideInput(_ text: String) { provideInput(bytes: Array(text.utf8)) }
    public func provideInput(bytes: [UInt8]) {
        guard !closedGuestDescriptors.contains(0) else { return }
        input.append(contentsOf: bytes)
        if case .waitingInput = status { status = .paused }
    }
    public func endInput() {
        inputEnded = true
        if case .waitingInput = status { status = .paused }
    }
    public func takeDiagnostics() -> String {
        defer { diagnosticOutput = ""; terminalErrorBytes = [] }
        return diagnosticOutput
    }
    public func takeStderrBytes() -> [UInt8] {
        defer { terminalErrorBytes = [] }
        return terminalErrorBytes
    }

    public func pause() { if case .running = status { status = .paused } }
    public func stop() { status = .paused; breakpointSkip = nil }
    public func step() {
        switch status {
        case .halted, .fault, .waitingInput: return
        default: break
        }
        breakpointSkip = nil
        let now = ProcessInfo.processInfo.systemUptime
        if !options.upstreamInterruptSampling || now - timerMark >= 0.01 { timerMark = now }
        status = .running
        execute(sample: true)
        if case .running = status { status = .paused }
    }

    @discardableResult
    public func run(maxSteps: Int = 10000, pollAtStart: Bool = true, logicalBatchSteps: Int? = nil) -> MachineStatus {
        switch status {
        case .halted, .fault, .waitingInput: return status
        default: break
        }
        if options.upstreamInterruptSampling {
            if pollAtStart || logicalStepsRemaining <= 0 {
                let now = ProcessInfo.processInfo.systemUptime
                if now - timerMark >= 0.01 { timerMark = now }
                logicalStepsRemaining = max(1, logicalBatchSteps ?? maxSteps)
                stepsUntilIOPoll = min(100, logicalStepsRemaining)
                sampleAtBoundary = true
            }
        } else if case .running = status {} else { timerMark = ProcessInfo.processInfo.systemUptime }
        status = .running
        for _ in 0..<max(0, maxSteps) {
            guard case .running = status else { break }
            if breakpoints.contains(pc), breakpointSkip != pc {
                breakpointSkip = pc
                status = .paused
                break
            }
            let continuedBreakpoint = breakpointSkip == pc
            let before = instructionCount
            let sample = !options.upstreamInterruptSampling || sampleAtBoundary
            sampleAtBoundary = false
            execute(sample: sample)
            if options.upstreamInterruptSampling && instructionCount != before {
                logicalStepsRemaining -= 1
                stepsUntilIOPoll -= 1
                if mmio && (stepsUntilIOPoll <= 0 || logicalStepsRemaining <= 0) {
                    stepsUntilIOPoll = min(100, max(1, logicalStepsRemaining))
                    sampleAtBoundary = true
                }
            }
            // A suspended input instruction has not retired yet. Keep its
            // breakpoint bypass until the same instruction finally completes.
            if status == .waitingInput, continuedBreakpoint { breakpointSkip = pc }
            else { breakpointSkip = nil }
        }
        return status
    }

    public func readWord(at address: UInt32) throws -> UInt32 { try load(address, size: 4) }
    public func writeWord(_ value: UInt32, at address: UInt32) throws { try store(value, at: address, size: 4) }
    public func readWord(_ address: UInt32) throws -> UInt32 { try readWord(at: address) }
    public func writeWord(_ address: UInt32, _ value: UInt32) throws { try writeWord(value, at: address) }
    public func instructionWord(at address: UInt32) -> UInt32? { code[address] }
    public var liveInstructions: [UInt32: Instruction] {
        code.mapValues { Instruction(word: $0) }.merging(image.instructions.filter {
            !runtimeCodeWrites.contains($0.key) && code[$0.key] == $0.value.word
        }) { _, original in original }
    }
    public var segmentRanges: [MemorySegment] {
        [.init(kind: .userData, lowerBound: 0x10000000, upperBoundExclusive: heap),
         .init(kind: .stack, lowerBound: min(0x80000000, max(stackBottom, registers[29])), upperBoundExclusive: 0x80000000),
         .init(kind: .kernelData, lowerBound: 0x90000000, upperBoundExclusive: kernelDataTop)]
    }
    public func peekWord(at address: UInt32) -> UInt32 {
        if address >= 0xffff0000 {
            switch address {
            case 0xffff0000: return (mmReceiverReady ? 1 : 0) | (mmReceiverIRQ ? 2 : 0)
            case 0xffff0004: return UInt32(mmReceiverValue)
            case 0xffff0008: return (ioPollCount >= mmSenderAvailableAt ? 1 : 0) | (mmSenderIRQ ? 2 : 0)
            case 0xffff000c: return UInt32(mmSenderValue)
            default: return 0
            }
        }
        return (0..<4).reduce(UInt32(0)) { value, offset in
            let at = address &+ UInt32(offset)
            let position = Int(at & 3)
            let codeShift = (options.littleEndian ? position : 3 - position) * 8
            let byte = memory[at] ?? UInt8(truncatingIfNeeded: (code[at & ~UInt32(3)] ?? 0) >> codeShift)
            return value | UInt32(byte) << ((options.littleEndian ? offset : 3 - offset) * 8)
        }
    }
    public func peekByte(at address: UInt32) -> UInt8 {
        let word = peekWord(at: address & ~UInt32(3))
        let offset = Int(address & 3)
        return UInt8(truncatingIfNeeded: word >> ((options.littleEndian ? offset : 3 - offset) * 8))
    }

    /// Install reassembled additions without resetting the live runtime. Changed
    /// assembler words resolve fixups; runtime-written text and data survive.
    public func install(image next: ProgramImage, options nextOptions: SpimOptions? = nil) {
        let previous = image
        if let nextOptions { options = nextOptions; guestDirectory = nextOptions.fileRootURL }
        for (address, instruction) in next.instructions {
            let old = previous.instructions[address]
            if old == nil || (!runtimeCodeWrites.contains(address) && (old?.word != instruction.word || old?.executionWord != instruction.executionWord))
                || (old?.source != instruction.source && old?.filename == instruction.filename) {
                code[address] = instruction.word
                executionWords[address] = instruction.executionWord
                runtimeCodeWrites.remove(address)
            }
        }
        for (address, byte) in next.data {
            if previous.data[address] != byte || memory[address] == nil { memory[address] = byte }
        }
        image = next
        let layout = options.memoryLayout
        textTop = max(textTop, 0x00400000 + min(layout.userTextSize, 0x0fc00000))
        kernelTextTop = max(kernelTextTop, 0x80000000 + min(layout.kernelTextSize, 0x10000000))
        heap = max(heap, initialDataTop(base: 0x10000000, size: max(65_536, layout.dataSize), end: next.dataEnd, ceiling: 0x7f000000))
        kernelDataTop = max(kernelDataTop, initialDataTop(base: 0x90000000, size: layout.kernelDataSize, end: next.kernelDataEnd, ceiling: 0xffff0000))
        codeRevision &+= 1
    }

    private func u(_ x: Int32) -> UInt32 { UInt32(bitPattern: x) }
    private func s(_ x: UInt32) -> Int32 { Int32(bitPattern: x) }
    private var branchDelay: Bool { options.delayedBranches }
    private var loadDelay: Bool { options.delayedLoads }
    private var mmio: Bool { options.usesMappedIO }

    private func aligned(_ size: UInt32) -> UInt32 {
        UInt32(min((UInt64(size) + 3) & ~UInt64(3), UInt64(UInt32.max & ~3)))
    }

    private func initialDataTop(base: UInt32, size: UInt32, end: UInt32, ceiling: UInt32) -> UInt32 {
        let top = UInt64(base) + UInt64(aligned(size))
        let extra = end > base && UInt64(end) >= top ? ((UInt64(end) - top + 65_536) & ~UInt64(65_535)) : 0
        return UInt32(min(top + extra, UInt64(ceiling)))
    }

    /// SPIM doubles the stack for nearby references unless that would exceed -lstack.
    @discardableResult
    private func growStack(to address: UInt32) -> Bool {
        if address >= stackBottom && address < 0x80000000 { return true }
        guard address > heap && address < stackBottom,
              stackBottom - address < 16 * 1024 * 1024 else { return false }
        let oldSize = 0x80000000 - stackBottom
        let delta = aligned(stackBottom - address + 4)
        let newSize = UInt64(oldSize) + UInt64(max(oldSize, delta))
        guard newSize <= UInt64(options.memoryLayout.stackLimit), newSize <= 0x80000000,
              0x80000000 - newSize > UInt64(heap) else { return false }
        stackBottom = 0x80000000 - UInt32(newSize)
        return true
    }
    private func isText(_ address: UInt32) -> Bool {
        (address >= 0x00400000 && address < textTop) || (address >= 0x80000000 && address < kernelTextTop)
    }
    private func mapped(_ address: UInt32) -> Bool {
        (address >= 0x00400000 && address < textTop)
        || (address >= 0x10000000 && address < heap)
        || (address >= stackBottom && address < 0x80000000)
        || (address >= 0x90000000 && address < kernelDataTop)
    }

    private func load(_ address: UInt32, size: Int) throws -> UInt32 {
        if size > 1 && (address & UInt32(size - 1)) != 0 { throw AccessError.exception(4, address) }
        if address >= 0xffff0000 {
            switch address {
            case 0xffff0000: return (mmReceiverReady ? 1 : 0) | (mmReceiverIRQ ? 2 : 0)
            case 0xffff0004:
                mmReceiverReady = false; mmReceiverAvailableAt = ioPollCount
                coprocessor0[13] &= ~0x0800
                return UInt32(mmReceiverValue)
            case 0xffff0008: return (ioPollCount >= mmSenderAvailableAt ? 1 : 0) | (mmSenderIRQ ? 2 : 0)
            case 0xffff000c: return UInt32(mmSenderValue)
            default: return 0
            }
        }
        if !mapped(address) { _ = growStack(to: address) }
        var result: UInt32 = 0
        for i in 0..<size {
            let addr = address &+ UInt32(i)
            guard mapped(addr) else { throw AccessError.exception(7, addr) }
            let offset = Int(addr & 3)
            let codeShift = (options.littleEndian ? offset : 3 - offset) * 8
            let byte = memory[addr] ?? UInt8(truncatingIfNeeded: (code[addr & ~UInt32(3)] ?? 0) >> codeShift)
            result |= UInt32(byte) << ((options.littleEndian ? i : size - i - 1) * 8)
        }
        return result
    }

    private func store(_ value: UInt32, at address: UInt32, size: Int) throws {
        if size > 1 && (address & UInt32(size - 1)) != 0 { throw AccessError.exception(5, address) }
        if address >= 0xffff0000 {
            switch address {
            case 0xffff0000:
                mmReceiverIRQ = value & 2 != 0
                if mmReceiverIRQ && mmReceiverReady { coprocessor0[13] |= 0x0800 }
                else if !mmReceiverIRQ { coprocessor0[13] &= ~0x0800 }
            case 0xffff0008:
                mmSenderIRQ = value & 2 != 0
                if mmSenderIRQ && ioPollCount >= mmSenderAvailableAt { coprocessor0[13] |= 0x0400 }
                else if !mmSenderIRQ { coprocessor0[13] &= ~0x0400 }
            case 0xffff000c:
                if ioPollCount >= mmSenderAvailableAt {
                    mmSenderValue = UInt8(truncatingIfNeeded: value)
                    emit([mmSenderValue])
                    mmSenderAvailableAt = ioPollCount &+ 101
                    mmSenderWasReady = false
                    coprocessor0[13] &= ~0x0400
                }
            default: break
            }
            return
        }
        if address >= 0x00400000, address < textTop, code[address & ~UInt32(3)] == nil {
            let base = address & ~UInt32(3)
            code[base] = size == 4 ? value : 0
            runtimeCodeWrites.insert(base); codeRevision &+= 1
            return
        }
        if !mapped(address) { _ = growStack(to: address) }
        for i in 0..<size {
            let addr = address &+ UInt32(i)
            guard mapped(addr) else { throw AccessError.exception(7, addr) }
        }
        for i in 0..<size {
            let addr = address &+ UInt32(i)
            let byte = UInt8(truncatingIfNeeded: value >> ((options.littleEndian ? i : size - i - 1) * 8))
            let base = addr & ~UInt32(3)
            if let current = code[base] {
                executionWords[base] = nil
                runtimeCodeWrites.insert(base); codeRevision &+= 1
                let offset = Int(addr & 3)
                let bits = (options.littleEndian ? offset : 3 - offset) * 8
                code[base] = current & ~(0xff << bits) | UInt32(byte) << bits
            } else {
                memory[addr] = byte
            }
        }
    }

    private func exception(_ type: UInt32, badAddress: UInt32? = nil) {
        if let addr = badAddress { coprocessor0[8] = addr }
        if coprocessor0[12] & 2 == 0 {
            coprocessor0[14] = (pendingBranch == nil ? pc : pc &- 4) & ~UInt32(3)
            coprocessor0[13] = (coprocessor0[13] & 0x0000ff00) | (type << 2)
            if pendingBranch != nil { coprocessor0[13] |= 0x80000000 }
        } else {
            coprocessor0[13] = coprocessor0[13] & ~0x7c | type << 2
        }
        coprocessor0[12] |= 2
        pendingBranch = nil
        if !options.quiet && type != 0 {
            var message = ""
            message += String(format: "Exception occurred at PC=0x%08x\n", coprocessor0[14])
            switch type {
            case 4: message += String(format: "  Unaligned address in inst/data fetch: 0x%08x\n", coprocessor0[8])
            case 5: message += String(format: "  Unaligned address in store: 0x%08x\n", coprocessor0[8])
            case 6: message += String(format: "  Bad address in text read: 0x%08x\n", coprocessor0[8])
            case 7: message += String(format: "  Bad address in data/stack read: 0x%08x\n", coprocessor0[8])
            case 8: message += "  Error in syscall\n"
            case 9: break
            case 10: message += "  Reserved instruction execution\n"
            case 11: message += "  Coprocessor unuable\n"
            case 12: message += "  Arithmetic overflow\n"
            case 13: message += "  Trap\n"
            case 15: message += "  Floating point\n"
            default: message += "Unknown exception: \(type)\n"
            }
            diagnosticOutput += message
            terminalErrorBytes.append(contentsOf: message.utf8)
        }
        pc = 0x80000180
    }

    private func pollTimer() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - timerMark >= 0.01 {
            let increments = options.upstreamInterruptSampling ? UInt32(1)
                : UInt32(min((now - timerMark) * 100, Double(UInt32.max)))
            let old = coprocessor0[9]
            coprocessor0[9] = old &+ increments
            if coprocessor0[11] &- old <= increments && coprocessor0[11] != old { coprocessor0[13] |= 0x8000 }
            timerMark = options.upstreamInterruptSampling ? now : timerMark + Double(increments) / 100
        }
    }
    private func pollMappedIO() {
        if !input.isEmpty && ioPollCount >= mmReceiverAvailableAt {
            mmReceiverValue = input.removeFirst()
            mmReceiverReady = true
            mmReceiverAvailableAt = ioPollCount &+ 101
            if mmReceiverIRQ { coprocessor0[13] |= 0x0800 }
        }
        let senderReady = ioPollCount >= mmSenderAvailableAt
        if senderReady && !mmSenderWasReady && mmSenderIRQ { coprocessor0[13] |= 0x0400 }
        mmSenderWasReady = senderReady
        ioPollCount &+= 1
    }

    private func execute(sample: Bool = true) {
        if sample && mmio && (options.upstreamInterruptSampling || instructionCount % 100 == 0) { pollMappedIO() }
        if sample && coprocessor0[12] & 3 == 1 && coprocessor0[12] & coprocessor0[13] & 0xff00 != 0 {
            exception(0)
        }
        pollTimer()
        guard pc & 3 == 0 else { exception(6, badAddress: pc); return }
        guard isText(pc) else { exception(6, badAddress: pc); return }
        guard let word = executionWords[pc] ?? code[pc] else {
            status = .fault("Attempt to execute non-instruction at " + String(format: "0x%08x", pc))
            return
        }
        if let symbol = image.unresolvedInstructions[pc], !runtimeCodeWrites.contains(pc), code[pc] == image.instructions[pc]?.word {
            let instruction = image.instructions[pc]!
            var disassembly = SpimDisassembler.format(word, at: pc, delayedBranches: branchDelay)
            if [UInt32(1), 4, 5, 6, 7, 20, 21, 22, 23].contains(word >> 26), let comma = disassembly.lastIndex(of: ",") {
                disassembly = String(disassembly[...comma]) + " 0"
            }
            let relative = [UInt32(1), 4, 5, 6, 7, 17, 20, 21, 22, 23].contains(word >> 26)
            let expression = relative ? String(format: "%@-0x%08x", symbol, pc) : symbol
            var row = String(format: "[0x%08x]\t0x%08x  ", pc, word) + disassembly + " [" + expression + "]"
            if !instruction.source.isEmpty {
                row += String(repeating: " ", count: max(0, 57 - row.utf8.count))
                row += "; \(instruction.line): " + instruction.source
            }
            status = .fault(String(format: "Instruction references undefined symbol at 0x%08x\n  ", pc) + row)
            return
        }
        if word & 0xfc00003f == 12 {
            let service = registers[2]
            let stdinRead = service == 14 && registers[4] == 0 && registers[6] != 0
            let characters = service == 12 || stdinRead
            if !inputEnded, (stdinRead || [UInt32(5), 6, 7, 12].contains(service) || (service == 8 && Int32(bitPattern: registers[5]) > 1)),
               characters ? input.isEmpty : (!input.contains(10) && input.count < (service == 8 ? max(0, Int(registers[5]) - 1) : 255)) {
                status = .waitingInput
                return
            }
        }

        let current = pc
        let delayTarget = pendingBranch
        var next = delayTarget ?? (current &+ 4)
        var branch: UInt32?
        nextLoad = nil
        let op = word >> 26, function = word & 63
        let rs = Int(word >> 21 & 31), rt = Int(word >> 16 & 31)
        let rd = Int(word >> 11 & 31), sh = Int(word >> 6 & 31)
        let imm = word & 0xffff
        let simm = u(Int32(Int16(bitPattern: UInt16(imm))))
        let a = registers[rs], b = registers[rt]
        let previousLoad = pendingLoad
        func floatingWord(_ index: Int) -> UInt32 { floatingRegisters[index] }
        pendingLoad = nil
        let addr = a &+ simm
        let link = current &+ (branchDelay ? 8 : 4)
        func g(_ dest: Int, _ value: UInt32) { if dest != 0 { registers[dest] = value } }
        func delayed(_ dest: Int, _ value: UInt32, floating: Bool = false) {
            if loadDelay { nextLoad = (dest, value, floating) }
            else if floating { floatingRegisters[dest] = value }
            else { g(dest, value) }
        }
        func jump(_ target: UInt32) {
            if branchDelay { branch = target } else { next = target }
        }
        func conditional(_ yes: Bool, likely: Bool = false) {
            if yes { jump(current &+ (branchDelay ? 4 : 0) &+ (simm << 2)) }
            else if likely { if delayTarget == nil { next = current &+ 8 } }
            else if branchDelay { branch = current &+ 8 }
        }
        func arithmetic(_ lhs: UInt32, _ rhs: UInt32, subtract: Bool = false) throws -> UInt32 {
            let result = subtract ? s(lhs).subtractingReportingOverflow(s(rhs)) : s(lhs).addingReportingOverflow(s(rhs))
            if result.overflow { throw AccessError.exception(12, nil) }
            return u(result.partialValue)
        }
        func trap(_ yes: Bool) throws { if yes { throw AccessError.exception(13, nil) } }
        func hilo(_ value: UInt64) { hi = UInt32(truncatingIfNeeded: value >> 32); lo = UInt32(truncatingIfNeeded: value) }
        let signedProduct = { UInt64(bitPattern: Int64(self.s(a)) * Int64(self.s(b))) }
        let unsignedProduct = { UInt64(a) * UInt64(b) }
        do {
            switch op {
            case 0:
                switch function {
                case 0: g(rd, b << sh)
                case 1: if condition(Int(word >> 18 & 7)) == (rt & 1 != 0) { g(rd, a) }
                case 2: g(rd, b >> sh)
                case 3: g(rd, u(s(b) >> sh))
                case 4: g(rd, b << (a & 31))
                case 6: g(rd, b >> (a & 31))
                case 7: g(rd, u(s(b) >> (a & 31)))
                case 8: jump(a)
                case 9: g(rd, link); jump(a)
                case 10: if b == 0 { g(rd, a) }
                case 11: if b != 0 { g(rd, a) }
                case 12: try syscall()
                case 13: throw AccessError.exception(9, nil)
                case 15: break
                case 16: g(rd, hi)
                case 17: hi = a
                case 18: g(rd, lo)
                case 19: lo = a
                case 24: hilo(signedProduct())
                case 25: hilo(unsignedProduct())
                case 26: if b != 0 && !(a == 0x80000000 && b == 0xffffffff) { lo = u(s(a) / s(b)); hi = u(s(a) % s(b)) }
                case 27: if b != 0 && !(a == 0x80000000 && b == 0xffffffff) { lo = a / b; hi = a % b }
                case 32: g(rd, try arithmetic(a, b))
                case 33: g(rd, a &+ b)
                case 34: g(rd, try arithmetic(a, b, subtract: true))
                case 35: g(rd, a &- b)
                case 36: g(rd, a & b)
                case 37: g(rd, a | b)
                case 38: g(rd, a ^ b)
                case 39: g(rd, ~(a | b))
                case 42: g(rd, s(a) < s(b) ? 1 : 0)
                case 43: g(rd, a < b ? 1 : 0)
                case 48: try trap(s(a) >= s(b))
                case 49: try trap(a >= b)
                case 50: try trap(s(a) < s(b))
                case 51: try trap(a < b)
                case 52: try trap(a == b)
                case 54: try trap(a != b)
                default: throw AccessError.exception(10, nil)
                }
            case 1:
                switch rt {
                case 0, 1, 2, 3, 16, 17, 18, 19:
                    if rt & 16 != 0 { g(31, link) }
                    conditional(rt & 1 != 0 ? s(a) >= 0 : s(a) < 0, likely: rt & 2 != 0)
                case 8: try trap(s(a) >= s(simm))
                case 9: try trap(a >= simm)
                case 10: try trap(s(a) < s(simm))
                case 11: try trap(a < simm)
                case 12: try trap(a == simm)
                case 14: try trap(a != simm)
                default: throw AccessError.exception(10, nil)
                }
            case 2: jump((current & 0xf0000000) | ((word & 0x03ffffff) << 2))
            case 3: g(31, link); jump((current & 0xf0000000) | ((word & 0x03ffffff) << 2))
            case 4, 20: conditional(a == b, likely: op == 20)
            case 5, 21: conditional(a != b, likely: op == 21)
            case 6, 22: conditional(s(a) <= 0, likely: op == 22)
            case 7, 23: conditional(s(a) > 0, likely: op == 23)
            case 8: g(rt, try arithmetic(a, simm))
            case 9: g(rt, a &+ simm)
            case 10: g(rt, s(a) < s(simm) ? 1 : 0)
            case 11: g(rt, a < simm ? 1 : 0)
            case 12: g(rt, a & imm)
            case 13: g(rt, a | imm)
            case 14: g(rt, a ^ imm)
            case 15: g(rt, imm << 16)
            case 16:
                switch rs {
                case 0: g(rt, coprocessor0[rd])
                case 2: g(rt, coprocessor0Control[rd])
                case 6: coprocessor0Control[rd] = b
                case 4:
                    switch rd {
                    case 11: coprocessor0[11] = b; coprocessor0[13] &= ~0x8000
                    case 12: coprocessor0[12] = b & 0xf000ff13 | 0x30000010
                    case 13: coprocessor0[13] = b & 0x8000ff7c
                    case 16: coprocessor0[16] = b & 0x000fc380
                    default: coprocessor0[rd] = b
                    }
                case 16:
                    switch function {
                    case 24: coprocessor0[12] &= ~2; jump(coprocessor0[14])
                    case 1, 2, 6, 8, 16: throw AccessError.exception(10, nil)
                    default: throw AccessError.exception(10, nil)
                    }
                default: throw AccessError.exception(10, nil)
                }
            case 17:
                if rs == 8 {
                    conditional(condition(rt >> 2) == (rt & 1 != 0), likely: rt & 2 != 0)
                } else { try floatInstruction(word: word, format: rs, rt: rt, fs: rd, fd: sh, function: function, rtValue: b, readWord: floatingWord) }
            case 18, 50, 54, 58, 62: throw AccessError.exception(11, nil)
            case 28:
                let hl = UInt64(hi) << 32 | UInt64(lo)
                switch function {
                case 0: hilo(hl &+ signedProduct())
                case 1: hilo(hl &+ unsignedProduct())
                case 2: hilo(signedProduct()); g(rd, lo)
                case 4: hilo(hl &- signedProduct())
                case 5: hilo(hl &- unsignedProduct())
                case 32: g(rd, UInt32(a.leadingZeroBitCount))
                case 33: g(rd, UInt32((~a).leadingZeroBitCount))
                default: throw AccessError.exception(10, nil)
                }
            case 32: delayed(rt, u(Int32(Int8(bitPattern: UInt8(try load(addr, size: 1))))))
            case 33: delayed(rt, u(Int32(Int16(bitPattern: UInt16(try load(addr, size: 2))))))
            case 34, 38:
                let old = try load(addr & ~UInt32(3), size: 4)
                let n = Int(addr & 3)
                if op == 34 {
                    let shift = 8 * (options.littleEndian ? 3 - n : n)
                    delayed(rt, (old << shift) | (b & ~(UInt32.max << shift)))
                } else {
                    let shift = 8 * (options.littleEndian ? n : 3 - n)
                    delayed(rt, (old >> shift) | (b & ~(UInt32.max >> shift)))
                }
            case 35: delayed(rt, try load(addr, size: 4))
            case 36: delayed(rt, try load(addr, size: 1))
            case 37: delayed(rt, try load(addr, size: 2))
            case 40: try store(b, at: addr, size: 1)
            case 41: try store(b, at: addr, size: 2)
            case 42, 46:
                let base = addr & ~UInt32(3), n = Int(addr & 3)
                let old = try load(base, size: 4)
                if op == 42 {
                    let shift = 8 * (options.littleEndian ? 3 - n : n)
                    try store((b >> shift) | (old & ~(UInt32.max >> shift)), at: base, size: 4)
                } else {
                    let shift = 8 * (options.littleEndian ? n : 3 - n)
                    try store((b << shift) | (old & ~(UInt32.max << shift)), at: base, size: 4)
                }
            case 43: try store(b, at: addr, size: 4)
            case 47, 51: break
            case 48: delayed(rt, try load(addr, size: 4))
            case 49: delayed(rt, try load(addr, size: 4), floating: true)
            case 53:
                guard rt < 31 else { throw AccessError.exception(10, nil) }
                delayed(rt, try load(addr, size: 4), floating: true)
                delayed(rt + 1, try load(addr &+ 4, size: 4), floating: true)
            case 56:
                // SPIM documents a simplified LL/SC model; an ordinary simulator
                // never runs more than one processor.
                try store(b, at: addr, size: 4)
            case 57: try store(floatingWord(rt), at: addr, size: 4)
            case 61:
                try store(floatingWord(rt & ~1), at: addr, size: 4)
                try store(floatingWord(rt | 1), at: addr &+ 4, size: 4)
            default: throw AccessError.exception(10, nil)
            }
            if case .running = status {
                pc = next
                pendingBranch = delayTarget == nil ? branch : nil
                pendingLoad = nextLoad
            }
        } catch AccessError.exception(let kind, let address) {
            exception(kind, badAddress: address)
        } catch {
            status = .fault(String(describing: error))
        }
        // SPIM's delayed load writeback happens after the intervening
        // instruction, including when that instruction wrote the same register.
        if let previousLoad {
            if previousLoad.2 { floatingRegisters[previousLoad.0] = previousLoad.1 }
            else if previousLoad.0 != 0 { registers[previousLoad.0] = previousLoad.1 }
        }
        registers[0] = 0
        instructionCount &+= 1
    }

    private func conditionMask(_ index: Int) -> UInt32 {
        index == 0 ? 1 << 23 : 1 << (24 + (index & 7))
    }

    private func condition(_ index: Int) -> Bool { fcsr & conditionMask(index) != 0 }

    public func doubleRegister(_ register: Int) -> Double {
        guard register >= 0 && register < 31 && register & 1 == 0 else { return 0 }
        let a = UInt64(floatingRegisters[register]), b = UInt64(floatingRegisters[register + 1])
        return Double(bitPattern: options.littleEndian ? (b << 32 | a) : (a << 32 | b))
    }

    public func setDoubleRegister(_ register: Int, _ value: Double) {
        guard register >= 0 && register < 31 && register & 1 == 0 else { return }
        let low = UInt32(truncatingIfNeeded: value.bitPattern)
        let high = UInt32(value.bitPattern >> 32)
        floatingRegisters[register] = options.littleEndian ? low : high
        floatingRegisters[register + 1] = options.littleEndian ? high : low
    }

    private func floatInstruction(word: UInt32, format: Int, rt: Int, fs: Int, fd: Int, function: UInt32, rtValue: UInt32, readWord: (Int) -> UInt32) throws {
        switch format {
        case 0:
            if rt != 0 { registers[rt] = readWord(fs) }
            return
        case 2:
            if rt != 0 { registers[rt] = fs == 31 ? fcsr : floatingControl[fs] }
            return
        case 4:
            floatingRegisters[fs] = rtValue
            return
        case 6:
            if fs == 31 {
                fcsr = rtValue
                if fcsr & ~0xfe800000 != 0 { throw AccessError.exception(15, nil) }
            } else if fs != 0 { floatingControl[fs] = rtValue }
            return
        case 16, 17, 20: break
        default: throw AccessError.exception(10, nil)
        }

        let single = format == 16, double = format == 17
        func numeric(_ index: Int) -> Double {
            if single { return Double(Float(bitPattern: readWord(index))) }
            if double {
                guard index & 1 == 0 else { return 0 }
                let low = UInt64(readWord(options.littleEndian ? index : index + 1))
                let high = UInt64(readWord(options.littleEndian ? index + 1 : index))
                return Double(bitPattern: high << 32 | low)
            }
            return Double(s(readWord(index)))
        }
        func assign(_ value: Double) {
            if single { floatingRegisters[fd] = Float(value).bitPattern }
            else if double { setDoubleRegister(fd, value) }
        }
        func assignWord(_ value: Double) {
            let truncated = value.rounded(.towardZero)
            if truncated.isFinite, truncated >= Double(Int32.min), truncated <= Double(Int32.max) {
                floatingRegisters[fd] = u(Int32(truncated))
            } else { floatingRegisters[fd] = 0x80000000 }
        }
        let a = numeric(fs), b = numeric(rt)
        switch function {
        case 0: assign(a + b)
        case 1: assign(a - b)
        case 2: assign(a * b)
        case 3: assign(a / b)
        case 4: assign(a.squareRoot())
        case 5: assign(abs(a))
        case 6:
            if single { floatingRegisters[fd] = readWord(fs) }
            else { assign(a) }
        case 7: assign(-a)
        case 12: assignWord(a + 0.5) // SPIM 9.1.24 truncates after adding 0.5.
        case 13, 36: assignWord(a)
        case 14: assignWord(a.rounded(.up))
        case 15: assignWord(a.rounded(.down))
        case 17: if condition(rt >> 2) == (rt & 1 != 0) { assign(a) }
        case 18: if rtValue == 0 { assign(a) }
        case 19: if rtValue != 0 { assign(a) }
        case 32: floatingRegisters[fd] = Float(a).bitPattern
        case 33:
            // The upstream op table encodes cvt.d.w with fmt=17 rather than
            // fmt=20. cvt.d.d is not an instruction, so both words can be
            // accepted here without colliding with a genuine instruction.
            setDoubleRegister(fd, double ? Double(s(readWord(fs))) : a)
        case 48...63:
            let flags = function & 15
            let unordered = a.isNaN || b.isNaN
            if unordered && flags & 8 != 0 { throw AccessError.exception(15, nil) }
            let result = (unordered && flags & 1 != 0)
                || (!unordered && a == b && flags & 2 != 0)
                || (!unordered && a < b && flags & 4 != 0)
            let mask = conditionMask(Int(word >> 8 & 7))
            if result { fcsr |= mask } else { fcsr &= ~mask }
        default: throw AccessError.exception(10, nil)
        }
    }

    private func emit(_ bytes: [UInt8]) {
        if !closedGuestDescriptors.contains(1) { outputBytes.append(contentsOf: bytes) }
    }
    private func terminatedString(_ address: UInt32) throws -> [UInt8] {
        var response: [UInt8] = []
        for i in 0..<1_048_576 {
            let byte = UInt8(try load(address &+ UInt32(i), size: 1))
            if byte == 0 { return response }
            response.append(byte)
        }
        throw AccessError.exception(7, address)
    }

    private func inputLine(maxBytes: Int) -> [UInt8] {
        var count = min(max(0, maxBytes), input.count)
        if let newline = input.firstIndex(of: 10), newline < count { count = newline + 1 }
        let bytes = Array(input.prefix(count))
        input.removeFirst(count)
        return bytes
    }

    private func validTransferBuffer(_ address: UInt32, count: UInt32) -> Bool {
        if count == 0 { return true }
        let end = UInt64(address) + UInt64(count)
        guard end <= UInt64(UInt32.max) + 1 else { return false }
        if !mapped(address) { _ = growStack(to: address) }
        let ranges: [(UInt32, UInt32)] = [(0x00400000, textTop), (0x10000000, heap),
            (stackBottom, 0x80000000), (0x90000000, kernelDataTop)]
        return ranges.contains { address >= $0.0 && end <= UInt64($0.1) }
    }

    private func parseInt(_ bytes: [UInt8]) -> UInt32 {
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = text.first == "-"
        let start = text.first == "+" || negative ? text.dropFirst() : text[...]
        var value: UInt32 = 0
        for byte in start.utf8 {
            guard (48...57).contains(byte) else { break }
            value = value &* 10 &+ UInt32(byte - 48)
        }
        return negative ? 0 &- value : value
    }

    private func parseDouble(_ bytes: [UInt8]) -> Double {
        let text = String(decoding: bytes, as: UTF8.self)
        return text.withCString { strtod($0, nil) }
    }

    private func openInGuestDirectory(_ path: String, flags raw: UInt32, mode: UInt32) -> OpenFile? {
        guard let root = guestDirectory else {
            guard !options.restrictFileAccess else { return nil }
            let fd = path.withCString { open($0, Int32(bitPattern: raw), mode_t(mode & 0o777)) }
            guard fd >= 0 else { return nil }
            let access = Int32(raw & 3)
            return OpenFile(handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true),
                            readable: access != O_WRONLY, writable: access != O_RDONLY)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !path.hasPrefix("/"), !components.isEmpty, !components.contains("..") else { return nil }
        let access = Int32(raw & 3)
        guard access <= 2 else { return nil }
        // SPIM implements open using the native host's POSIX flag values.
        let flags = access | Int32(raw & UInt32(O_CREAT | O_EXCL | O_APPEND))
            | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let permissions = mode_t(mode & 0o777)
        let fd: Int32
        // Walk relative to directory descriptors on both platforms. Darwin
        // rejects O_NOFOLLOW_ANY combined with O_NOFOLLOW (EINVAL).
        // Each guest path component must be opened without following symlinks;
        // the user-selected root may itself use a system alias such as /tmp.
        let rootFD = root.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard rootFD >= 0 else { return nil }
        var current = rootFD
        defer { _ = close(current) }
        for component in components.dropLast() {
            let next = String(component).withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0)
            }
            guard next >= 0 else { return nil }
            _ = close(current)
            current = next
        }
        fd = String(components[components.count - 1]).withCString { openat(current, $0, flags, permissions) }
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            _ = close(fd)
            return nil
        }
        if raw & UInt32(O_TRUNC) != 0 && access != O_RDONLY && ftruncate(fd, 0) != 0 {
            _ = close(fd)
            return nil
        }
        return OpenFile(handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true), readable: access != O_WRONLY, writable: access != O_RDONLY)
    }

    private func syscall() throws {
        let service = registers[2], a0 = registers[4], a1 = registers[5], a2 = registers[6]
        switch service {
        case 1: emit(Array(String(s(a0)).utf8))
        case 2: emit(Array(String(format: "%.8f", Double(Float(bitPattern: floatingRegisters[12]))).utf8))
        case 3: emit(Array(String(format: "%.18g", doubleRegister(12)).utf8))
        case 4: emit(try terminatedString(a0))
        case 5: registers[2] = parseInt(inputLine(maxBytes: 255))
        case 6: floatingRegisters[0] = Float(parseDouble(inputLine(maxBytes: 255))).bitPattern
        case 7: setDoubleRegister(0, parseDouble(inputLine(maxBytes: 255)))
        case 8:
            guard Int32(bitPattern: a1) > 0 else { return }
            let bytes = inputLine(maxBytes: Int(a1) - 1) + [UInt8(0)]
            for (i, byte) in bytes.enumerated() { try store(UInt32(byte), at: a0 &+ UInt32(i), size: 1) }
        case 9:
            let request = Int64(Int32(bitPattern: a0))
            let newSize = Int64(heap - 0x10000000) + ((request + 3) & ~3)
            guard request >= 0, newSize >= 0, newSize <= Int64(options.memoryLayout.dataLimit),
                  UInt64(0x10000000) + UInt64(newSize) <= UInt64(stackBottom) else {
                status = .fault("Can't expand data segment by \(request) bytes to \(newSize) bytes\nUse -ldata # with # > \(newSize)")
                return
            }
            registers[2] = heap
            heap = 0x10000000 + UInt32(newSize)
        case 10: status = .halted(0)
        case 11: emit([UInt8(truncatingIfNeeded: a0)])
        case 12:
            let byte: UInt8 = input.isEmpty ? 0 : input.removeFirst()
            registers[2] = byte == 0 ? 10 : UInt32(bitPattern: Int32(Int8(bitPattern: byte)))
        case 13:
            let path = String(decoding: try terminatedString(a0), as: UTF8.self)
            guard let file = openInGuestDirectory(path, flags: a1, mode: a2) else {
                registers[2] = .max
                return
            }
            var descriptor: UInt32 = 3
            while files[descriptor] != nil { descriptor &+= 1 }
            files[descriptor] = file
            registers[2] = descriptor
        case 14:
            let count = Int(a2)
            guard (a0 == 0 && !closedGuestDescriptors.contains(0)) || files[a0]?.readable == true else { registers[2] = .max; return }
            if count == 0 { registers[2] = 0; return }
            guard validTransferBuffer(a1, count: a2) else { registers[2] = .max; return }
            let data: [UInt8]
            if a0 == 0 {
                let received = min(count, input.count)
                data = Array(input.prefix(received)); input.removeFirst(received)
            }
            else if let file = files[a0], file.readable {
                do { data = Array(try file.handle.read(upToCount: count) ?? Data()) }
                catch { registers[2] = .max; return }
            } else { registers[2] = .max; return }
            for (i, byte) in data.enumerated() { try store(UInt32(byte), at: a1 &+ UInt32(i), size: 1) }
            registers[2] = UInt32(data.count)
        case 15:
            let count = Int(a2)
            guard ((a0 == 1 || a0 == 2) && !closedGuestDescriptors.contains(a0)) || files[a0]?.writable == true,
                  validTransferBuffer(a1, count: a2) else { registers[2] = .max; return }
            var data: [UInt8] = []
            data.reserveCapacity(count)
            for i in 0..<count { data.append(UInt8(try load(a1 &+ UInt32(i), size: 1))) }
            if a0 == 1 || a0 == 2 {
                guard !closedGuestDescriptors.contains(a0) else { registers[2] = .max; return }
                if a0 == 1 { emit(data) } else { stderrBytes.append(contentsOf: data); terminalErrorBytes.append(contentsOf: data) }
            }
            else if let file = files[a0], file.writable {
                do { try file.handle.write(contentsOf: Data(data)) }
                catch { registers[2] = .max; return }
            } else { registers[2] = .max; return }
            registers[2] = UInt32(count)
        case 16:
            if a0 < 3 {
                if closedGuestDescriptors.contains(a0) { registers[2] = .max; return }
                closedGuestDescriptors.insert(a0)
                if a0 == 0 { input = []; inputEnded = true }
                registers[2] = 0
                return
            }
            if let file = files.removeValue(forKey: a0) {
                do { try file.handle.close(); registers[2] = 0 }
                catch { registers[2] = .max }
            } else { registers[2] = .max }
        case 17: status = .halted(s(a0))
        default: status = .fault("Unknown system call: \(service)")
        }
    }
}
