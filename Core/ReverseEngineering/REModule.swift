import Foundation
import SwiftUI
import Observation
import AxiomCore

/// The Reverse Engineering module: static binary analysis built on the ported
/// AxiomRE engine (Packages/AxiomCore). All analysis is read-only with respect
/// to the analyzed file — binaries are copied into the app sandbox and never
/// executed; engine subprocesses (otool, optionally Ghidra/radare2 configured by
/// the analyst) are the only tools invoked, and they work on the sandbox copy.
@MainActor
@Observable
public final class REModule: @preconcurrency Module, @preconcurrency ModuleDefinition, ModuleUI {
    public nonisolated static let identifier = "com.kiln.reverseengineering"
    public nonisolated static let displayName = "Reverse Engineering Console"
    public nonisolated static let version = "1.0.0"
    public nonisolated static let dependencies: [String] = []
    public nonisolated static let requiredCapabilities: ModuleCapabilities = [
        .fileSystemRead, .processSpawn, .memoryInspection, .debuggerAttach, .kernelDebug,
    ]

    /// One analyzed binary + its persisted project folder.
    public struct REProject: Identifiable, Sendable {
        public let id: String
        public let folder: URL
        public let binaryURL: URL
        public var analysis: Analysis?
        public var loaded = false

        public init(folder: URL, binaryURL: URL, analysis: Analysis? = nil, loaded: Bool = false) {
            self.id = folder.lastPathComponent
            self.folder = folder
            self.binaryURL = binaryURL
            self.analysis = analysis
            self.loaded = loaded
        }
    }

    public private(set) var projects: [REProject] = []
    public private(set) var selectedID: String?
    public private(set) var bootstrapError: String?

    /// Analyst-configured Ghidra install (must contain support/analyzeHeadless) and
    /// the AxiomExport.java post script. Nil = Ghidra analysis unavailable; native
    /// otool inspection still works.
    public var ghidraHome: URL?
    public var ghidraScriptURL: URL?

    private var context: ModuleContext?
    private var projectsRoot: URL = URL(fileURLWithPath: NSTemporaryDirectory())

    /// Read-only debug-probe access. Its audit log moves into Application Support once the module initializes.
    public private(set) var deviceBench = REDeviceBench(
        auditLog: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kiln-bench-sessions.jsonl"))

    public nonisolated init() {}

    // MARK: Module lifecycle

    public func initialize(context: ModuleContext) async throws {
        self.context = context
        context.logger.info("Reverse Engineering module initialized")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        await MainActor.run {
            self.projectsRoot = support.appendingPathComponent("ReverseEngineering/Projects", isDirectory: true)
            try? FileManager.default.createDirectory(at: self.projectsRoot, withIntermediateDirectories: true)
            self.deviceBench = REDeviceBench(
                auditLog: support.appendingPathComponent("ReverseEngineering/bench-sessions.jsonl"))
        }
        await reloadProjectList()
        context.logger.info("Reverse Engineering module ready (\(projects.count) projects)")
    }

    public func activate() async throws { context?.logger.info("Reverse Engineering activated") }
    public func deactivate() async throws { context?.logger.info("Reverse Engineering deactivated") }
    public func shutdown() async throws { context = nil }

    public nonisolated func contributeMenus() -> [MenuContribution] {
        [MenuContribution(title: "Reverse Engineering", items: ["Import Binary…", "Analyze with Ghidra…"])]
    }

    public nonisolated func contributeCommands() -> [CommandContribution] {
        [
            CommandContribution(identifier: "re.importBinary", title: "Import Binary", shortcut: "⌘⇧I", category: "Reverse Engineering"),
            CommandContribution(identifier: "re.undo", title: "Undo", shortcut: "⌘Z", category: "Reverse Engineering"),
            CommandContribution(identifier: "re.redo", title: "Redo", shortcut: "⇧⌘Z", category: "Reverse Engineering"),
        ]
    }

    public func makeRootView() -> AnyView {
        AnyView(REModuleRootView(module: self))
    }

    // MARK: Analysis surface

    /// Imports a binary into a new project folder under Application Support, then
    /// runs native inspection (file type, format, sections, strings, otool
    /// disassembly). 256 MiB import cap; anything larger is refused with a
    /// specific reason.
    public func importBinary(at url: URL) async throws -> Analysis {
        let root = try await MainActor.run { self.projectsRoot }
        let imported = try await Task.detached(priority: .userInitiated) {
            try Self.importBinaryUnchecked(at: url, into: root)
        }.value
        let project = REProject(
            folder: imported.folder,
            binaryURL: imported.folder.appendingPathComponent(
                imported.analysis.binaryPath.components(separatedBy: "/").last ?? imported.analysis.binaryPath),
            analysis: imported.analysis, loaded: true)
        await MainActor.run {
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                projects[index] = project
            } else {
                projects.append(project)
            }
            selectedID = project.id
        }
        return imported.analysis
    }

    public func configureGhidra(home: URL, script: URL) {
        ghidraHome = home
        ghidraScriptURL = script
    }

    /// Runs the full Ghidra headless pipeline over an existing project. Requires a
    /// configured Ghidra home and export script; throws a specific reason otherwise.
    public func analyzeWithGhidra(projectID: String) async throws -> Analysis {
        guard let home = ghidraHome, let script = ghidraScriptURL else {
            throw REError.ghidraNotConfigured
        }
        let project = try await MainActor.run { try self.projectFolder(id: projectID) }
        let analysis = try await Task.detached(priority: .userInitiated) {
            try Analyzer.analyzeProject(project.binaryURL.path, project: project.folder.path,
                                        home: home.path, scriptPath: script.path, arch: nil)
            return try ProjectStore.load(project.folder.path)
        }.value
        await MainActor.run { self.replace(projectID: projectID, with: analysis) }
        return analysis
    }

    /// Analysis as stored on disk for this project.
    public func analysis(projectID: String) async throws -> Analysis {
        try await MainActor.run { try self.loadedAnalysis(projectID: projectID) }
    }

    /// Disassembly text for one function, as the engine produced it.
    public func disassembly(projectID: String, address: String) async throws -> String {
        try await MainActor.run {
            let analysis = try self.loadedAnalysis(projectID: projectID)
            guard let function = analysis.functions.first(where: {
                ProjectStore.normalizedAddress($0.address) == ProjectStore.normalizedAddress(address)
            }) else { throw REError.unknownFunction }
            return function.assembly
        }
    }

    /// Decompiled pseudocode for one function (Ghidra analyses only).
    public func decompilation(projectID: String, address: String) async throws -> String {
        try await MainActor.run {
            let analysis = try self.loadedAnalysis(projectID: projectID)
            guard let function = analysis.functions.first(where: {
                ProjectStore.normalizedAddress($0.address) == ProjectStore.normalizedAddress(address)
            }) else { throw REError.unknownFunction }
            guard !function.code.isEmpty else {
                throw REError.noDecompilation("No decompiled code for this function.")
            }
            return function.code
        }
    }

    /// Substring search over the project's extracted strings.
    public func searchStrings(projectID: String, pattern: String, caseSensitive: Bool = false) async throws -> [StringMatch] {
        let analysis = try await MainActor.run { try self.loadedAnalysis(projectID: projectID) }
        let haystack = caseSensitive ? pattern : pattern.lowercased()
        return analysis.strings.enumerated().compactMap { index, record in
            let value = caseSensitive ? record.value : record.value.lowercased()
            guard value.contains(haystack) else { return nil }
            return StringMatch(record: record, rank: index)
        }
    }

    /// Cross-references to or from one address.
    public func xrefs(projectID: String, address: String, direction: String? = nil) async throws -> [Xref] {
        try await MainActor.run {
            let analysis = try self.loadedAnalysis(projectID: projectID)
            let key = ProjectStore.normalizedAddress(address)
            guard let function = analysis.functions.first(where: {
                ProjectStore.normalizedAddress($0.address) == key
            }) else { throw REError.unknownFunction }
            let outgoing = function.callees.map { Xref(from: address, to: $0, kind: "call") }
            let incoming = analysis.functions.compactMap { f in
                f.callees.contains(address) ? Xref(from: f.address, to: address, kind: "call") : nil
            }
            switch direction {
            case "to": return outgoing
            case "from": return incoming
            default: return outgoing + incoming
            }
        }
    }

    /// Crypto-constant scan over the project's binary.
    public func scanCrypto(projectID: String) async throws -> [CryptoHit] {
        try await Task.detached(priority: .userInitiated) {
            let project = try await MainActor.run { try self.projectFolder(id: projectID) }
            let data = try ToolBelt.readData(project.binaryURL.path, limit: ToolBelt.scanLimit)
            return CryptoIdentifier.scan(data)
        }.value
    }

    /// Runs analyst-supplied YARA-subset rules over the project's binary. Syntax
    /// errors surface as `RuleSyntaxError` with the position the compiler reports.
    public func scanRules(projectID: String, source: String) async throws -> [RuleMatch] {
        try await Task.detached(priority: .userInitiated) {
            let rules = try RuleScanner.compile(source)
            let project = try await MainActor.run { try self.projectFolder(id: projectID) }
            let data = try ToolBelt.readData(project.binaryURL.path, limit: ToolBelt.scanLimit)
            return RuleScanner.scan(data, rules: rules)
        }.value
    }

    /// Dump forensics over the project's binary: embedded module listing plus, when the
    /// file is an ELF/Mach-O core dump, its region layout. Read-only; nothing is extracted.
    public func dumpForensics(projectID: String) async throws -> REDumpReport {
        try await Task.detached(priority: .userInitiated) {
            let project = try await MainActor.run { try self.projectFolder(id: projectID) }
            let data = try ToolBelt.readData(project.binaryURL.path, limit: ToolBelt.scanLimit)
            return REDumpReport(modules: DumpForensics.listModules(data), core: DumpForensics.parseCore(data))
        }.value
    }

    /// Runs an analyst script against the project's binary. The script sees the binary's
    /// path as `binary` and the `axiom` analysis API. The caller gets an answer after
    /// `timeout` even if the script is still running: JavaScriptCore offers no way to
    /// interrupt a script in-process, so a runaway script keeps its own thread busy until
    /// the process exits. The thread is dedicated, so it never starves the cooperative pool.
    public func runScript(projectID: String, source: String,
                          timeout: Duration = .seconds(10)) async throws -> REScriptResult {
        let binaryPath = try await MainActor.run { try self.projectFolder(id: projectID).binaryURL.path }
        let encoded = String(data: try JSONSerialization.data(withJSONObject: [binaryPath]), encoding: .utf8) ?? "[\"\"]"
        let script = "var binary = \(encoded.dropFirst().dropLast());\n" + source
        let seconds = Int(timeout.components.seconds)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeOnce()
            let worker = Thread {
                let outcome: Result<REScriptResult, Error>
                switch ScriptConsole().run(script: script) {
                case .success(let (value, output)):
                    outcome = .success(REScriptResult(value: value, output: output))
                case .failure(let error):
                    outcome = .failure(error)
                }
                if gate.claim() { continuation.resume(with: outcome) }
            }
            worker.stackSize = 8 * 1024 * 1024
            worker.start()
            Task.detached {
                try? await Task.sleep(for: timeout)
                if gate.claim() { continuation.resume(throwing: REError.scriptTimedOut(seconds)) }
            }
        }
    }

    /// Format carving over the project's binary.
    public func carveFormats(projectID: String) async throws -> [FormatHit] {
        try await Task.detached(priority: .userInitiated) {
            let project = try await MainActor.run { try self.projectFolder(id: projectID) }
            let data = try ToolBelt.readData(project.binaryURL.path, limit: ToolBelt.scanLimit)
            return FormatIdentifier.scan(data) + FormatIdentifier.identifyPacker(data)
        }.value
    }

    /// ROP/JOP gadget search over the project's disassembly.
    public func findGadgets(projectID: String, ending: String? = nil, depth: Int? = nil) async throws -> [Gadget] {
        try await Task.detached(priority: .userInitiated) {
            let (analysis, binaryPath) = try await MainActor.run {
                (try self.loadedAnalysis(projectID: projectID), try self.projectFolder(id: projectID).binaryURL.path)
            }
            if analysis.functions.isEmpty {
                // Stripped binaries recover no functions, so sweep the whole disassembly instead.
                let listing = try Analyzer.disassemblyListing(binaryPath, arch: analysis.slice)
                return GadgetSearch.search(assembly: listing, depth: depth ?? 5, ending: ending ?? "ret", limit: 1024)
            }
            return GadgetSearch.search(
                functions: analysis.functions,
                depth: depth ?? 5,
                ending: ending ?? "ret",
                limit: 1024
            )
        }.value
    }

    /// Attempt decryption against typed keys, strings found in the binary, and/or
    /// a wordlist file. Results carry validator evidence and key fingerprints,
    /// never key material.
    public func autoDecrypt(projectID: String, ciphers: [String]?, keys: [String]?,
                            wordlistURL: URL?) async throws -> [CandidateResult] {
        try await Task.detached(priority: .userInitiated) {
            let project = try await MainActor.run { try self.projectFolder(id: projectID) }
            let data = try ToolBelt.readData(project.binaryURL.path, limit: ToolBelt.scanLimit)
            var wordlist: Data?
            if let wordlistURL {
                wordlist = try ToolBelt.readData(wordlistURL.path, limit: ToolBelt.wordlistLimit)
            }
            var options = AutoDecryptor.Options()
            options.ciphers = ciphers?.compactMap { Cipher(rawValue: $0) }
            return try AutoDecryptor.run(data: data, typedKeys: keys ?? [], wordlist: wordlist, options: options)
        }.value
    }

    /// Revision-controlled edit of one project (names, comments, signatures,
    /// address notes/labels, variable renames). All operations apply atomically
    /// under one revision bump.
    public func editProject(projectID: String, expectedRevision: Int,
                            operations: [REEditOperation]) async throws -> Analysis {
        try await mutatingProject(projectID: projectID, expectedRevision: expectedRevision) { project in
            let result = try ProjectStore.transact(project.folder.path, expectedRevision: expectedRevision,
                                                   operations.map { $0.operation })
            return try ProjectStore.load(project.folder.path)
        }
    }

    public func undo(projectID: String, expectedRevision: Int) async throws -> Analysis {
        try await mutatingProject(projectID: projectID, expectedRevision: expectedRevision) {
            try ProjectStore.undo($0.folder.path, expectedRevision: expectedRevision)
        }
    }

    public func redo(projectID: String, expectedRevision: Int) async throws -> Analysis {
        try await mutatingProject(projectID: projectID, expectedRevision: expectedRevision) {
            try ProjectStore.redo($0.folder.path, expectedRevision: expectedRevision)
        }
    }

    public func toggleBookmark(projectID: String, expectedRevision: Int, address: String) async throws -> Analysis {
        try await mutatingProject(projectID: projectID, expectedRevision: expectedRevision) {
            try ProjectStore.toggleBookmark($0.folder.path, expectedRevision: expectedRevision, address: address)
        }
    }

    // MARK: Internal

    public func select(projectID: String) {
        selectedID = projectID
    }

    public var selected: REProject? {
        projects.first { $0.id == selectedID }
    }

    public func reloadProjectList() async {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        var loaded: [REProject] = []
        for folder in folders where folder.hasDirectoryPath {
            let analysisJSON = folder.appendingPathComponent("analysis.json")
            guard FileManager.default.fileExists(atPath: analysisJSON.path) else { continue }
            guard let data = try? Data(contentsOf: analysisJSON),
                  let analysis = try? JSONDecoder().decode(Analysis.self, from: data) else { continue }
            let binaryName = analysis.binaryPath.components(separatedBy: "/").last ?? "binary"
            let binaryURL = folder.appendingPathComponent(binaryName)
            loaded.append(REProject(folder: folder, binaryURL: binaryURL,
                                    analysis: analysis, loaded: true))
        }
        loaded.sort { ($0.analysis?.created ?? .distantPast) > ($1.analysis?.created ?? .distantPast) }
        projects = loaded
        if selectedID == nil, let first = projects.first { selectedID = first.id }
    }

    public func deleteProject(id: String) async throws {
        var folder: URL?
        await MainActor.run {
            folder = projects.first(where: { $0.id == id })?.folder
        }
        guard let folder else { return }
        try await Task.detached(priority: .utility) {
            try FileManager.default.removeItem(at: folder)
        }.value
        await MainActor.run {
            projects.removeAll { $0.id == id }
            if selectedID == id { selectedID = projects.first?.id }
        }
    }

    public func projectFolder(id: String) throws -> REProject {
        guard let project = projects.first(where: { $0.id == id }) else { throw REError.unknownProject }
        return project
    }

    private func loadedAnalysis(projectID: String) throws -> Analysis {
        guard let project = projects.first(where: { $0.id == projectID }), let analysis = project.analysis else {
            throw REError.unknownProject
        }
        return analysis
    }

    private func loadedAnalysisUnchecked(projectID: String) throws -> Analysis {
        try loadedAnalysis(projectID: projectID)
    }

    private func replace(projectID: String, with analysis: Analysis) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].analysis = analysis
    }

    private func mutatingProject(projectID: String, expectedRevision: Int,
                                 _ mutate: @escaping @Sendable (REProject) throws -> Analysis) async throws -> Analysis {
        let project = try await MainActor.run { try self.projectFolder(id: projectID) }
        let result = try await Task.detached(priority: .userInitiated) {
            try mutate(project)
        }.value
        try await MainActor.run {
            self.replace(projectID: projectID, with: result)
        }
        return result
    }

    private static nonisolated func importBinaryUnchecked(at url: URL, into root: URL) throws
        -> (folder: URL, analysis: Analysis)
    {
        let original = URL(fileURLWithPath: url.path).standardizedFileURL
        let attrs = try FileManager.default.attributesOfItem(atPath: original.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else {
            throw REError.notAFile(url.path)
        }
        guard let size = attrs[.size] as? Int else {
            throw REError.fileTooLarge(-1)
        }
        guard size <= 256 * 1024 * 1024 else {
            throw REError.fileTooLarge(size)
        }
        let proposed = original.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "_")
        var folder = root.appendingPathComponent(proposed, isDirectory: true)
        var suffix = 0
        while FileManager.default.fileExists(atPath: folder.path) {
            suffix += 1
            folder = root.appendingPathComponent("\(proposed)-\(suffix)", isDirectory: true)
        }
        // ProjectStore.create must make the project folder itself (it refuses an existing path),
        // so analyze a staged copy first and move the binary in once the folder exists.
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: staged)
        var analysis = try Analyzer.inspect(staged.path)
        let binary = folder.appendingPathComponent(original.lastPathComponent)
        analysis.binaryPath = binary.path
        try ProjectStore.create(analysis, to: folder.path)
        try FileManager.default.copyItem(at: staged, to: binary)
        return (folder: folder, analysis: analysis)
    }
}

// MARK: Values carried across the service boundary

public enum REEditOperation: Sendable, Equatable {
    case function(address: String, name: String?, comment: String?, signature: String?)
    case addressNote(address: String, comment: String?, label: String?)
    case variable(address: String, id: String, name: String?, type: String?)

    fileprivate var operation: ProjectStore.EditOperation {
        switch self {
        case let .function(address, name, comment, signature):
            .function(address: address, name: name, comment: comment, signature: signature)
        case let .addressNote(address, comment, label):
            .addressNote(address: address, comment: comment, label: label)
        case let .variable(address, id, name, type):
            .variable(address: address, id: id, name: name, type: type)
        }
    }
}

/// Result of dump forensics over one binary.
public struct REDumpReport: Sendable {
    public let modules: [DumpModule]
    public let core: DumpForensics.CoreDump?
}

/// Result of one script run: the final expression's value and the console lines it logged.
public struct REScriptResult: Sendable, Equatable {
    public let value: String
    public let output: [String]
}

public struct StringMatch: Codable, Sendable, Identifiable {
    public let id = UUID()
    public let record: StringRecord
    public let rank: Int
}

public struct Xref: Codable, Sendable, Equatable, Identifiable {
    public let id = UUID()
    public let from: String
    public let to: String
    public let kind: String
}

public enum REError: LocalizedError {
    case notAFile(String)
    case fileTooLarge(Int)
    case unknownProject
    case unknownFunction
    case noDecompilation(String)
    case ghidraNotConfigured
    case scriptTimedOut(Int)

    public var errorDescription: String? {
        switch self {
        case .scriptTimedOut(let seconds):
            "Script did not finish within \(seconds) s and was abandoned. Its background thread may stay busy until the process exits."
        case .notAFile(let path): "Not a regular file: \(path)"
        case .fileTooLarge(let size):
            "File too large: \(size / 1024 / 1024) MiB (import limit is 256 MiB)."
        case .unknownProject: "Unknown analysis project."
        case .unknownFunction: "Function not found in this project."
        case .noDecompilation(let detail): detail
        case .ghidraNotConfigured:
            "Ghidra is not configured. Set the Ghidra install home and the AxiomExport.java " +
            "script path in Settings → Reverse Engineering, then re-run analysis."
        }
    }
}

/// Lets exactly one of two racing completions resume a continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
