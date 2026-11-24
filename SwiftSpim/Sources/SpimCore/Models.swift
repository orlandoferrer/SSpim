import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct MemorySegment: Equatable {
    public enum Kind { case userData, stack, kernelData }
    public let kind: Kind
    public let lowerBound: UInt32
    public let upperBoundExclusive: UInt32
    public init(kind: Kind, lowerBound: UInt32, upperBoundExclusive: UInt32) {
        self.kind = kind; self.lowerBound = lowerBound; self.upperBoundExclusive = upperBoundExclusive
    }
}

/// Sparse segment capacities. Defaults mirror the QtSpim GUI's SPIM build.
public struct SpimMemoryLayout {
    public var userTextSize: UInt32 = 256 * 1024
    public var dataSize: UInt32 = 256 * 1024
    public var dataLimit: UInt32 = 1024 * 1024
    public var stackSize: UInt32 = 64 * 1024
    public var stackLimit: UInt32 = 256 * 1024
    public var kernelTextSize: UInt32 = 64 * 1024
    public var kernelDataSize: UInt32 = 64 * 1024
    public var kernelDataLimit: UInt32 = 1024 * 1024

    public init() {}

    public static let legacyFlags: Set<String> = [
        "-stext", "-st", "-sdata", "-sd", "-ldata", "-ld",
        "-sstack", "-ss", "-lstack", "-ls", "-sktext", "-skt",
        "-skdata", "-skd", "-lkdata", "-lkd"
    ]

    /// Legacy QtSpim switches take a positive decimal byte count. Cap each
    /// override before rounding to prevent overlap and integer overflow.
    @discardableResult
    public mutating func setLegacyOption(_ flag: String, bytes: UInt32) -> Bool {
        guard bytes > 0, bytes <= 0x0fc0_0000 else { return false }
        let aligned = (bytes &+ 3) & ~UInt32(3)
        switch flag {
        case "-stext", "-st": userTextSize = aligned
        case "-sdata", "-sd": dataSize = max(64 * 1024, aligned)
        case "-ldata", "-ld": dataLimit = bytes
        case "-sstack", "-ss": stackSize = aligned
        case "-lstack", "-ls": stackLimit = bytes
        case "-sktext", "-skt": kernelTextSize = aligned
        case "-skdata", "-skd": kernelDataSize = aligned
        case "-lkdata", "-lkd": kernelDataLimit = bytes
        default: return false
        }
        return true
    }
}

public struct SpimOptions {
    public var bareMachine: Bool
    public var littleEndian: Bool
    public var delayedBranches: Bool
    public var delayedLoads: Bool
    public var mappedIO: Bool
    public var loadExceptionHandler: Bool
    public var acceptPseudoInstructions: Bool
    public var startAddress: UInt32?
    public var arguments: [String]
    public var fileRootURL: URL?
    /// Optional SwiftSpim restriction; false preserves upstream host file I/O.
    public var restrictFileAccess = false
    public var quiet = false
    public var environment: [String] = []
    public var strictEntryPoint = false
    public var upstreamInterruptSampling = false
    public var memoryLayout: SpimMemoryLayout

    public init(
        bareMachine: Bool = false, littleEndian: Bool = true, delayedBranches: Bool = false,
        delayedLoads: Bool = false, mappedIO: Bool = false, loadExceptionHandler: Bool = true,
        acceptPseudoInstructions: Bool = true, startAddress: UInt32? = nil,
        arguments: [String] = [], fileRootURL: URL? = nil,
        memoryLayout: SpimMemoryLayout = .init(), quiet: Bool = false,
        environment: [String] = [], strictEntryPoint: Bool = false,
        restrictFileAccess: Bool = false
    ) {
        self.bareMachine = bareMachine
        self.littleEndian = littleEndian
        self.delayedBranches = delayedBranches
        self.delayedLoads = delayedLoads
        self.mappedIO = mappedIO
        self.loadExceptionHandler = loadExceptionHandler
        self.acceptPseudoInstructions = acceptPseudoInstructions
        self.startAddress = startAddress
        self.arguments = arguments
        self.fileRootURL = fileRootURL
        self.memoryLayout = memoryLayout
        self.quiet = quiet
        self.environment = environment
        self.strictEntryPoint = strictEntryPoint
        self.restrictFileAccess = restrictFileAccess
    }
    public var usesMappedIO: Bool { mappedIO && !bareMachine }

    /// Preserve the native environment vector's order for SPIM's stack ABI.
    /// Callers can inject a small controlled vector for deterministic tests.
    public static func hostEnvironment() -> [String] {
        let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = environ
        guard let pointer else { return [] }
        var result: [String] = [], index = 0
        while let value = pointer[index] {
            result.append(String(cString: value)); index += 1
        }
        return result
    }
}

public struct Instruction: Hashable {
    public var word: UInt32
    public var source: String
    public var line: Int
    public var filename: String
    /// SPIM stores semantic operands separately from its printed word for
    /// certain opcodes. A nil override means execute the displayed word.
    public var executionWord: UInt32?
    public init(word: UInt32, source: String = "", line: Int = 0, filename: String = "",
                executionWord: UInt32? = nil) {
        self.word = word
        self.source = source
        self.line = line
        self.filename = filename
        self.executionWord = executionWord
    }
}

public struct ProgramImage {
    public var instructions: [UInt32: Instruction]
    public var data: [UInt32: UInt8]
    public var symbols: [String: UInt32]
    public var dataEnd: UInt32
    public var kernelDataEnd: UInt32
    public var unresolvedSymbols: [String]
    public var diagnostics: [AssemblyError] = []
    public var unresolvedInstructions: [UInt32: String] = [:]
    public init(
        instructions: [UInt32: Instruction] = [:], data: [UInt32: UInt8] = [:],
        symbols: [String: UInt32] = [:], dataEnd: UInt32 = 0x1000_0000, unresolvedSymbols: [String] = [],
        kernelDataEnd: UInt32 = 0x9000_0000
    ) {
        self.instructions = instructions
        self.data = data
        self.symbols = symbols
        self.dataEnd = dataEnd
        self.kernelDataEnd = kernelDataEnd
        self.unresolvedSymbols = unresolvedSymbols
    }
}

public enum MachineStatus: Equatable {
    case ready
    case running
    case paused
    case waitingInput
    case halted(Int32)
    case fault(String)
}
