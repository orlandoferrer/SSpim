#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SpimCore

@MainActor final class Debugger: ObservableObject {
    @Published private(set) var machine: Machine?
    @Published private(set) var generation = 0
    @Published private(set) var running = false
    @Published private(set) var files: [ProgramFile] = []
    @Published var options = SpimOptions()
    @Published var useDefaultHandler = true
    @Published var handlerPath = ""
    @Published var quiet = false
    @Published var acceptPseudoInstructions = true
    @Published var recent: [String] = []
    @Published var recentLimit = 4
    @Published var registerRadix = Radix.hex
    @Published var dataRadix = Radix.hex
    @Published var panels = Set(DebugPanel.allCases)
    @Published var userText = true
    @Published var kernelText = true
    @Published var comments = true
    @Published var machineWords = true
    @Published var userData = true
    @Published var userStack = true
    @Published var kernelData = true
    @Published var textSize = 13.0
    @Published var colorChangedRegisters = true
    @Published var changedRegisterColor = Color.red
    @Published var registerSize = 13.0
    @Published var registerFamily = ""
    @Published var registerColor = Color.primary
    @Published var registerBackground = Color(nsColor: .textBackgroundColor)
    @Published var textFamily = ""
    @Published var consoleFamily = ""
    @Published var consoleSize = 13.0
    @Published var textColor = Color.primary
    @Published var consoleColor = Color.primary
    @Published var textBackground = Color(nsColor: .textBackgroundColor)
    @Published var consoleBackground = Color(nsColor: .textBackgroundColor)
    @Published var startAddress = ""
    @Published var arguments = ""
    @Published var jumpAddress = ""
    @Published var input = ""
    @Published var appendNewline = true
    @Published var messages = ["SwiftSpim · QtSpim 9.1.24 compatibility target"]
    @Published var modal: Modal?
    @Published var edit: FieldEdit?
    @Published var error: String?
    @Published var breakpointAddress = ""
    @Published var exports = Set([DebugPanel.integer, .text, .data, .console])
    private var runTask: Task<Void, Never>?
    private var resumeAfterInput = false
    private var remainingQtBatch = 0
    private var didStart = false
    private var stopped = false
    private let defaults: UserDefaults
    private let environment: () -> [String]
    private var instructionCache: (Machine, UInt64, Bool, Bool, [(address: UInt32, instruction: Instruction)])?
    private var memoryRowsCache: (Int, Bool, Bool, Bool, String, [MemoryDisplayRow])?
    private var explicitFirstPC: UInt32?
    private var lastLoadedURL: URL?
    private var restartAfterStep = false
    private var partialStderr: [UInt8] = []
    let dockTargets = DockTargets()
    var pendingFloatLocations: [DebugPanel: NSPoint] = [:]
    @Published var dock = DockLayout.standard

    init(defaults: UserDefaults = .standard, environment: @escaping () -> [String] = SpimOptions.hostEnvironment) {
        self.environment = environment
        self.defaults = defaults
        recent = defaults.stringArray(forKey: "recent") ?? []
        if defaults.object(forKey: "recentLimit") != nil { recentLimit = defaults.integer(forKey: "recentLimit") }
        if let value = defaults.string(forKey: "registerRadix").flatMap(Radix.init(rawValue:)) { registerRadix = value }
        if let value = defaults.string(forKey: "dataRadix").flatMap(Radix.init(rawValue:)) { dataRadix = value }
        if let value = defaults.stringArray(forKey: "panels") { panels = Set(value.compactMap(DebugPanel.init(rawValue:))) }
        if let data = defaults.data(forKey: "dockLayout"),
           let saved = try? JSONDecoder().decode(DockLayout.self, from: data), saved.isValid {
            dock = saved
        } else {
            for key in ["selectedRegister", "selectedSegment"] {
                if let name = defaults.string(forKey: key), let panel = DebugPanel(rawValue: name) {
                    dock.select(panel)
                }
            }
        }
        options.bareMachine = defaults.bool(forKey: "bare")
        options.delayedBranches = defaults.bool(forKey: "branchDelay")
        options.delayedLoads = defaults.bool(forKey: "loadDelay")
        options.mappedIO = defaults.bool(forKey: "mapped")
        if defaults.object(forKey: "handler") != nil { options.loadExceptionHandler = defaults.bool(forKey: "handler") }
        if defaults.object(forKey: "littleEndian") != nil { options.littleEndian = defaults.bool(forKey: "littleEndian") }
        if defaults.object(forKey: "defaultHandler") != nil { useDefaultHandler = defaults.bool(forKey: "defaultHandler") }
        handlerPath = defaults.string(forKey: "handlerPath") ?? ""
        if let root = defaults.string(forKey: "fileRoot") { options.fileRootURL = URL(fileURLWithPath: root, isDirectory: true) }
        options.restrictFileAccess = defaults.bool(forKey: "restrictFileAccess")
        if defaults.object(forKey: "pseudos") != nil { acceptPseudoInstructions = defaults.bool(forKey: "pseudos") }
        quiet = defaults.bool(forKey: "quiet")
        userText = savedBool("userText", true); kernelText = savedBool("kernelText", true)
        comments = savedBool("comments", true); machineWords = savedBool("machineWords", true)
        userData = savedBool("userData", true); userStack = savedBool("userStack", true)
        kernelData = savedBool("kernelData", true)
        colorChangedRegisters = savedBool("highlightChangedRegisters", true)
        changedRegisterColor = color("changedRegisterColor") ?? .red
        registerSize = defaults.object(forKey: "registerSize") as? Double ?? 13
        registerFamily = defaults.string(forKey: "registerFamily") ?? ""
        registerColor = color("registerColor") ?? .primary
        registerBackground = color("registerBackground") ?? Color(nsColor: .textBackgroundColor)
        textFamily = defaults.string(forKey: "textFamily") ?? ""
        consoleFamily = defaults.string(forKey: "consoleFamily") ?? ""
        textSize = defaults.object(forKey: "textSize") as? Double ?? 13
        consoleSize = defaults.object(forKey: "consoleSize") as? Double ?? 13
        textColor = color("textColor") ?? .primary; consoleColor = color("consoleColor") ?? .primary
        textBackground = color("textBackground") ?? Color(nsColor: .textBackgroundColor)
        consoleBackground = color("consoleBackground") ?? Color(nsColor: .textBackgroundColor)
        if defaults.integer(forKey: "compactLayoutVersion") < 2 {
            let freshRegisters = defaults.object(forKey: "registerSize") == nil && defaults.object(forKey: "registerFamily") == nil
            if freshRegisters || (registerFamily == "Courier" && registerSize == 10) {
                registerFamily = "Courier"
                registerSize = 14
                defaults.set(registerFamily, forKey: "registerFamily")
                defaults.set(registerSize, forKey: "registerSize")
            }
            let freshText = defaults.object(forKey: "textSize") == nil && defaults.object(forKey: "textFamily") == nil
            if freshText || (textFamily == "Courier" && textSize == 11) {
                textFamily = "Courier"
                textSize = 15
                defaults.set(textFamily, forKey: "textFamily")
                defaults.set(textSize, forKey: "textSize")
            }
            if consoleFamily.isEmpty && consoleSize == 13 {
                consoleSize = 15
                defaults.set(consoleSize, forKey: "consoleSize")
            }
            defaults.set(2, forKey: "compactLayoutVersion")
        }
    }
    private func savedBool(_ name: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: name) == nil ? fallback : defaults.bool(forKey: name)
    }
    private func color(_ key: String) -> Color? {
        guard let data = defaults.data(forKey: key),
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else { return nil }
        return Color(nsColor: color)
    }
    func saveDock() { defaults.set(try? JSONEncoder().encode(dock), forKey: "dockLayout") }
    func savePreferences() {
        defaults.set(try? JSONEncoder().encode(dock), forKey: "dockLayout")
        defaults.set(4, forKey: "layoutVersion")
        defaults.set(2, forKey: "compactLayoutVersion")
        defaults.set(recent, forKey: "recent"); defaults.set(recentLimit, forKey: "recentLimit")
        defaults.set(registerRadix.rawValue, forKey: "registerRadix"); defaults.set(dataRadix.rawValue, forKey: "dataRadix")
        defaults.set(panels.map(\.rawValue), forKey: "panels")
        defaults.set(options.bareMachine, forKey: "bare"); defaults.set(options.delayedBranches, forKey: "branchDelay")
        defaults.set(options.delayedLoads, forKey: "loadDelay"); defaults.set(options.mappedIO, forKey: "mapped")
        defaults.set(options.loadExceptionHandler, forKey: "handler"); defaults.set(options.littleEndian, forKey: "littleEndian")
        defaults.set(useDefaultHandler, forKey: "defaultHandler"); defaults.set(handlerPath, forKey: "handlerPath")
        defaults.set(options.fileRootURL?.path, forKey: "fileRoot")
        defaults.set(options.restrictFileAccess, forKey: "restrictFileAccess")
        defaults.set(acceptPseudoInstructions, forKey: "pseudos"); defaults.set(quiet, forKey: "quiet")
        for (key, value) in [("userText", userText), ("kernelText", kernelText), ("comments", comments),
                             ("machineWords", machineWords), ("userData", userData), ("userStack", userStack), ("kernelData", kernelData)] {
            defaults.set(value, forKey: key)
        }
        defaults.set(colorChangedRegisters, forKey: "highlightChangedRegisters")
        defaults.set(registerSize, forKey: "registerSize"); defaults.set(registerFamily, forKey: "registerFamily")
        defaults.set(textFamily, forKey: "textFamily"); defaults.set(consoleFamily, forKey: "consoleFamily")
        defaults.set(textSize, forKey: "textSize"); defaults.set(consoleSize, forKey: "consoleSize")
        for (key, value) in [("registerColor", registerColor), ("registerBackground", registerBackground), ("changedRegisterColor", changedRegisterColor),
                             ("textColor", textColor), ("consoleColor", consoleColor),
                             ("textBackground", textBackground), ("consoleBackground", consoleBackground)] {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: NSColor(value), requiringSecureCoding: true) {
                defaults.set(data, forKey: key)
            }
        }
    }
    var registerFont: Font { registerFamily.isEmpty ? .system(size: registerSize, design: .monospaced) : .custom(registerFamily, size: registerSize) }
    var displayFont: Font { textFamily.isEmpty ? .system(size: textSize, design: .monospaced) : .custom(textFamily, size: textSize) }
    var machineOptions: SpimOptions { machine?.options ?? options }
    var statusLabel: String {
        if running { return "Running" }
        if stopped { return "Stopped" }
        guard let machine else { return "No program loaded" }
        switch machine.status {
        case .ready: return "Ready"
        case .running: return "Paused"
        case .paused: return "Paused"
        case .waitingInput: return "Waiting for input"
        case .halted(let code): return "Exited (\(code))"
        case .fault(let reason): return "Fault: \(reason)"
        }
    }
    var mayExecute: Bool {
        machine != nil && !files.isEmpty && !running
    }
    func show(_ panel: DebugPanel) -> Binding<Bool> {
        Binding(get: { self.panels.contains(panel) }, set: { enabled in
            if enabled { self.panels.insert(panel) } else { self.panels.remove(panel) }
            self.savePreferences()
        })
    }
    func tileLayout() {
        panels.formUnion([.integer, .floating, .text, .data])
        dock = .standard
        savePreferences()
    }
    func restoreLayout() {
        panels = Set(DebugPanel.allCases)
        dock = .standard
        savePreferences()
    }
    func configureBare(_ bare: Bool) {
        options.bareMachine = bare
        options.delayedBranches = bare
        options.delayedLoads = bare
        acceptPseudoInstructions = !bare
        savePreferences()
    }
    func chooseHandler() {
        let open = NSOpenPanel()
        open.message = "Choose a custom SPIM exception handler"
        if open.runModal() == .OK, let file = open.url {
            handlerPath = file.path
            useDefaultHandler = false
            options.loadExceptionHandler = true
            savePreferences()
        }
    }
    func chooseFiles(reinitialize: Bool) {
        if reinitialize { reinitializeSimulator() }
        let open = NSOpenPanel()
        open.message = "Open Assembly Code"
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        if let previous = recent.first { open.directoryURL = URL(fileURLWithPath: previous).deletingLastPathComponent() }
        if open.runModal() == .OK { load(open.urls, appending: true) }
    }
    func load(_ urls: [URL], appending: Bool) {
        let continueOnInput = resumeAfterInput && machine?.status == .waitingInput
        pause()
        defer {
            if continueOnInput, machine?.status == .waitingInput { resumeAfterInput = true }
        }
        do {
            let new = try urls.map { url in
                ProgramFile(url: url, input: SourceInput(name: url.path, data: try Data(contentsOf: url)))
            }
            var pending = appending ? files : []
            for item in new {
                if let i = pending.firstIndex(where: { $0.url == item.url }) { pending[i] = item }
                else { pending.append(item) }
            }
            try assemble(pending, keepState: appending && !files.isEmpty)
            files = pending
            if let url = urls.last { lastLoadedURL = url }
            for item in new {
                recent.removeAll { $0 == item.url.path }
                recent.insert(item.url.path, at: 0)
                log("Loaded \(item.url.lastPathComponent)")
            }
            trimRecent()
            savePreferences()
        } catch { fail(error) }
    }
    private func assemble(_ sources: [ProgramFile], keepState: Bool) throws {
        var effective = options
        effective.strictEntryPoint = true
        effective.upstreamInterruptSampling = true
        effective.quiet = quiet
        effective.environment = environment()
        if !options.restrictFileAccess { effective.fileRootURL = nil }
        effective.acceptPseudoInstructions = acceptPseudoInstructions
        var input = sources.map(\.input)
        if effective.loadExceptionHandler && !useDefaultHandler {
            guard !handlerPath.isEmpty else {
                throw NSError(domain: "SwiftSpim", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a custom exception handler in Settings, or enable Use default exception handler."])
            }
            effective.loadExceptionHandler = false
            let url = URL(fileURLWithPath: handlerPath)
            var handler = SourceInput(name: url.path, data: try Data(contentsOf: url))
            handler.isExceptionHandler = true
            input.insert(handler, at: 0)
        }
        let compiled = try Assembler().assemble(input, options: effective, allowUndefinedSymbols: true, recovering: true)
        for diagnostic in compiled.diagnostics { messages.append(diagnostic.description) }
        if !sources.isEmpty, !compiled.unresolvedSymbols.isEmpty {
            messages.append("Undefined symbols: " + compiled.unresolvedSymbols.joined(separator: ", "))
        }
        if keepState, let machine {
            machine.install(image: compiled, options: effective)
        } else {
            partialStderr.removeAll()
            machine = Machine(image: compiled, options: effective)
            didStart = false
            stopped = false
            explicitFirstPC = nil
            restartAfterStep = false
        }
        refresh()
    }
    func reinitializeSimulator() {
        pause()
        files = []
        lastLoadedURL = nil
        resumeAfterInput = false
        do { try assemble([], keepState: false) }
        catch { machine = nil; fail(error) }
        log("Memory and registers cleared")
    }
    func refresh() { generation &+= 1 }
    func trimRecent() { recent = Array(recent.prefix(max(0, recentLimit))) }
    func clearRegisters() {
        guard let machine else { return }
        machine.clearRegisters()
        explicitFirstPC = nil
        restartAfterStep = false
        stopped = false
        didStart = false
        refresh()
    }
    func log(_ message: String) {
        if !quiet { messages.append(message) }
        if messages.count > 2000 { messages.removeFirst(messages.count - 2000) }
    }
    func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        messages.append(message)
        self.error = message
    }
    func number(_ text: String) -> UInt32? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let symbol = machine?.image.symbols[value] { return symbol }
        if value.lowercased().hasPrefix("0x") { return UInt32(value.dropFirst(2), radix: 16) }
        if value.lowercased().hasPrefix("0b") { return UInt32(value.dropFirst(2), radix: 2) }
        if let signed = Int32(value) { return UInt32(bitPattern: signed) }
        return UInt32(value)
    }
    struct RunParameters: Equatable {
        var address: String
        var arguments: String
    }
    var runParameters: RunParameters { .init(address: startAddress, arguments: arguments) }
    func finishRunParameters(_ draft: RunParameters?) {
        if let draft {
            startAddress = draft.address
            arguments = draft.arguments
        }
        modal = nil
    }
    func readyToStart(_ machine: Machine) -> Bool {
        guard !didStart || restartAfterStep || machine.pc == 0 else {
            machine.prepareToExecute()
            return true
        }
        let address = explicitFirstPC ?? number(startAddress)
        if !startAddress.trimmingCharacters(in: .whitespaces).isEmpty, address == nil || (address ?? 0) & 3 != 0 {
            error = "Enter a valid, word-aligned start address or symbol."
            return false
        }
        let tokens = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        let argv = lastLoadedURL.map { [$0.path] } ?? []
        machine.prepareToExecute()
        machine.setRunParameters(address: address, arguments: argv + tokens)
        didStart = true
        explicitFirstPC = nil
        restartAfterStep = false
        return true
    }
    func run(resumingInput: Bool = false) {
        guard let machine, !running, readyToStart(machine) else { return }
        if case .waitingInput = machine.status { resumeAfterInput = true; return }
        if !resumingInput { remainingQtBatch = 0 }
        stopped = false
        running = true
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastRefresh = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled, self.running, self.machine === machine {
                let deadline = ProcessInfo.processInfo.systemUptime + 0.008
                repeat {
                    // Qt requests 100,000 instructions per Run batch. Yield
                    // to SwiftUI more frequently without polling extra IRQs.
                    let startsBatch = self.remainingQtBatch == 0
                    if startsBatch { self.remainingQtBatch = 100_000 }
                    let count = min(512, self.remainingQtBatch)
                    let before = machine.instructionCount
                    machine.run(maxSteps: count, pollAtStart: startsBatch, logicalBatchSteps: 100_000)
                    if machine.status == .running {
                        self.remainingQtBatch -= count
                    } else {
                        self.remainingQtBatch -= Int(min(UInt64(count), machine.instructionCount &- before))
                        break
                    }
                } while ProcessInfo.processInfo.systemUptime < deadline
                self.drainDiagnostics(machine)
                switch machine.status {
                case .halted, .fault:
                    self.running = false
                    if case .fault = machine.status { self.messages.append(self.statusLabel) }
                    else { self.log(self.statusLabel) }
                case .waitingInput:
                    self.resumeAfterInput = true
                    self.running = false
                case .paused where machine.breakpoints.contains(machine.pc):
                    self.running = false
                    self.log("Breakpoint at \(Radix.hex.show(machine.pc))")
                    self.modal = .hit
                default: break
                }
                let now = ProcessInfo.processInfo.systemUptime
                if !self.running || now - lastRefresh >= 0.1 {
                    self.refresh()
                    lastRefresh = now
                }
                if self.running { await Task.yield() }
            }
        }
    }
    func pause() {
        runTask?.cancel()
        runTask = nil
        machine?.pause()
        running = false
        resumeAfterInput = false
        refresh()
    }
    func stop() {
        pause()
        machine?.stop()
        stopped = true
        restartAfterStep = false
        refresh()
        log("Execution stopped")
    }
    func step() {
        guard let machine, !running, readyToStart(machine) else { return }
        resumeAfterInput = false
        stopped = false
        machine.step()
        drainDiagnostics(machine)
        switch machine.status {
        case .fault(let reason): messages.append(reason); restartAfterStep = true
        case .halted: restartAfterStep = true
        default: break
        }
        refresh()
    }
    private func drainDiagnostics(_ machine: Machine) {
        if !machine.stderrBytes.isEmpty {
            partialStderr.append(contentsOf: machine.stderrBytes)
            machine.stderrBytes.removeAll(keepingCapacity: true)
        }
        if !partialStderr.isEmpty {
            let boundary = machine.status == .running
                ? partialStderr.lastIndex(of: 10).map { $0 + 1 } ?? 0
                : partialStderr.count
            if boundary > 0 {
                messages.append(String(decoding: partialStderr.prefix(boundary), as: UTF8.self).trimmingCharacters(in: .newlines))
                partialStderr.removeFirst(boundary)
            }
        }
        let diagnostic = machine.takeDiagnostics()
        if !diagnostic.isEmpty { messages.append(diagnostic.trimmingCharacters(in: .newlines)) }
    }
    func sendInput() {
        guard let machine else { return }
        let shouldResume = resumeAfterInput
        let wasWaiting = machine.status == .waitingInput
        resumeAfterInput = false
        let bytes = input + (!machine.options.usesMappedIO || appendNewline ? "\n" : "")
        if !machine.options.usesMappedIO { machine.outputBytes.append(contentsOf: bytes.utf8) }
        machine.provideInput(bytes)
        input = ""
        refresh()
        if shouldResume { run(resumingInput: true) }
        else if wasWaiting { step() }
    }
    func toggleBreakpoint(_ address: UInt32) {
        guard let machine else { return }
        if machine.breakpoints.contains(address) { machine.breakpoints.remove(address) }
        else { machine.breakpoints.insert(address) }
        refresh()
    }
    func submitBreakpoint() {
        guard let address = number(breakpointAddress), address & 3 == 0 else {
            error = "Enter a word-aligned instruction address or symbol."
            return
        }
        toggleBreakpoint(address)
        breakpointAddress = ""
        modal = nil
    }
    var instructions: [(address: UInt32, instruction: Instruction)] {
        guard let machine else { return [] }
        if let cached = instructionCache, cached.0 === machine, cached.1 == machine.codeRevision,
           cached.2 == userText, cached.3 == kernelText { return cached.4 }
        let rows = machine.liveInstructions.filter { address, _ in
            address >= 0x8000_0000 ? kernelText : userText
        }.sorted { $0.key < $1.key }.map { (address: $0.key, instruction: $0.value) }
        instructionCache = (machine, machine.codeRevision, userText, kernelText, rows)
        return rows
    }

    struct MemoryDisplayRow: Identifiable {
        let address: UInt32
        let zeroEndExclusive: UInt32?
        var heading: String? = nil
        var id: UInt32 { address }
        var zeroDescription: String? {
            zeroEndExclusive.map { Radix.hex.show(address) + " – " + Radix.hex.show($0 - 1) + "   (zero-filled)" }
        }
    }

    var memoryRows: [MemoryDisplayRow] {
        guard let machine else { return [] }
        if let c = memoryRowsCache, c.0 == generation, c.1 == userData, c.2 == userStack,
           c.3 == kernelData, c.4 == jumpAddress { return c.5 }
        var rows: [MemoryDisplayRow] = []
        var occupied = Set<UInt32>()
        for (address, byte) in machine.memory where byte != 0 { occupied.insert(address & ~15) }
        let jump = number(jumpAddress).map { $0 & ~15 }
        if let jump { occupied.insert(jump) }
        let addresses = occupied.sorted()
        var foundJump = false
        for range in machine.segmentRanges {
            let enabled: Bool
            switch range.kind {
            case .userData: enabled = userData
            case .stack: enabled = userStack
            case .kernelData: enabled = kernelData
            }
            guard range.lowerBound < range.upperBoundExclusive else { continue }
            let start = range.lowerBound & ~15
            let end = range.upperBoundExclusive
            if let jump, jump >= start, jump < end { foundJump = true }
            guard enabled else { continue }
            let firstRowIndex = rows.count
            var cursor = start
            for address in addresses where address >= start && address < end {
                if cursor < address { rows.append(.init(address: cursor, zeroEndExclusive: address)) }
                rows.append(.init(address: address, zeroEndExclusive: nil))
                cursor = address + 16
            }
            if cursor < end { rows.append(.init(address: cursor, zeroEndExclusive: end)) }
            let title: String
            switch range.kind {
            case .userData: title = "User data segment"
            case .stack: title = "User stack"
            case .kernelData: title = "Kernel data segment"
            }
            rows[firstRowIndex].heading = title + "  " + Radix.hex.show(range.lowerBound) + " – " + Radix.hex.show(end - 1)
        }
        if let jump, !foundJump { rows.append(.init(address: jump, zeroEndExclusive: nil)) }
        rows.sort { $0.address < $1.address }
        memoryRowsCache = (generation, userData, userStack, kernelData, jumpAddress, rows)
        return rows
    }
    func readWord(at address: UInt32) -> UInt32 {
        machine?.peekWord(at: address) ?? 0
    }
    func writeWord(_ value: UInt32, at address: UInt32) {
        guard let machine else { return }
        do { try machine.writeWord(value, at: address) }
        catch { fail(error) }
    }
    func apply(_ edit: FieldEdit, value: String) {
        guard let machine else { return }
        switch edit.target {
        case .floating(let index):
            guard let new = value.hasPrefix("0x") ? number(value) : Float(value).map(\.bitPattern) else {
                error = "Enter a floating-point number or hexadecimal bit pattern."; return
            }
            machine.floatingRegisters[index] = new
        case .double(let index):
            guard let new = value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : Double(value).map(\.bitPattern) else {
                error = "Enter a double or hexadecimal bit pattern."; return
            }
            let low = UInt32(truncatingIfNeeded: new), high = UInt32(truncatingIfNeeded: new >> 32)
            machine.floatingRegisters[index] = machineOptions.littleEndian ? low : high
            machine.floatingRegisters[index + 1] = machineOptions.littleEndian ? high : low
        default:
            guard let new = number(value) else { error = "Enter a valid 32-bit number or symbol."; return }
            switch edit.target {
            case .integer(let index): if index != 0 { machine.registers[index] = new }
            case .pc:
                machine.pc = new
                if !didStart || restartAfterStep { explicitFirstPC = new }
            case .hi: machine.hi = new
            case .cp0(let index): machine.coprocessor0[index] = new
            case .fcsr: machine.fcsr = new
            case .lo: machine.lo = new
            case .memory(let address): writeWord(new, at: address)
            default: break
            }
        }
        refresh()
    }
    func exportText() -> String {
        _ = generation
        guard let machine else { return "" }
        var sections: [String] = []
        if exports.contains(.integer) {
            let special: [(String, UInt32)] = [("PC", machine.pc), ("EPC", machine.coprocessor0[14]),
                ("Cause", machine.coprocessor0[13]), ("BadVAddr", machine.coprocessor0[8]),
                ("Status", machine.coprocessor0[12]), ("HI", machine.hi), ("LO", machine.lo)]
            sections.append("Integer Registers\n" + special.map { "\($0.0)\t\(registerRadix.show($0.1))" }.joined(separator: "\n") + "\n" + machine.registers.enumerated().map {
                "$\($0.offset) (\(MIPSListing.names[$0.offset]))\t\(registerRadix.show($0.element))"
            }.joined(separator: "\n"))
        }
        if exports.contains(.floating) {
            sections.append("Floating-Point Registers\nFIR\t" + registerRadix.show(machine.floatingControl[0]) + "\nFCSR\t" + registerRadix.show(machine.fcsr) + "\nSingle Precision\n" + machine.floatingRegisters.enumerated().map {
                "$f\($0.offset)\t\(Float(bitPattern: $0.element))\t\(Radix.hex.show($0.element))"
            }.joined(separator: "\n") + "\nDouble Precision\n" + stride(from: 0, to: 32, by: 2).map {
                "$f\($0)\t\(machine.doubleRegister($0))"
            }.joined(separator: "\n"))
        }
        if exports.contains(.text) {
            sections.append("Text Segments\n" + instructions.map {
                row in
                let word = machine.instructionWord(at: row.address) ?? row.instruction.word
                return "\(Radix.hex.show(row.address))\t\(Radix.hex.show(word))\t\(SpimDisassembler.format(word, at: row.address, delayedBranches: machineOptions.delayedBranches))\t\(row.instruction.source)"
            }.joined(separator: "\n"))
        }
        if exports.contains(.data) { sections.append("Data Segments\n" + memoryRows.map { row in
            let heading = row.heading.map { $0 + "\n" } ?? ""
            if let zero = row.zeroDescription { return heading + zero }
            let address = row.address
            return heading + Radix.hex.show(address) + "\t" + (0..<4).map { dataRadix.show(readWord(at: address &+ UInt32($0 * 4))) }.joined(separator: "\t")
        }.joined(separator: "\n")) }
        if exports.contains(.console) { sections.append("Console\n" + machine.output) }
        if exports.contains(.messages) { sections.append("Messages\n" + messages.joined(separator: "\n")) }
        return sections.joined(separator: "\n\n") + "\n"
    }
    func launch(_ args: [String]) {
        var i = 0
        while i < args.count {
            let flag = args[i]
            i += 1
            switch flag {
            case "-asm", "-a": options.bareMachine = false; options.delayedBranches = false; options.delayedLoads = false
            case "-bare", "-b": options.bareMachine = true; options.delayedBranches = true; options.delayedLoads = true; quiet = true
            case "-delayed_branches", "-db": options.delayedBranches = true
            case "-delayed_loads", "-dl": options.delayedLoads = true
            case "-exception", "-e", "-trap", "-t":
                options.loadExceptionHandler = true
            case "-noexception", "-ne", "-notrap", "-nt": options.loadExceptionHandler = false
            case "-exception_file", "-ef", "-trap_file", "-tf":
                if i < args.count {
                    handlerPath = args[i]; i += 1; options.loadExceptionHandler = true; useDefaultHandler = false
                } else { messages.append("Missing exception handler path after \(flag)") }
            case "-mapped_io", "-mio": options.mappedIO = true
            case "-nomapped_io", "-nmio": options.mappedIO = false
            case "-pseudo", "-p": acceptPseudoInstructions = true
            case "-nopseudo", "-np": acceptPseudoInstructions = false
            case "-quiet", "-q": quiet = true
            case "-noquiet", "-nq": quiet = false
            case let memoryFlag where SpimMemoryLayout.legacyFlags.contains(memoryFlag):
                guard i < args.count else {
                    messages.append("Missing byte count after \(flag)")
                    continue
                }
                let token = args[i]
                // Keep a following switch available for normal parsing if its
                // predecessor omitted the size, but consume negative integers.
                if !token.hasPrefix("-") || Int64(token) != nil { i += 1 }
                var layout = options.memoryLayout
                guard let size = UInt32(token), size > 0,
                      layout.setLegacyOption(flag, bytes: size) else {
                    messages.append("Invalid byte count for \(flag): \(token)")
                    continue
                }
                options.memoryLayout = layout
            case "-NSDocumentRevisionsDebugMode", "-ApplePersistenceIgnoreState", "-AppleLanguages", "-AppleLocale", "-NSQuitAlwaysKeepsWindows":
                if i < args.count { i += 1 }
            case let value where value.hasPrefix("-psn_"): break
            case "-file", "-f":
                reinitializeSimulator()
                load(args[i...].map { URL(fileURLWithPath: $0) }, appending: true)
                return
            default:
                if flag.hasPrefix("-") { messages.append("Unknown option \(flag)") }
                else {
                    reinitializeSimulator()
                    load(([flag] + Array(args[i...])).map { URL(fileURLWithPath: $0) }, appending: true)
                    return
                }
            }
        }
        reinitializeSimulator()
    }
    func saveLog() {
        let save = NSSavePanel()
        save.nameFieldStringValue = "SwiftSpim Log.txt"
        save.allowedContentTypes = [.plainText]
        if save.runModal() == .OK, let url = save.url {
            do { try exportText().write(to: url, atomically: true, encoding: .utf8) }
            catch { fail(error) }
        }
    }
    func printLog() {
        let content = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        content.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        content.string = exportText()
        if let container = content.textContainer, let layout = content.layoutManager {
            container.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            content.setFrameSize(NSSize(width: 500, height: max(700, layout.usedRect(for: container).height + 20)))
        }
        let operation = NSPrintOperation(view: content)
        operation.printInfo.horizontalPagination = .fit
        operation.printInfo.verticalPagination = .automatic
        operation.run()
    }
}

enum MIPSListing {
    static let names = ["zero", "at", "v0", "v1", "a0", "a1", "a2", "a3",
                        "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7",
                        "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7",
                        "t8", "t9", "k0", "k1", "gp", "sp", "fp", "ra"]
}
#endif
