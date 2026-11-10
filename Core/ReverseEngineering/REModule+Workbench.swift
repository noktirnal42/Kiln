import Foundation
import AxiomCore

/// Service layer for the Analyze workbench: graphs, references, hex, patches, structures, diff, packages, findings, report, debugger and
/// scripting. The GUI and the `re_*` agent/MCP tools both call these, so they cannot drift apart.
extension REModule {
    // MARK: Context

    public func xrefIndex(projectID: String) async throws -> REXrefIndex {
        let analysis = try await self.analysis(projectID: projectID)
        if let cached = xrefCache[projectID], cached.revision == analysis.revision { return cached.index }
        let index = await Task.detached(priority: .userInitiated) { REXrefIndex.build(analysis) }.value
        xrefCache[projectID] = (analysis.revision, index)
        return index
    }

    public func addressMap(projectID: String) async throws -> REAddressMap {
        let analysis = try await self.analysis(projectID: projectID)
        return REAddressMap.parse(sections: analysis.sections, sliceBase: 0)
    }

    private func functionRecord(_ analysis: Analysis, _ key: String) throws -> FunctionRecord {
        let normalized = ProjectStore.normalizedAddress(key)
        guard let f = analysis.functions.first(where: { ProjectStore.normalizedAddress($0.address) == normalized || $0.name == key }) else { throw REError.unknownFunction }
        return f
    }

    // MARK: Graphs

    public func controlFlowGraph(projectID: String, function key: String) async throws -> ControlFlowGraph {
        let analysis = try await self.analysis(projectID: projectID)
        let index = try await xrefIndex(projectID: projectID)
        let f = try functionRecord(analysis, key)
        return CFGBuilder.build(function: f, symbols: index.functionNames, names: index.functionStarts)
    }

    public func callGraph(projectID: String, function key: String, direction: CallGraph.Direction = .both, depth: Int = 2) async throws -> CallGraph {
        let analysis = try await self.analysis(projectID: projectID)
        let f = try functionRecord(analysis, key)
        guard let graph = CallGraph.build(analysis: analysis, root: f.address, direction: direction, depth: max(1, min(depth, 6))) else { throw REError.unknownFunction }
        return graph
    }

    // MARK: References

    /// References to a function name, address or string text.
    public func references(projectID: String, target: String) async throws -> [REReference] {
        let index = try await xrefIndex(projectID: projectID)
        switch index.resolve(target) {
        case .function(let address, _): return index.references(to: REListing.address(address) ?? 0)
        case .string(_, let value): return index.references(toString: value)
        case .address(let address, _): return index.references(to: address)
        case nil: return index.references(toString: target)
        }
    }

    // MARK: Hex

    public func readHex(projectID: String, address: String? = nil, offset: UInt64? = nil, length: Int) async throws -> [REHexRow] {
        let binary = try projectFolder(id: projectID).binaryURL
        let map = try await addressMap(projectID: projectID)
        let start: UInt64
        if let offset { start = offset }
        else if let address, let value = REListing.address(address), let mapped = map.fileOffset(forAddress: value) { start = mapped }
        else { throw REError.invalidArgument("give a file offset, or an address backed by file contents") }
        let data = try REHex.read(binary, offset: start, length: length)
        return REHex.rows(data, startOffset: start, map: map)
    }

    public func searchBytes(projectID: String, pattern: String, limit: Int = 200) async throws -> [UInt64] {
        let binary = try projectFolder(id: projectID).binaryURL
        let parsed = try REHex.pattern(pattern)
        return try await Task.detached { try REHex.search(binary, pattern: parsed, limit: min(max(limit, 1), 2000)) }.value
    }

    // MARK: Workspace

    public func workspace(projectID: String) throws -> REWorkspace { REWorkspaceStore.load(try projectFolder(id: projectID).folder) }
    @discardableResult
    func mutateWorkspace(projectID: String, _ body: (inout REWorkspace) throws -> Void) throws -> REWorkspace {
        let folder = try projectFolder(id: projectID).folder
        var workspace = REWorkspaceStore.load(folder)
        try body(&workspace)
        try REWorkspaceStore.save(workspace, to: folder)
        return workspace
    }

    public func defineStructures(projectID: String, source: String) throws -> [REStructure] {
        try mutateWorkspace(projectID: projectID) { workspace in
            let parsed = try REStructureParser.parse(source, existing: workspace.structures)
            var merged = workspace.structures.filter { old in !parsed.contains { $0.name == old.name } }
            merged += parsed
            workspace.setStructures(merged)
        }.structures
    }
    public func deleteStructure(projectID: String, name: String) throws {
        try mutateWorkspace(projectID: projectID) { $0.setStructures($0.structures.filter { $0.name != name }) }
    }
    public func undoStructures(projectID: String) throws -> Bool { var ok = false; try mutateWorkspace(projectID: projectID) { ok = $0.undoStructures() }; return ok }
    public func redoStructures(projectID: String) throws -> Bool { var ok = false; try mutateWorkspace(projectID: projectID) { ok = $0.redoStructures() }; return ok }

    /// Retypes a decompiler variable to `struct Name *` (or a struct value), through the same undoable edit log as every other change.
    public func applyStructure(projectID: String, function: String, variableID: String, structure: String, asPointer: Bool = true, expectedRevision: Int) async throws -> Analysis {
        guard try workspace(projectID: projectID).structures.contains(where: { $0.name == structure }) else { throw REError.invalidArgument("unknown structure \(structure)") }
        let analysis = try await self.analysis(projectID: projectID)
        let f = try functionRecord(analysis, function)
        return try await editProject(projectID: projectID, expectedRevision: expectedRevision,
                                     operations: [.variable(address: f.address, id: variableID, name: nil, type: "struct \(structure)" + (asPointer ? " *" : ""))])
    }

    public func toggleAddressBookmark(projectID: String, address: String, note: String = "") throws -> Bool {
        let key = ProjectStore.normalizedAddress(address)
        guard UInt64(key, radix: 16) != nil else { throw REError.invalidArgument("address must be hexadecimal") }
        var added = false
        try mutateWorkspace(projectID: projectID) { workspace in
            if let i = workspace.bookmarks.firstIndex(where: { $0.address == key }) { workspace.bookmarks.remove(at: i) }
            else { workspace.bookmarks.append(REBookmark(address: key, note: note)); added = true }
        }
        return added
    }

    // MARK: Patching

    public func createPatch(projectID: String, address: String, hex: String? = nil, assembly: String? = nil, nopLength: Int? = nil, note: String = "") async throws -> REPatch {
        guard let value = REListing.address(address) else { throw REError.invalidArgument("address must be hexadecimal") }
        let analysis = try await self.analysis(projectID: projectID)
        let arch = REListing.architecture(format: analysis.format, slice: analysis.slice)
        let bytes: Data
        if let hex { bytes = Data(hex: hex) }
        else if let assembly { bytes = try await Task.detached { try REPatcher.assemble(assembly, architecture: arch) }.value }
        else if let nopLength { bytes = try REPatcher.nop(architecture: arch, length: nopLength) }
        else { throw REError.invalidArgument("give hex bytes, assembly source, or a NOP length") }
        let patch = try REPatcher.makePatch(binary: try projectFolder(id: projectID).binaryURL, map: try await addressMap(projectID: projectID), address: value, bytes: bytes, note: note, assembly: assembly)
        try mutateWorkspace(projectID: projectID) { workspace in
            for other in workspace.patches where other.fileOffset < patch.fileOffset + UInt64(patch.patchData.count) && patch.fileOffset < other.fileOffset + UInt64(other.patchData.count) {
                throw REError.invalidArgument("overlaps the patch at 0x\(other.address); remove it first")
            }
            workspace.patches.append(patch)
        }
        return patch
    }
    public func removePatch(projectID: String, id: String) throws { try mutateWorkspace(projectID: projectID) { $0.patches.removeAll { $0.id == id } } }

    /// Writes the patched copy. Default location: `<project>/patched/<name>.patched`. Never the original.
    public func exportPatched(projectID: String, destination: URL? = nil) async throws -> (url: URL, sha256: String) {
        let project = try projectFolder(id: projectID)
        let patches = try workspace(projectID: projectID).patches
        guard !patches.isEmpty else { throw REError.invalidArgument("no patches to apply") }
        let output = destination ?? project.folder.appendingPathComponent("patched").appendingPathComponent(project.binaryURL.lastPathComponent + ".patched")
        let hash = try await Task.detached { try REPatcher.apply(patches, to: project.binaryURL, output: output) }.value
        try mutateWorkspace(projectID: projectID) { for i in $0.patches.indices { $0.patches[i].applied = true } }
        return (output, hash)
    }

    // MARK: Diff

    public func diff(projectA: String, projectB: String) async throws -> REDiffResult {
        let a = try await analysis(projectID: projectA), b = try await analysis(projectID: projectB)
        return await Task.detached(priority: .userInitiated) { REDiff.compare(a, b) }.value
    }

    // MARK: Packages

    public func inspectPackage(at url: URL) async throws -> REPackageReport { try await Task.detached { try REPackage.inspect(url) }.value }

    /// Extracts one file from an IPA or APK and imports it as a project.
    public func importPackageEntry(archive: URL, entry: String) async throws -> Analysis {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-unpack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try await Task.detached { try REPackage.extract(archive, entry: entry, into: folder) }.value
        return try await importBinary(at: file)
    }

    // MARK: Findings and report

    @discardableResult
    public func addFinding(projectID: String, finding: REFinding) throws -> REFinding {
        guard !finding.title.isEmpty, finding.title.count <= 200, finding.summary.count <= 8000 else { throw REError.invalidArgument("title 1–200 and summary up to 8000 characters") }
        try mutateWorkspace(projectID: projectID) { $0.findings.append(finding) }
        return finding
    }
    public func removeFinding(projectID: String, id: String) throws { try mutateWorkspace(projectID: projectID) { $0.findings.removeAll { $0.id == id } } }

    /// Copies an image into the project's attachments and returns the stored name, for a finding's screenshot.
    public func addAttachment(projectID: String, from url: URL) throws -> String {
        let folder = REWorkspaceStore.attachmentsFolder(try projectFolder(id: projectID).folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString.prefix(8) + "-" + url.lastPathComponent
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(String(name)))
        return String(name)
    }

    public func exportReport(projectID: String, destination: URL? = nil, title: String? = nil) async throws -> REReport.Result {
        let project = try projectFolder(id: projectID)
        let analysis = try await self.analysis(projectID: projectID)
        let workspace = try workspace(projectID: projectID)
        let target = destination ?? project.folder.appendingPathComponent("reports", isDirectory: true)
        return try REReport.export(analysis: analysis, workspace: workspace, projectFolder: project.folder, destination: target, title: title)
    }

    // MARK: Debugger

    public func debugPlan(projectID: String, mode: REDebugPlan.Mode, addresses: [String], arguments: [String] = [], pid: Int32? = nil) async throws -> REDebugPlan {
        let analysis = try await self.analysis(projectID: projectID)
        let values = try addresses.map { text -> UInt64 in guard let v = REListing.address(text) else { throw REError.invalidArgument("bad address \(text)") }; return v }
        return try REDebugLink.plan(mode: mode, program: try projectFolder(id: projectID).binaryURL, breakpoints: values, arguments: arguments, pid: pid,
                                    architecture: analysis.slice)
    }
    /// Executes a plan. Launching runs the target: callers must have the analyst's approval.
    public func runDebugPlan(_ plan: REDebugPlan) async throws -> String {
        try await Task.detached { try REDebugLink.run(plan) }.value
    }

    // MARK: Scripting

    /// Runs a script with `re` (this API) and `axiom`. Queued renames and comments are applied as one undoable transaction.
    public func runWorkbenchScript(projectID: String, source: String, timeout: Duration = .seconds(10)) async throws -> REScriptRun {
        let analysis = try await self.analysis(projectID: projectID)
        let index = try await xrefIndex(projectID: projectID)
        let binary = try projectFolder(id: projectID).binaryURL
        let map = try await addressMap(projectID: projectID)
        let api = REScriptAPI(analysis: analysis, index: index, binary: binary, map: map)
        let (result, edits) = try await REScriptEngine.run(source: source, api: api, binaryPath: binary.path, timeout: timeout)
        if !edits.isEmpty {
            _ = try await editProject(projectID: projectID, expectedRevision: analysis.revision, operations: edits.map { op -> REEditOperation in
                switch op {
                case let .function(a, n, c, sg): .function(address: a, name: n, comment: c, signature: sg)
                case let .addressNote(a, c, l): .addressNote(address: a, comment: c, label: l)
                case let .variable(a, i, n, t): .variable(address: a, id: i, name: n, type: t)
                }
            })
        }
        return result
    }
}
