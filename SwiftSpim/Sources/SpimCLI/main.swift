import Foundation
import SpimCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func diagnostic(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func printUsage() {
    print("""
    Usage: swiftspim-cli [OPTIONS] -file PROGRAM [GUEST ARGUMENTS]
      -asm, -bare                     Extended assembler or bare machine
      -pseudo, -nopseudo              Permit or reject pseudo-instructions
      -exception, -noexception        Use or omit the standard exception handler
      -ef FILE                        Load a custom assembly exception handler
      -delayed_branches, -delayed_loads
      -mapped_io, -nomapped_io        Toggle memory-mapped console
      -stext/-st BYTES, -sdata/-sd BYTES, -ldata/-ld BYTES
      -sstack/-ss BYTES, -lstack/-ls BYTES
      -sktext/-skt BYTES, -skdata/-skd BYTES, -lkdata/-lkd BYTES
                                      Set the original SPIM segment sizes and limits
      --big-endian                    Use big-endian guest memory
      --pc ADDRESS                    Specify the starting address
      --dump-instruction-words        Assemble only; print address and word pairs
      --guest-directory DIRECTORY     Restrict guest file operations to DIRECTORY
      --no-file-io                    Disable guest host-file access
      --max-steps COUNT               Maximum number of simulated instructions (default 10,000,000)
      --help                          Show this help
    """)
}

func execute() throws -> Int32 {
    let argv = Array(CommandLine.arguments.dropFirst())
    var options = SpimOptions(environment: SpimOptions.hostEnvironment(), strictEntryPoint: true)
    // Upstream builds its terminal reference with different initial capacities
    // than the Qt application. Keep the GUI defaults in the shared core.
    options.upstreamInterruptSampling = true
    options.memoryLayout.userTextSize = 64 * 1024
    options.memoryLayout.dataSize = 128 * 1024
    var files: [String] = []
    var exceptions: String?
    var maxSteps = 10_000_000
    var dumpWords = false
    var index = 0
    func value(for option: String) throws -> String {
        index += 1
        guard index < argv.count else { throw CLIError("Missing value for \(option)") }
        return argv[index]
    }
    while index < argv.count {
        let option = argv[index]
        switch option {
        case "-h", "--help": printUsage(); return 0
        case "-asm", "-a": options.bareMachine = false; options.delayedBranches = false; options.delayedLoads = false
        case "-bare", "-b": options.bareMachine = true; options.delayedBranches = true; options.delayedLoads = true; options.quiet = true
        case "-pseudo", "-p": options.acceptPseudoInstructions = true
        case "-nopseudo", "-np": options.acceptPseudoInstructions = false
        case "-exception", "-e", "-trap", "-t": options.loadExceptionHandler = true
        case "-noexception", "-ne", "-notrap", "-nt": options.loadExceptionHandler = false
        case "-ef", "-exception_file", "-trap_file", "-tf": exceptions = try value(for: option); options.loadExceptionHandler = true
        case "-delayed_branches", "-db": options.delayedBranches = true
        case "-delayed_loads", "-dl": options.delayedLoads = true
        case "-mapped_io", "-mio": options.mappedIO = true
        case "-nomapped_io", "-nmio": options.mappedIO = false
        case "--big-endian": options.littleEndian = false
        case "--dump-instruction-words": dumpWords = true
        case "--pc":
            let raw = try value(for: option)
            let number = raw.lowercased().hasPrefix("0x") ? UInt32(raw.dropFirst(2), radix: 16) : UInt32(raw)
            guard let number else { throw CLIError("Invalid start address: \(raw)") }
            options.startAddress = number
        case "--guest-directory":
            options.fileRootURL = URL(fileURLWithPath: try value(for: option), isDirectory: true)
            options.restrictFileAccess = true
        case "--no-file-io": options.restrictFileAccess = true; options.fileRootURL = nil
        case "--max-steps":
            guard let parsed = Int(try value(for: option)), parsed > 0 else { throw CLIError("Maximum steps must be positive") }
            maxSteps = parsed
        case "-file", "-f":
            files.append(try value(for: option))
            options.arguments = Array(argv[index...])
            index = argv.count
        case let flag where SpimMemoryLayout.legacyFlags.contains(flag):
            guard let bytes = UInt32(try value(for: flag)), options.memoryLayout.setLegacyOption(flag, bytes: bytes) else {
                throw CLIError("Invalid byte count for \(flag)")
            }
        case "-quiet", "-q": options.quiet = true
        case "-noquiet", "-nq": options.quiet = false
        default:
            guard !option.hasPrefix("-") else { throw CLIError("Unknown option: \(option)") }
            files.append(option)
            options.arguments = Array(argv[index...])
            index = argv.count
        }
        index += 1
    }
    guard !files.isEmpty else { printUsage(); return 2 }
    func readSource(_ path: String) throws -> SourceInput {
        SourceInput(name: path, data: try Data(contentsOf: URL(fileURLWithPath: path)))
    }
    var sources = try files.map(readSource)
    let willLoadHandler = options.loadExceptionHandler
    if options.loadExceptionHandler, let exceptions {
        options.loadExceptionHandler = false
        var handlerSource = try readSource(exceptions)
        handlerSource.isExceptionHandler = true
        sources.insert(handlerSource, at: 0)
    }
    if options.arguments.isEmpty { options.arguments = [files[0]] }
    if !options.quiet && willLoadHandler {
        print("Loaded: " + (exceptions ?? "exceptions.s")); fflush(stdout)
    }
    let image = try Assembler().assemble(sources, options: options, recovering: true)
    for warning in image.diagnostics {
        FileHandle.standardError.write(Data(warning.spimDescription.utf8))
    }
    if dumpWords {
        for address in image.instructions.keys.sorted() {
            if let instruction = image.instructions[address] {
                print(String(format: "0x%08x 0x%08x", address, instruction.word))
            }
        }
        return 0
    }
    let machine = Machine(image: image, options: options)
    if !image.unresolvedSymbols.isEmpty {
        print("The following symbols are undefined:\n" + image.unresolvedSymbols.joined(separator: "\n") + "\n")
        fflush(stdout)
    }
    var remaining = maxSteps
    var mappedInputEnded = false
    func feedMappedInput() {
        guard options.mappedIO, !options.bareMachine, !mappedInputEnded else { return }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0, (descriptor.revents & Int16(POLLIN | POLLHUP)) != 0 else { return }
        var buffer = Array(repeating: UInt8(0), count: 8_192)
        let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
        if count > 0 { machine.provideInput(bytes: Array(buffer.prefix(count))) }
        else if count == 0 { mappedInputEnded = true; machine.endInput() }
    }
    var firstBatch = true
    while remaining > 0 {
        feedMappedInput()
        let chunk = min(remaining, 10_000)
        let before = machine.instructionCount
        machine.run(maxSteps: chunk, pollAtStart: firstBatch, logicalBatchSteps: maxSteps)
        firstBatch = false
        let used = machine.instructionCount &- before
        remaining -= Int(min(UInt64(chunk), max(1, used)))
        if !machine.outputBytes.isEmpty {
            FileHandle.standardOutput.write(Data(machine.outputBytes))
            machine.outputBytes = []
        }
        let errors = machine.takeStderrBytes()
        _ = machine.takeDiagnostics()
        machine.stderrBytes = []
        if !errors.isEmpty { FileHandle.standardError.write(Data(errors)) }
        switch machine.status {
        case .halted(let code): return code
        case .fault(let reason):
            diagnostic(reason)
            return 0
        case .waitingInput:
            let service = machine.registers[2]
            if service == 14 {
                let requested = Int(machine.registers[6])
                guard requested <= Int(options.memoryLayout.dataLimit) + Int(options.memoryLayout.stackLimit) + Int(options.memoryLayout.kernelDataLimit) else {
                    throw CLIError("Invalid guest read buffer size")
                }
                var bytes = [UInt8](repeating: 0, count: requested)
                let count = bytes.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, requested) }
                if count > 0 { machine.provideInput(bytes: Array(bytes.prefix(count))) }
                else if count == 0 { machine.endInput() }
                else if errno != EINTR { throw CLIError("Unable to read program input") }
            } else {
                let maximum = service == 12 ? 1 : service == 8 ? max(0, Int(Int32(bitPattern: machine.registers[5])) - 1) : 255
                var bytes: [UInt8] = []
                var ended = false
                while bytes.count < maximum {
                    var byte: UInt8 = 0
                    let count = read(STDIN_FILENO, &byte, 1)
                    if count == 0 { ended = true; break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw CLIError("Unable to read program input")
                    }
                    bytes.append(byte)
                    if byte == 10 { break }
                }
                if !bytes.isEmpty { machine.provideInput(bytes: bytes) }
                if ended { machine.endInput() }
            }
        default: break
        }
    }
    throw CLIError("Instruction budget exceeded (\(maxSteps)) at \(String(format: "0x%08x", machine.pc))")
}

do { exit(try execute()) }
catch { diagnostic(String(describing: error)); exit(1) }
