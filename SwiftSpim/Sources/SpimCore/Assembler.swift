import Foundation

public struct SourceInput: Sendable {
    public enum LiteralEncoding: Sendable { case utf8, latin1 }
    public var name: String
    public var text: String
    public var literalEncoding: LiteralEncoding = .utf8
    public var isExceptionHandler = false
    public init(name: String, text: String) { self.name = name; self.text = text }
    public init(name: String, data: Data) {
        self.name = name
        if let text = String(data: data, encoding: .utf8) { self.text = text }
        else {
            self.text = String(String.UnicodeScalarView(data.map { UnicodeScalar(UInt32($0))! }))
            literalEncoding = .latin1
        }
    }
}

public struct AssemblyError: LocalizedError, CustomStringConvertible {
    public var filename: String
    public var line: Int
    public var message: String
    public var source: String = ""
    public var diagnosticColumn: Int? = nil
    public var endsLine = false
    public var lineOffset = 0
    public var omitSource = false
    public var description: String { "\(filename):\(line): \(message)" }
    public var errorDescription: String? { description }
    public var spimDescription: String {
        if message.hasPrefix("Target of jump differs") { return message + "\n" }
        let immediate = message.hasPrefix("immediate value")
        let shift = message.hasPrefix("Shift distance")
        let text = message == "syntax error" ? source : source.trimmingCharacters(in: .whitespaces)
        let column: Int
        if let diagnosticColumn { column = diagnosticColumn }
        else if immediate || endsLine { column = text.count }
        else if shift { column = text.lastIndex(where: \.isWhitespace).map { text.distance(from: text.startIndex, to: $0) + 1 } ?? 0 }
        else {
            let leading = text.prefix(while: \.isWhitespace).count
            column = leading + text.dropFirst(leading).prefix(while: { !$0.isWhitespace }).count + 1
        }
        let header = "spim: (parser) \(message) on line \(line + lineOffset + ((immediate || endsLine) ? 1 : 0)) of file \(filename)\n"
        if omitSource { return header }
        return header + "\t  \(text)\n" + ((immediate || endsLine) ? "\n" : "") + "\t  " + String(repeating: " ", count: column) + "^\n"
    }
}

public struct Assembler {
    public init() {}
    public func assemble(_ sources: [SourceInput], options: SpimOptions = .init(),
                         allowUndefinedSymbols: Bool = false, recovering: Bool = false) throws -> ProgramImage {
        var inputs = sources
        if options.loadExceptionHandler, allowUndefinedSymbols || !sources.isEmpty {
            var handler = SourceInput(name: "exceptions.s", text: StandardExceptionHandler.source)
            handler.isExceptionHandler = true
            inputs.insert(handler, at: 0)
        }
        return try AssemblyState(options, recovering: recovering).assemble(inputs, allowUndefinedSymbols: allowUndefinedSymbols || recovering)
    }
}

private enum Section: Int { case text, data, ktext, kdata; var isText: Bool { self == .text || self == .ktext } }

private indirect enum Formula {
    case literal(UInt32)
    case symbol(String)
    case binary(String, Formula, Formula)

    var referencedSymbol: String? {
        switch self {
        case .literal: return nil
        case .symbol(let name): return name
        case .binary(_, let a, let b): return a.referencedSymbol ?? b.referencedSymbol
        }
    }

    func value(_ symbols: [String: UInt32]) -> UInt32? {
        switch self {
        case .literal(let n): return n
        case .symbol(let name): return symbols[name]
        case .binary(let op, let left, let right):
            guard let a = left.value(symbols), let b = right.value(symbols) else { return nil }
            switch op {
            case "+": return a &+ b
            case "-": return a &- b
            case "*": return a &* b
            case "/":
                guard b != 0 else { return nil }
                let quotient = Int64(Int32(bitPattern: a)) / Int64(Int32(bitPattern: b))
                return UInt32(truncatingIfNeeded: quotient)
            default: return nil
            }
        }
    }
}

private struct Expression {
    var symbol: String?
    var addend: UInt32
    var part: String? = nil
    var formula: Formula? = nil
    func value(_ symbols: [String: UInt32], adjust: Bool = false) -> UInt32? {
        let base: UInt32
        if let formula {
            guard let value = formula.value(symbols) else { return nil }
            base = value
        } else if let symbol {
            guard let value = symbols[symbol] else { return nil }
            base = value
        } else { base = 0 }
        let v = base &+ addend
        if part == "hi" { return (adjust ? v &+ 0x8000 : v) >> 16 }
        if part == "lo" { return v & 0xffff }
        return v
    }
    func adding(_ offset: UInt32) -> Expression { .init(symbol: symbol, addend: addend &+ offset, part: part, formula: formula) }
    func bits(_ part: String) -> Expression { .init(symbol: symbol, addend: addend, part: part, formula: formula) }
}

private final class AssemblyState {
    struct Fixup {
        var expression: Expression
        var filename: String
        var line: Int
        var active: () -> Bool
        var apply: (UInt32) -> Void
        var instructionAddress: UInt32? = nil
        var unresolved: (() -> Void)? = nil
    }
    var options: SpimOptions
    let recovering: Bool
    var image = ProgramImage()
    var jumpDiagnostics: [(UInt64, AssemblyError)] = []
    var pc: [UInt32]
    var highWater: [UInt32]
    var section = Section.text
    var file = ""
    var line = 0
    var original = ""
    var instructionSource = ""
    var sourceReturned = false
    var literalEncoding = SourceInput.LiteralEncoding.utf8
    var autoAlign = true
    var labels: [String] = []
    var fixups: [Fixup] = []
    var constants: [String: UInt32] = [:]
    var gpAddress: UInt32 = 0x10000000
    var noAT = false
    var activeDataSection = Section.data
    var gpSymbols: Set<String> = []
    var serial: UInt64 = 0
    var wordStamps: [UInt32: UInt64] = [:]
    var byteStamps: [UInt32: UInt64] = [:]
    var sourceIndex = 0
    var localNames: Set<String> = []
    private let scopeSeparator = "\u{1f}"
    func key(_ name: String) -> String {
        localNames.contains(name) ? String(sourceIndex) + scopeSeparator + name : name
    }
    func visibleName(_ key: String) -> String {
        key.firstIndex(of: Character(scopeSeparator)).map { String(key[key.index(after: $0)...]) } ?? key
    }
    var location: UInt32 {
        get { pc[section.rawValue] }
        set {
            pc[section.rawValue] = newValue
            highWater[section.rawValue] = max(highWater[section.rawValue], newValue)
        }
    }

    func checkBounds(_ address: UInt32, in segment: Section, bytes: UInt64 = 0) throws {
        let layout = options.memoryLayout
        let base: UInt32, initial: UInt32, limit: UInt32
        switch segment {
        case .text: (base, initial, limit) = (0x00400000, layout.userTextSize, layout.userTextSize)
        case .data: (base, initial, limit) = (0x10000000, max(65_536, layout.dataSize), layout.dataLimit)
        case .ktext: (base, initial, limit) = (0x80000000, layout.kernelTextSize, layout.kernelTextSize)
        case .kdata: (base, initial, limit) = (0x90000000, layout.kernelDataSize, layout.kernelDataLimit)
        }
        let alignedInitial = (UInt64(initial) + 3) & ~UInt64(3)
        let end = UInt64(address) + bytes
        let allowed = UInt64(base) + max(alignedInitial, UInt64(limit))
        guard address >= base, end <= allowed else {
            throw fail("Assembly exceeds the \(segment) segment bounds")
        }
        if !segment.isText, bytes > 0 {
            let mapped = UInt64(base) + alignedInitial
            if end >= mapped {
                // SPIM grows initialized data in 64 KiB increments, with an
                // exclusive high-water boundary. Check the actual rounded size.
                let growth = (end - mapped + 65_536) & ~UInt64(65_535)
                guard alignedInitial + growth <= UInt64(limit) else {
                    throw fail("Assembly exceeds the \(segment) segment growth limit")
                }
            }
        }
    }

    init(_ options: SpimOptions, recovering: Bool = false) {
        self.options = options
        self.recovering = recovering
        pc = [0x00400000, options.bareMachine ? 0x10000000 : 0x10010000, 0x80000000, 0x90000000]
        highWater = pc
    }

    func assemble(_ sources: [SourceInput], allowUndefinedSymbols: Bool) throws -> ProgramImage {
        for (sourceID, source) in sources.enumerated() {
            let savedBare = options.bareMachine, savedPseudo = options.acceptPseudoInstructions
            if source.isExceptionHandler { options.bareMachine = false; options.acceptPseudoInstructions = true }
            defer { options.bareMachine = savedBare; options.acceptPseudoInstructions = savedPseudo }
            sourceIndex = sourceID
            localNames = []
            var globals: Set<String> = []
            literalEncoding = source.literalEncoding
            let lines = source.text.components(separatedBy: "\n")
            for raw in lines {
                for tokens in (try? tokenize(String(raw))) ?? [] {
                    var i = 0
                    while i+1 < tokens.count, tokens[i+1] == ":" {
                        localNames.insert(tokens[i]); i += 2
                    }
                    guard i+1 < tokens.count else { continue }
                    if [".globl", ".global", ".extern", ".comm"].contains(tokens[i].lowercased()) {
                        globals.insert(tokens[i+1])
                    } else if [".lab", ".lcomm"].contains(tokens[i].lowercased()) {
                        localNames.insert(tokens[i+1])
                    } else if tokens[i+1] == "=" {
                        localNames.insert(tokens[i])
                    }
                }
            }
            // QtSpim recognizes the conventional entry symbol in separately
            // loaded sources without requiring callers of this API to qualify it.
            globals.formUnion(["main", "__start", "__eoth"])
            localNames.subtract(globals)
            file = source.name
            section = .text
            labels = []
            autoAlign = true
            noAT = false
            for (index, raw) in lines.enumerated() {
                line = index + 1
                original = String(raw).trimmingCharacters(in: .newlines)
                instructionSource = original.trimmingCharacters(in: .whitespaces)
                sourceReturned = false
                do {
                    for statement in try tokenize(original) {
                        try consume(statement)
                        try checkBounds(location, in: section)
                    }
                } catch let error as AssemblyError {
                    guard recovering, !error.message.hasPrefix("Encountered .err") else { throw error }
                    image.diagnostics.append(error)
                    // A syntax error aborts upstream's parser for this input;
                    // prior instructions and relocations remain loaded.
                    break
                }
            }
            // A previously unresolved use is shared with a later input's local
            // definition in SPIM. Resolve those uses before flushing this file's
            // local scope; do not make the definition global for later inputs.
            var localAliases = image.symbols.merging(constants) { _, constant in constant }
            let pendingGlobalNames = Set(fixups.compactMap { fix -> String? in
                guard let name = fix.expression.symbol, !name.contains(scopeSeparator) else { return nil }
                return name
            })
            for name in localNames where pendingGlobalNames.contains(name) {
                if let address = image.symbols[key(name)] { localAliases[name] = address }
            }
            var pending: [Fixup] = []
            for fix in fixups {
                if !fix.active() { continue }
                if let value = fix.expression.value(localAliases) { fix.apply(value) }
                else { pending.append(fix) }
            }
            fixups = pending
        }
        let table = image.symbols.merging(constants) { _, constant in constant }
        for fix in fixups where fix.active() {
            guard let value = fix.expression.value(table) else {
                let symbol = visibleName(fix.expression.symbol ?? "")
                if allowUndefinedSymbols {
                    image.unresolvedSymbols.append(symbol)
                    if let address = fix.instructionAddress {
                        image.unresolvedInstructions[address] = symbol
                    }
                    if let unresolved = fix.unresolved { unresolved() }
                    else { fix.apply(0) }
                    continue
                }
                throw AssemblyError(filename: fix.filename, line: fix.line, message: "Undefined symbol: \(symbol)")
            }
            fix.apply(value)
        }
        fixups.removeAll()
        image.diagnostics.append(contentsOf: jumpDiagnostics.sorted { $0.0 < $1.0 }.map(\.1))
        image.unresolvedSymbols = Array(Set(image.unresolvedSymbols)).sorted()
        // External consumers can look up unambiguous local labels without
        // exposing our per-input symbol keys in the Symbol Inspector.
        let scoped = Dictionary(grouping: image.symbols.filter { $0.key.contains(scopeSeparator) }) { visibleName($0.key) }
        for (label, addresses) in scoped {
            if addresses.count == 1, image.symbols[label] == nil { image.symbols[label] = addresses[0].value }
            for address in addresses { image.symbols.removeValue(forKey: address.key) }
        }
        image.dataEnd = highWater[Section.data.rawValue]
        image.kernelDataEnd = highWater[Section.kdata.rawValue]
        return image
    }

    func fail(_ message: String) -> AssemblyError { .init(filename: file, line: line, message: message, source: original) }
    func warn(_ message: String, column: Int? = nil, endsLine: Bool = false) {
        if recovering {
            var diagnostic = fail(message)
            diagnostic.diagnosticColumn = column; diagnostic.endsLine = endsLine
            image.diagnostics.append(diagnostic)
        }
    }

    func tokenize(_ text: String) throws -> [[String]] {
        var results: [[String]] = [], tokens: [String] = [], token = ""
        var quote: Character?
        var escaped = false
        func flush() { if !token.isEmpty { tokens.append(token); token = "" } }
        for ch in text {
            if quote != nil {
                token.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == quote { quote = nil; flush() }
            } else if ch == "#" {
                break
            } else if ch == "\"" || ch == "'" {
                flush(); quote = ch; token.append(ch)
            } else if ch == ";" {
                flush(); if !tokens.isEmpty { results.append(tokens) }; tokens = []
            } else if ch == "," {
                flush(); tokens.append(",")
            } else if ch.isWhitespace {
                flush()
            } else if ":()=+-*/".contains(ch) {
                if (ch == "+" || ch == "-"), token.last.map({ $0 == "e" || $0 == "E" }) == true,
                   (token.first?.isNumber == true || token.first == "."), !token.lowercased().hasPrefix("0x") {
                    token.append(ch)
                } else { flush(); tokens.append(String(ch)) }
            } else {
                token.append(ch)
            }
        }
        guard quote == nil else { throw fail("Unterminated string or character literal") }
        flush()
        if !tokens.isEmpty { results.append(tokens) }
        return results
    }

    func consume(_ tokens: [String]) throws {
        var p = 0
        while p + 1 < tokens.count, tokens[p + 1] == ":" {
            let label = key(tokens[p])
            if image.symbols[label] != nil && !gpSymbols.contains(label) {
                guard recovering else { throw fail("Duplicate label: \(tokens[p])") }
                warn("Label is defined for the second time", column: tokens[p].count)
                labels.removeAll()
            } else {
                if !gpSymbols.contains(label) { image.symbols[label] = location }
                labels.append(label)
            }
            p += 2
            if let colon = instructionSource.firstIndex(of: ":") {
                instructionSource = String(instructionSource[instructionSource.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard p < tokens.count else { return }
        let name = tokens[p].lowercased()
        var operands = Array(tokens.dropFirst(p + 1))
        if operands.first == "=" {
            operands.removeFirst()
            let e = try directiveExpression(operands)
            guard let value = resolve(e) else { throw fail("Constant must be defined before use") }
            constants[key(tokens[p])] = value
        } else if name.hasPrefix(".") { try directive(name, operands) }
        else { try encode(name, combine(operands)) }
        labels.removeAll()
    }

    func combine(_ operands: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < operands.count {
            var item = operands[i]
            if item == "," { i += 1; continue }
            if ["+", "-"].contains(item), i + 1 < operands.count {
                i += 1; item += operands[i]
            }
            if ["%hi", "%lo"].contains(item), i + 3 < operands.count, operands[i+1] == "(" {
                var j = i + 2
                while j < operands.count && operands[j] != ")" { j += 1 }
                if j < operands.count {
                    item += operands[(i+1)...j].joined(); i = j
                }
            }
            if i + 2 < operands.count, ["+", "-"].contains(operands[i+1]), !item.hasPrefix("$"),
               !item.hasPrefix("\""), !item.hasPrefix("'"),
               operands[i+2] != "(", operands[i+2] != ",", !operands[i+2].hasPrefix("$") {
                item += operands[i+1] + operands[i+2]; i += 2
            }
            if i + 3 < operands.count, operands[i+1] == "(", operands[i+3] == ")" {
                item += operands[(i+1)...(i+3)].joined(); i += 3
            } else if item == "(", i + 2 < operands.count, operands[i+2] == ")" {
                item += operands[(i+1)...(i+2)].joined(); i += 2
            }
            result.append(item); i += 1
        }
        return result
    }

    func expr(_ input: [String]) throws -> Expression { try expr(input.joined()) }
    func expr(_ input: String) throws -> Expression {
        if input.isEmpty { return .init(symbol: nil, addend: 0) }
        if input.hasPrefix("%hi(") || input.hasPrefix("%lo("), input.hasSuffix(")") {
            let part = String(input.dropFirst().prefix(2))
            return try expr(String(input.dropFirst(4).dropLast())).bits(part)
        }
        if let n = numeric(input) { return .init(symbol: nil, addend: n) }
        if input.hasPrefix("'"), input.hasSuffix("'") {
            guard let byte = try decoded(input).first else { throw fail("Empty character constant") }
            return .init(symbol: nil, addend: UInt32(byte))
        }
        if let delimiter = input.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) {
            let left = String(input[..<delimiter])
            let right = String(input[input.index(after: delimiter)...])
            if let offset = numeric(String(input[delimiter...])) { return try expr(left).adding(offset) }
            if input[delimiter] == "+", let offset = numeric(left) { return try expr(right).adding(offset) }
            throw fail("Invalid expression: \(input)")
        }
        guard !input.isEmpty, input.first?.isNumber != true else { throw fail("Invalid expression: \(input)") }
        return .init(symbol: key(input), addend: 0)
    }

    func directiveExpression(_ tokens: [String]) throws -> Expression {
        var pos = 0
        let e = try nextDirectiveExpression(tokens, &pos)
        guard pos == tokens.count else { throw fail("Unexpected token: \(tokens[pos])") }
        return e
    }

    func nextDirectiveExpression(_ tokens: [String], _ pos: inout Int) throws -> Expression {
        func atom(_ p: inout Int) throws -> Formula {
            guard p < tokens.count else { throw fail("Expected expression") }
            let token = tokens[p]; p += 1
            switch token {
            case "(":
                let inside = try binary(&p, precedence: 0)
                guard p < tokens.count, tokens[p] == ")" else { throw fail("Expected a closing parenthesis") }
                p += 1
                return inside
            case "-": return .binary("-", .literal(0), try atom(&p))
            case "+": return try atom(&p)
            case ",", ":", ")", "*", "/": throw fail("Expected expression")
            default:
                if let n = numeric(token) { return .literal(n) }
                if token.hasPrefix("'"), token.hasSuffix("'"), let ch = try decoded(token).first { return .literal(UInt32(ch)) }
                return .symbol(key(token))
            }
        }

        func binary(_ p: inout Int, precedence: Int) throws -> Formula {
            var value = try atom(&p)
            while p < tokens.count {
                let op = tokens[p]
                let level: Int
                switch op { case "+", "-": level = 1; case "*", "/": level = 2; default: level = -1 }
                if level < precedence { break }
                p += 1
                let right = try binary(&p, precedence: level + 1)
                if op == "/", right.value(image.symbols.merging(constants) { _, c in c }) == 0 {
                    throw fail("Division by zero in expression")
                }
                value = .binary(op, value, right)
            }
            return value
        }

        let formula = try binary(&pos, precedence: 0)
        return .init(symbol: formula.referencedSymbol, addend: 0, formula: formula)
    }

    func numeric(_ token: String) -> UInt32? {
        var s = token[...]
        var negative = false
        if s.first == "-" || s.first == "+" { negative = s.first == "-"; s = s.dropFirst() }
        let lower = s.lowercased()
        let radix: Int
        if lower.hasPrefix("0x") { s = s.dropFirst(2); radix = 16 }
        else if lower.hasPrefix("0b") { s = s.dropFirst(2); radix = 2 }
        else if lower.hasPrefix("0") && lower.count > 1 && lower.allSatisfy({ "01234567".contains($0) }) {
            radix = 8
        } else { radix = 10 }
        guard let n = UInt64(s, radix: radix) else { return nil }
        let result = UInt32(truncatingIfNeeded: n)
        return negative ? 0 &- result : result
    }

    func decoded(_ token: String) throws -> [UInt8] {
        guard token.count >= 2, let quote = token.first, token.last == quote, quote == "\"" || quote == "'" else {
            throw fail("Expected string literal")
        }
        let content = token.dropFirst().dropLast()
        let chars: [UInt8] = literalEncoding == .utf8 ? Array(content.utf8)
            : content.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
        var bytes: [UInt8] = [], i = 0
        while i < chars.count {
            let c = chars[i]; i += 1
            if c != 92 || i == chars.count { bytes.append(c); continue }
            let escape = chars[i]; i += 1
            switch escape {
            case 110: bytes.append(10)
            case 116: bytes.append(9)
            case 114: bytes.append(13)
            case 98: bytes.append(8)
            case 102: bytes.append(12)
            case 118: bytes.append(11)
            case 97: bytes.append(7)
            case 48...55:
                var n = Int(escape - 48), count = 1
                while i < chars.count, count < 3, (48...55).contains(chars[i]) {
                    n = n * 8 + Int(chars[i] - 48); i += 1; count += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: n))
            default: bytes.append(escape)
            }
        }
        return bytes
    }

    func resolve(_ e: Expression, adjust: Bool = false) -> UInt32? {
        e.value(image.symbols.merging(constants) { _, c in c }, adjust: adjust)
    }
    func bind(_ e: Expression, active: @escaping () -> Bool = { true }, _ apply: @escaping (UInt32) -> Void) {
        if let value = resolve(e) { apply(value) }
        else { fixups.append(.init(expression: e, filename: file, line: line, active: active, apply: apply)) }
    }

    func stamp(_ address: UInt32, size: Int) -> UInt64 {
        serial &+= 1
        for i in 0..<size { byteStamps[address &+ UInt32(i)] = serial }
        return serial
    }

    func isStamped(_ address: UInt32, size: Int, by mark: UInt64) -> Bool {
        (0..<size).contains { byteStamps[address &+ UInt32($0)] == mark }
    }

    func write(_ bytes: [UInt8]) {
        let a = location
        _ = stamp(a, size: bytes.count)
        for (i, byte) in bytes.enumerated() { image.data[a &+ UInt32(i)] = byte }
        location = a &+ UInt32(bytes.count)
    }
    func store(_ value: UInt64, size: Int, at address: UInt32, mark: UInt64? = nil) {
        let mark = mark ?? stamp(address, size: size)
        for i in 0..<size {
            let at = address &+ UInt32(i)
            guard byteStamps[at] == mark else { continue }
            let shift = (options.littleEndian ? i : size - 1 - i) * 8
            image.data[at] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }
    func align(_ exponent: UInt32) throws {
        guard exponent < 31 else { throw fail("Alignment is out of range") }
        let mask = (UInt32(1) << exponent) &- 1
        let previous = location
        location = (location &+ mask) & ~mask
        for label in labels where image.symbols[label] == previous { image.symbols[label] = location }
    }

    func directive(_ name: String, _ input: [String]) throws {
        let a = combine(input)
        switch name {
        case ".text", ".data", ".ktext", ".kdata", ".rdata", ".sdata":
            switch name {
            case ".text": section = .text
            case ".ktext": section = .ktext
            case ".kdata": section = .kdata
            default: section = .data
            }
            if !section.isText { autoAlign = true; activeDataSection = section }
            if !a.isEmpty {
                let e = try directiveExpression(input)
                guard let addr = resolve(e) else { throw fail("Section address must be absolute") }
                location = addr
            }
        case ".align":
            guard let n = try resolve(directiveExpression(input)) else { throw fail("Alignment must be absolute") }
            if n == 0 { autoAlign = false }
            else { try align(n) }
        case ".space":
            guard let n = try resolve(directiveExpression(input)), n <= 256 * 1024 * 1024 else { throw fail("Invalid .space size") }
            try checkBounds(location, in: section, bytes: UInt64(n))
            location = location &+ n
        case ".ascii", ".asciiz":
            let priorSection = section
            if section.isText {
                guard recovering else { throw fail("Cannot put data in the text segment") }
                warn("Can't put data in text segment", endsLine: true)
                section = activeDataSection
            }
            defer { section = priorSection }
            var index = 0
            while index < a.count {
                let data = try decoded(a[index])
                index += 1
                var count = 1
                if index + 1 < a.count, a[index] == ":" {
                    guard let n = numeric(a[index+1]), n <= 1_000_000 else { throw fail("Invalid repeat count") }
                    count = Int(n); index += 2
                }
                if count != 0, data.count > 64 * 1024 * 1024 / count {
                    throw fail("String data exceeds 64 MiB")
                }
                try checkBounds(location, in: section, bytes: UInt64(count) * UInt64(data.count + (name == ".asciiz" ? 1 : 0)))
                for _ in 0..<count {
                    write(data)
                    if name == ".asciiz" { write([0]) }
                }
            }
        case ".word", ".half", ".byte", ".float", ".double":
            let size: Int
            switch name { case ".byte": size = 1; case ".half": size = 2; case ".double": size = 8; default: size = 4 }
            let priorSection = section
            if section.isText && name != ".word" {
                guard recovering else { throw fail("Cannot put data in the text segment") }
                warn("Can't put data in text segment", endsLine: true)
                section = activeDataSection
            }
            defer { section = priorSection }
            if autoAlign, !section.isText { try align(UInt32(size.trailingZeroBitCount)) }
            let float = name == ".float" || name == ".double"
            let values = float ? a : input
            var index = 0
            while index < values.count {
                if values[index] == "," { index += 1; continue }
                let token = values[index]
                let e: Expression?
                if float { index += 1; e = nil }
                else { e = try nextDirectiveExpression(values, &index) }
                var repeatCount = 1
                if index + 1 < values.count && values[index] == ":" {
                    guard let n = numeric(values[index+1]), n <= 4_000_000 else { throw fail("Invalid repeat count") }
                    repeatCount = Int(n)
                    index += 2
                }
                try checkBounds(location, in: section, bytes: UInt64(size) * UInt64(repeatCount))
                if let e {
                    for _ in 0..<repeatCount {
                        if size == 4 && section.isText { emit(0, immediate: e) { _, v in v } }
                        else {
                            let address = location
                            location = location &+ UInt32(size)
                            let mark = stamp(address, size: size)
                            bind(e, active: { [unowned self] in self.isStamped(address, size: size, by: mark) }) {
                                [unowned self] in self.store(UInt64($0), size: size, at: address, mark: mark)
                            }
                        }
                    }
                } else {
                    guard let number = Double(token) else { throw fail("Invalid floating-point constant: \(token)") }
                    let bits = name == ".float" ? UInt64(Float(number).bitPattern) : number.bitPattern
                    for _ in 0..<repeatCount {
                        store(bits, size: size, at: location)
                        location = location &+ UInt32(size)
                    }
                }
            }
        case ".extern", ".lcomm", ".comm":
            guard let symbolName = input.first,
                  let n = try resolve(directiveExpression(Array(input.dropFirst().filter { $0 != "," }))),
                  n <= 256 * 1024 * 1024 else { throw fail("Invalid allocation") }
            let nameKey = key(symbolName)
            if name != ".comm", image.symbols[nameKey] == nil, n > 0, n <= 8,
               gpAddress &+ n < 0x10010000, !options.bareMachine {
                image.symbols[nameKey] = gpAddress
                gpSymbols.insert(nameKey)
                gpAddress = gpAddress &+ n
            } else if name != ".extern" {
                let prior = section
                section = .data
                if name == ".comm" { try align(2) }
                if image.symbols[nameKey] == nil { image.symbols[nameKey] = location }
                try checkBounds(location, in: section, bytes: UInt64(n))
                location = location &+ n
                section = prior
            }
        case ".lab":
            guard let label = a.first, a.count == 1 else { throw fail("Invalid label") }
            image.symbols[key(label)] = location
        case ".set":
            if a.first == "noat" { noAT = true }
            else if a.first == "at" { noAT = false }
        case ".err": throw fail("Encountered .err directive")
        case ".repeat", ".struct": warn("Warning: \(name.dropFirst()) directive ignored", endsLine: true)
        case ".globl", ".global", ".alias", ".noalias", ".asm0", ".bgnb", ".endb",
             ".end", ".endr", ".ent", ".file", ".fmask", ".frame", ".livereg", ".loc", ".mask",
             ".option", ".verstamp", ".vreg":
            break
        default: throw fail("Unknown directive: \(name)")
        }
    }

    func emit(_ base: UInt32, executionWord: UInt32? = nil, immediate: Expression? = nil, encode: @escaping (UInt32, UInt32) -> UInt32 = { $0 | ($1 & 0xffff) }) {
        let address = location
        let inText = section.isText
        let ins = Instruction(word: base, source: sourceReturned ? "" : instructionSource, line: line, filename: file)
        sourceReturned = true
        location = location &+ 4
        let mark: UInt64
        if inText {
            serial &+= 1
            mark = serial
            wordStamps[address] = mark
        } else { mark = stamp(address, size: 4) }
        let active: () -> Bool = { [unowned self] in
            inText ? self.wordStamps[address] == mark : self.isStamped(address, size: 4, by: mark)
        }
        let put: (UInt32) -> Void = { [unowned self] word in
            if inText { self.image.instructions[address] = Instruction(word: word, source: ins.source, line: ins.line, filename: ins.filename, executionWord: executionWord) }
            else { self.store(UInt64(word), size: 4, at: address, mark: mark) }
        }
        if let immediate {
            if let value = resolve(immediate) { put(encode(base, value)) }
            else {
                fixups.append(.init(expression: immediate, filename: file, line: line, active: active,
                                    apply: { put(encode(base, $0)) }, instructionAddress: inText ? address : nil,
                                    unresolved: { put(base) }))
            }
        }
        else { put(base) }
    }
}

private extension AssemblyState {
    func register(_ s: String, checkReserved: Bool = true) throws -> UInt32 {
        guard s.first == "$" else { throw fail("Expected register: \(s)") }
        let raw = String(s.dropFirst()).lowercased()
        let aliases = ["zero":0,"at":1,"v0":2,"v1":3,"a0":4,"a1":5,"a2":6,"a3":7,
                       "t0":8,"t1":9,"t2":10,"t3":11,"t4":12,"t5":13,"t6":14,"t7":15,
                       "s0":16,"s1":17,"s2":18,"s3":19,"s4":20,"s5":21,"s6":22,"s7":23,
                       "t8":24,"t9":25,"k0":26,"k1":27,"gp":28,"sp":29,"fp":30,"s8":30,"ra":31]
        let n = aliases[raw] ?? Int(raw) ?? (raw.hasPrefix("f") ? Int(raw.dropFirst()) : nil)
        guard let n else { throw fail("Invalid register: \(s)") }
        if !(0...31).contains(n) {
            guard recovering else { throw fail("Invalid register: \(s)") }
            warn(raw.hasPrefix("f") ? "FP register number out of range" : "Register number out of range")
        }
        if checkReserved && n == 1 && !raw.hasPrefix("f") && !options.bareMachine && !noAT {
            let range = instructionSource.range(of: s)
            let column = range.map { instructionSource.distance(from: instructionSource.startIndex, to: $0.lowerBound) }
            warn("Register 1 is reserved for assembler", column: column)
            if recovering, let range {
                let suffix = instructionSource[range.upperBound...].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                if !suffix.trimmingCharacters(in: .whitespaces).isEmpty {
                    var error = fail("syntax error"); error.lineOffset = 1; error.omitSource = true
                    throw error
                }
            }
        }
        return UInt32(truncatingIfNeeded: n) & 31
    }
    func cc(_ s: String) throws -> UInt32 {
        let raw = s.hasPrefix("$fcc") ? String(s.dropFirst(4)) : s.hasPrefix("$") ? String(s.dropFirst()) : s
        guard let i = UInt32(raw), i < 8 else { throw fail("Invalid condition-code register: \(s)") }
        return i
    }
    func address(_ s: String) throws -> (UInt32, Expression) {
        if s.hasSuffix(")"), let start = s.lastIndex(of: "("), s[s.index(after: start)...].hasPrefix("$") {
            let base = try register(String(s[s.index(after: start)..<s.index(before: s.endIndex)]))
            return (base, try expr(String(s[..<start])))
        }
        return (0, try expr(s))
    }
    func r(_ base: UInt32, _ rd: UInt32 = 0, _ rs: UInt32 = 0, _ rt: UInt32 = 0, _ sh: UInt32 = 0) {
        emit(base | ((rs & 31) << 21) | ((rt & 31) << 16) | ((rd & 31) << 11) | ((sh & 31) << 6))
    }
    func i(_ base: UInt32, _ rt: UInt32, _ rs: UInt32, _ expression: Expression) {
        emit(base | ((rs & 31) << 21) | ((rt & 31) << 16), immediate: expression)
    }
    func imm(_ v: UInt32) -> Expression { .init(symbol: nil, addend: v) }
    func branch(_ base: UInt32, _ rs: UInt32, _ rt: UInt32, _ target: Expression, relativeAlready: Bool = false) {
        let pc = location
        let delayAdjust: UInt32 = options.delayedBranches ? 4 : 0
        emit(base | (rs << 21) | (rt << 16), immediate: target) { word, v in
            let displacement = (relativeAlready ? v : v &- pc) &- delayAdjust
            return word | (UInt32(bitPattern: Int32(bitPattern: displacement) >> 2) & 0xffff)
        }
    }
    func skip(_ base: UInt32, _ rs: UInt32, _ rt: UInt32, _ words: UInt32) {
        branch(base, rs, rt, imm(words &* 4), relativeAlready: true)
    }
    func full(_ rt: UInt32, _ e: Expression) {
        if let symbol = e.symbol, gpSymbols.contains(symbol), let v = resolve(e) {
            let offset = v &- 0x10008000
            if Int32(bitPattern: offset) >= Int32(Int16.min), Int32(bitPattern: offset) <= Int32(Int16.max) {
                i(0x24000000, rt, 28, imm(offset)); return
            }
        }
        if let v = resolve(e) {
            if v <= 0xffff { i(0x34000000, rt, 0, imm(v)); return }
            if v & 0xffff == 0 { i(0x3c000000, rt, 0, imm(v >> 16)); return }
        }
        i(0x3c000000, 1, 0, e.bits("hi")); i(0x34000000, rt, 1, e.bits("lo"))
    }
    func memory(_ op: UInt32, _ rt: UInt32, _ rs: UInt32, _ e: Expression) {
        if let sym = e.symbol, gpSymbols.contains(sym), rs == 0, let v = resolve(e) {
            let offset = v &- 0x10008000
            if Int32(bitPattern: offset) >= Int32(Int16.min), Int32(bitPattern: offset) <= Int32(Int16.max) {
                i(op, rt, 28, imm(offset)); return
            }
        }
        if let v = resolve(e) {
            let signed = Int32(bitPattern: v)
            if Int32(Int16.min)...Int32(Int16.max) ~= signed || e.part != nil {
                i(op, rt, rs, e); return
            }
        }
        if options.bareMachine || e.part != nil { i(op, rt, rs, e); return }
        emit(0x3c010000, immediate: e) { b, v in b | ((v &+ 0x8000) >> 16) }
        if rs != 0 { r(0x21, 1, 1, rs) }
        i(op, rt, 1, e.bits("lo"))
    }
    func require(_ a: [String], _ count: Int, _ name: String) throws {
        if a.count != count { throw fail("\(name) expects \(count) operand\(count == 1 ? "" : "s")") }
    }

    func encode(_ name: String, _ args: [String]) throws {
        var a = args
        if a.count == 2, ["add","addu","and","nor","or","xor","slt","sltu","sub","subu",
                          "addi","addiu","andi","ori","xori","slti","sltiu","sllv","srlv","srav"].contains(name) {
            a.insert(a[0], at: 1)
        }
        func reg(_ n: Int) throws -> UInt32 { try register(a[n]) }
        func e(_ n: Int) throws -> Expression { try expr(a[n]) }
        func need(_ n: Int) throws { try require(a, n, name) }
        let specs = spimOperationSpecs[name]
        if specs == nil && !spimPseudoNames.contains(name) { throw fail("syntax error") }
        if specs?.2 == true {
            guard recovering else { throw fail("MIPS32 Release 2 instruction is not implemented by SPIM: \(name)") }
            let column = a.last.flatMap { instructionSource.range(of: $0, options: .backwards) }.map { instructionSource.distance(from: instructionSource.startIndex, to: $0.lowerBound) }
            warn("Warning: MIPS32 Rev 2 instruction is not implemented. Instruction ignored.", column: column)
            return
        }
        let pseudo = specs == nil || (["div","divu"].contains(name) && a.count == 3)
        if pseudo {
            guard !options.bareMachine && options.acceptPseudoInstructions else {
                throw fail("Pseudo-instructions are turned off: \(name)")
            }
            try encodePseudo(name, a)
            return
        }
        guard let (layout, base, _) = specs else { throw fail("Unknown instruction: \(name)") }
        switch layout {
        case "NOARG":
            if ["break","sync"].contains(name), a.count == 1 {
                let field = try e(0)
                guard let v = resolve(field), v < 32 else { throw fail("Invalid \(name) code") }
                if name == "break" && v == 1 {
                    guard recovering else { throw fail("Breakpoint 1 is reserved for debugger") }
                    warn("Breakpoint 1 is reserved for debugger")
                }
                // SPIM stores the break code as an operand but omits it from the displayed word.
                if name == "break", v != 0 { emit(base, executionWord: base | v << 11) }
                else { r(base, v) }
            } else { try need(0); emit(base) }
        case "R1s":
            if name == "jr" && a.count == 2 { r(base, 0, try reg(1)) }
            else { try need(1); r(base, 0, try reg(0)) }
        case "R1d":
            try need(1); r(base, try reg(0))
        case "R2st":
            try need(2); r(base, 0, try reg(0), try reg(1))
        case "R2ds":
            if a.count == 1 { r(base, 31, try reg(0)) }
            else { try need(2); r(base, try reg(0), try reg(1)) }
        case "R2td", "FP_R2ts":
            try need(2); r(base, try register(a[1], checkReserved: false), 0, try reg(0))
        case "R2sh":
            if name == "ssnop" { try need(0); emit(base); return }
            try need(3)
            let dest = try reg(0), source = try reg(1)
            if a[2].hasPrefix("$"), !options.bareMachine {
                r(base | 4, dest, try reg(2), source)
            } else {
                guard let shift = try resolve(e(2)) else { throw fail("Invalid shift amount") }
                if shift >= 32 {
                    guard recovering else { throw fail("Invalid shift amount") }
                    warn("Shift distance can only be in the range 0..31")
                }
                r(base, dest, 0, source, shift)
            }
        case "R3sh":
            try need(3)
            if a[2].hasPrefix("$") { r(base, try reg(0), try reg(2), try reg(1)) }
            else {
                guard let sh = try resolve(e(2)), sh < 32 else { throw fail("Invalid shift amount") }
                r(base & ~4, try reg(0), 0, try reg(1), sh)
            }
        case "R3":
            if ["clz", "clo"].contains(name) {
                try need(2); r(base, try reg(0), try reg(1), try reg(0))
            } else {
                let immBase: [String: UInt32] = ["add":0x20000000, "addu":0x24000000, "and":0x30000000,
                    "or":0x34000000,"xor":0x38000000,"slt":0x28000000,"sltu":0x2c000000]
                if let op = immBase[name], a.count == 2, !a[1].hasPrefix("$") {
                    let target = try reg(0)
                    compute(op, target, target, try e(1), original: base)
                    return
                }
                try need(3)
                if a[2].hasPrefix("$") { r(base, try reg(0), try reg(1), try reg(2)); return }
                // The original grammar accepts binary operations with a hardware
                // immediate analogue even when pseudo-instructions are disabled.
                if let op = immBase[name] {
                    compute(op, try reg(0), try reg(1), try e(2), original: base)
                    return
                }
                guard !options.bareMachine else { throw fail("Immediate form not allowed in bare machine") }
                if name == "sub" || name == "subu", let value = try resolve(e(2)) {
                    compute(name == "sub" ? 0x20000000 : 0x24000000, try reg(0), try reg(1), imm(0 &- value), original: name == "sub" ? 0x20 : 0x21)
                } else {
                    let value = try e(2)
                    let zero = name != "mul" && resolve(value) == 0
                    if !zero { full(1, value) }
                    r(base, try reg(0), try reg(1), zero ? 0 : 1)
                }
            }
        case "MOVC":
            if a.count == 2 { r(base, try reg(0), try reg(1)); return }
            try need(3); r(base, try reg(0), try reg(1), try cc(a[2]) << 2)
        case "I1s":
            try need(2); i(base, 0, try reg(0), try e(1))
        case "I1t":
            if ["di","ei"].contains(name), a.isEmpty { emit(base) }
            else if ["di","ei"].contains(name) { try need(1); i(base, try reg(0), 0, imm(0)) }
            else { try need(2); compute(base, try reg(0), 0, try e(1), original: nil) }
        case "I2":
            if name == "cache" || name == "pref" {
                try need(2)
                guard let op = try resolve(e(0)), op < 32 else { throw fail("Invalid cache operation") }
                let addr = try address(a[1]); memory(base, op, addr.0, addr.1)
            } else {
                try need(3)
                let real: [String:UInt32] = ["addi":0x20,"addiu":0x21,"andi":0x24,"ori":0x25,"xori":0x26,
                                             "slti":0x2a,"sltiu":0x2b,"subi":0x22,"subiu":0x23]
                compute(base, try reg(0), try reg(1), try e(2), original: real[name])
            }
        case "I2a", "FP_I2a":
            try need(2); let addr = try address(a[1]); memory(base, try reg(0), addr.0, addr.1)
        case "B1":
            try need(2)
            let target = try e(1)
            branch(base, try reg(0), 0, target, relativeAlready: target.symbol == nil)
        case "B2":
            try need(3)
            let target = try e(2)
            let rs = try reg(0)
            if a[1].hasPrefix("$") {
                branch(base, rs, try reg(1), target, relativeAlready: target.symbol == nil)
            } else {
                guard !options.bareMachine else { throw fail("Expected register operand") }
                let value = try e(1)
                let zero = resolve(value) == 0
                if !zero { full(1, value) }
                branch(base, zero ? 0 : 1, rs, target, relativeAlready: target.symbol == nil)
            }
        case "BC":
            guard a.count == 1 || a.count == 2 else { throw fail("Invalid coprocessor branch") }
            let rt = a.count == 2 ? try cc(a[0]) << 2 : 0
            let target = try e(a.count - 1)
            branch(base, 0, rt, target, relativeAlready: target.symbol == nil)
        case "J":
            if name == "cop2" {
                try need(1); emit(base, immediate: try e(0)) { $0 | ($1 & 0x1ffffff) }
            } else if a.first?.hasPrefix("$") == true {
                if name == "j" { try need(1); r(8, 0, try reg(0)) }
                else if a.count == 2 { r(9, try reg(0), try reg(1)) }
                else { try need(1); r(9, 31, try reg(0)) }
            } else {
                try need(1)
                let address = location
                let order = serial
                emit(base, immediate: try e(0)) { [unowned self] word, target in
                    if self.recovering, target & 0xf0000000 != address & 0xf0000000 {
                        self.jumpDiagnostics.append((order, self.fail(String(format: "Target of jump differs in high-order 4 bits from instruction pc 0x%x", address))))
                    }
                    return word | ((target >> 2) & 0x03ff_ffff)
                }
            }
        case "FP_R2ds":
            try need(2); emit(base | (try reg(0) << 6) | (try reg(1) << 11))
        case "FP_R3":
            try need(3); emit(base | (try reg(0) << 6) | (try reg(1) << 11) | (try reg(2) << 16))
        case "FP_CMP":
            guard a.count == 2 || a.count == 3 else { throw fail("Invalid floating-point compare") }
            let condition = a.count == 3 ? try cc(a[0]) << 8 : 0
            emit(base | condition | (try reg(a.count-2) << 11) | (try reg(a.count-1) << 16))
        case "FP_MOVC":
            guard a.count == 2 || a.count == 3 else { throw fail("Invalid floating-point conditional move") }
            let cond: UInt32
            if a.count == 2 { cond = 0 }
            else if name.hasPrefix("movn") || name.hasPrefix("movz") { cond = try reg(2) << 16 }
            else { cond = try cc(a[2]) << 18 }
            let displayWord = base | (try reg(0) << 6) | (try reg(1) << 11)
            // SPIM omits the GPR operand of floating-point movn/movz when encoding for display.
            if (name.hasPrefix("movn") || name.hasPrefix("movz")) && cond != 0 {
                emit(displayWord, executionWord: displayWord | cond)
            } else {
                emit(displayWord | cond)
            }
        default: throw fail("Instruction form is not implemented by SPIM: \(name)")
        }
    }

    func compute(_ base: UInt32, _ rt: UInt32, _ rs: UInt32, _ e: Expression, original: UInt32?) {
        let op = base >> 26
        let signed = [8,9,10,11].contains(op)
        if options.bareMachine, e.part == nil, let value = resolve(e) {
            let number = Int64(Int32(bitPattern: value))
            let minimum: Int64 = signed ? -32768 : 0
            let maximum: Int64 = signed ? 32767 : 65535
            if number < minimum || number > maximum {
                warn("immediate value (\(number)) out of range (\(minimum) .. \(maximum))")
            }
        }
        if let v = resolve(e), e.part != nil || (signed ? (Int32(Int16.min)...Int32(Int16.max) ~= Int32(bitPattern:v)) : v <= 0xffff) {
            i(base, rt, rs, e)
        } else if options.bareMachine || e.part != nil {
            i(base, rt, rs, e)
        } else if rs == 0 && [8,9,13,15].contains(op) {
            full(rt, e)
        } else if let original {
            full(1, e); r(original, rt, rs, 1)
        } else {
            i(base, rt, rs, e)
        }
    }

    func encodePseudo(_ name: String, _ a: [String]) throws {
        func reg(_ n: Int) throws -> UInt32 { try register(a[n]) }
        func e(_ n: Int) throws -> Expression { try expr(a[n]) }
        func need(_ n: Int) throws { try require(a, n, name) }
        switch name {
        case "nop": try need(0); emit(0)
        case "move": try need(2); r(0x21, try reg(0), 0, try reg(1))
        case "not": try need(2); r(0x27, try reg(0), try reg(1))
        case "neg", "negu": try need(2); r(name == "neg" ? 0x22 : 0x23, try reg(0), 0, try reg(1))
        case "abs":
            try need(2)
            let rd = try reg(0), rs = try reg(1)
            if rd != rs { r(0x21, rd, 0, rs) }
            skip(0x04010000, rs, 0, 3); emit(0); r(0x22, rd, 0, rs)
        case "li":
            try need(2); full(try reg(0), try e(1))
        case "la":
            try need(2)
            let addr = try address(a[1])
            if addr.0 == 0 { full(try reg(0), addr.1) }
            else { compute(0x20000000, try reg(0), addr.0, addr.1, original: 0x20) }
        case "li.s", "li.d":
            try need(2)
            let fr = try reg(0)
            guard let value = Double(a[1]) else { throw fail("Invalid floating-point constant") }
            if name == "li.s" {
                full(1, imm(Float(value).bitPattern)); r(0x44800000, fr, 0, 1)
            } else {
                let lo = UInt32(truncatingIfNeeded: value.bitPattern), hi = UInt32(value.bitPattern >> 32)
                full(1, imm(options.littleEndian ? lo : hi)); r(0x44800000, fr, 0, 1)
                full(1, imm(options.littleEndian ? hi : lo)); r(0x44800000, fr+1, 0, 1)
            }
        case "l.s", "l.d", "s.s", "s.d", "ld", "sd", "ulw", "usw", "ulh", "ulhu", "ush":
            try need(2)
            let t = try reg(0), ad = try address(a[1])
            func m(_ op: UInt32, _ rt: UInt32, _ offset: UInt32 = 0) { memory(op, rt, ad.0, ad.1.adding(offset)) }
            switch name {
            case "l.s": m(0xc4000000,t)
            case "l.d": m(0xd4000000,t)
            case "s.s": m(0xe4000000,t)
            case "s.d": m(0xf4000000,t)
            case "ld": m(0x8c000000,t); m(0x8c000000,t+1,4)
            case "sd": m(0xac000000,t); m(0xac000000,t+1,4)
            case "ulw": m(0x88000000,t,options.littleEndian ? 3 : 0); m(0x98000000,t,options.littleEndian ? 0 : 3)
            case "usw": m(0xa8000000,t,options.littleEndian ? 3 : 0); m(0xb8000000,t,options.littleEndian ? 0 : 3)
            case "ulh","ulhu":
                m(name == "ulh" ? 0x80000000 : 0x90000000,t, options.littleEndian ? 1 : 0)
                m(0x90000000,1,options.littleEndian ? 0 : 1); r(0,t,0,t,8); r(0x25,t,t,1)
            default:
                m(0xa0000000, t)
                r(0,1,0,t,24); r(2,t,0,t,8); r(0x25,t,t,1)
                m(0xa0000000,t,1)
                r(0,1,0,t,8); r(2,t,0,t,24); r(0x25,t,t,1)
            }
        case "mfc1.d", "mtc1.d":
            try need(2)
            let rt = try reg(0), fr = try reg(1), op: UInt32 = name == "mfc1.d" ? 0x44000000 : 0x44800000
            r(op, fr, 0, rt); r(op, fr+1, 0, rt+1)
        case "b","bal","beqz","bnez":
            if name == "b" || name == "bal" {
                try need(1); let target = try e(0)
                branch(name == "b" ? 0x04010000 : 0x04110000, 0, 0, target, relativeAlready: target.symbol == nil)
            } else {
                try need(2); let target = try e(1)
                branch(name == "beqz" ? 0x10000000 : 0x14000000, try reg(0), 0, target, relativeAlready: target.symbol == nil)
            }
        case "bge","bgeu","bgt","bgtu","ble","bleu","blt","bltu":
            try need(3)
            let lhs = try reg(0), unsigned = name.hasSuffix("u"), root = unsigned ? String(name.dropLast()) : name
            let target = try e(2)
            let slt: UInt32 = unsigned ? 0x2b : 0x2a
            let slti: UInt32 = unsigned ? 0x2c000000 : 0x28000000
            var notEqual = root == "blt" || root == "bgt"
            if a[1].hasPrefix("$") {
                let rhs = try reg(1)
                let reverse = root == "ble" || root == "bgt"
                r(slt, 1, reverse ? rhs : lhs, reverse ? lhs : rhs)
            } else {
                let value = try e(1)
                if root == "blt" || root == "bge" {
                    compute(slti, 1, lhs, value, original: slt)
                } else {
                    notEqual = root == "ble"
                    if !unsigned {
                        compute(slti, 1, lhs, value.adding(1), original: slt)
                    } else {
                        full(1, value)
                        if root == "bgt" { skip(0x10000000, 1, lhs, 3) }
                        else { branch(0x10000000, 1, lhs, target, relativeAlready: target.symbol == nil) }
                        r(slt, 1, lhs, 1)
                    }
                }
            }
            branch(notEqual ? 0x14000000 : 0x10000000, 1, 0, target, relativeAlready: target.symbol == nil)
        case "seq","sne","sge","sgeu","sgt","sgtu","sle","sleu":
            try need(3)
            let dest = try reg(0), lhs = try reg(1), unsigned = name.hasSuffix("u")
            let root = unsigned ? String(name.dropLast()) : name
            let rhs: UInt32
            if a[2].hasPrefix("$") { rhs = try reg(2) }
            else {
                let value = try e(2)
                if resolve(value) == 0 { rhs = 0 } else { full(1, value); rhs = 1 }
            }
            if root == "seq" || root == "sne" {
                skip(0x10000000,rhs,lhs,3)
                i(0x34000000,dest,0,imm(root == "seq" ? 0 : 1))
                skip(0x10000000,0,0,3); emit(0)
                i(0x34000000,dest,0,imm(root == "seq" ? 1 : 0))
            } else if root == "sgt" { r(unsigned ? 0x2b : 0x2a,dest,rhs,lhs) }
            else {
                skip(0x14000000,rhs,lhs,3)
                i(0x34000000,dest,0,imm(1))
                skip(0x10000000,0,0,3); emit(0)
                r(unsigned ? 0x2b : 0x2a,dest,root == "sle" ? lhs : rhs,root == "sle" ? rhs : lhs)
            }
        case "div","divu","rem","remu","mulo","mulou":
            try need(3)
            let rd = try reg(0), rs = try reg(1), rt: UInt32, constant = !a[2].hasPrefix("$")
            if constant {
                let value = try e(2)
                if resolve(value) == 0 {
                    if name.hasPrefix("mul") { full(rd, value); return }
                    guard recovering else { throw fail("Divide by zero") }
                    warn("Divide by zero", endsLine: true)
                    return
                }
                full(1, value); rt = 1
            } else { rt = try reg(2) }
            if name.hasPrefix("mul") {
                r(name == "mulo" ? 0x18 : 0x19,0,rs,rt)
                if rd != 0 {
                    r(0x10,1)
                    if name == "mulo" { r(0x12,rd); r(3,rd,0,rd,31) }
                    skip(0x10000000,1,name == "mulo" ? rd : 0,3); emit(0); emit(13)
                    r(0x12,rd)
                }
            } else {
                if rd != 0 && !constant { skip(0x14000000,rt,0,3); emit(0); emit(13) }
                r(name.hasSuffix("u") ? 0x1b : 0x1a,0,rs,rt)
                if rd != 0 { r(name.hasPrefix("rem") ? 0x10 : 0x12,rd) }
            }
        case "rol","ror":
            try need(3)
            let rd = try reg(0), rs = try reg(1)
            if a[2].hasPrefix("$") {
                let rt = try reg(2)
                r(0x23,1,0,rt); r(name == "rol" ? 6 : 4,1,1,rs); r(name == "rol" ? 4 : 6,rd,rt,rs)
            } else {
                guard let shift = try resolve(e(2)), shift < 32 else { throw fail("Invalid rotation amount") }
                r(name == "rol" ? 2 : 0,1,0,rs,0 &- shift); r(name == "rol" ? 0 : 2,rd,0,rs,shift)
            }
            r(0x25,rd,rd,1)
        default: throw fail("Unknown instruction: \(name)")
        }
    }
}
