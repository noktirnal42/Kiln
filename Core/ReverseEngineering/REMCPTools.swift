import Foundation
import AxiomCore

public enum REMToolError: LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case unknownFunction(String)
    case encodingFailure
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "Unknown tool: \(name)"
        case .missingArgument(let arg): "Missing required argument: \(arg)"
        case .unknownFunction(let ref): "Function not found: \(ref)"
        case .encodingFailure: "Failed to encode result."
        case .unavailable(let detail): detail
        }
    }
}


/// One tool in the module's MCP surface, documented with name, description and
/// input schema (the same shape the module's manifest uses).
public struct REMCPToolDefinition: @unchecked Sendable {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]
    /// true when the tool has no side effects on any project or binary.
    public let readOnly: Bool
    /// true when the tool runs code or a program (a script, the debugger, an analysis engine) and needs execute-level approval.
    public let executes: Bool

    public init(name: String, description: String, inputSchema: [String: Any], readOnly: Bool, executes: Bool = false) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.readOnly = readOnly; self.executes = executes
    }
}

/// Dispatches the RE module's MCP tools onto `REService`. Results are returned
/// as JSON text; failures are thrown so an MCP transport can render them as
/// isError responses. Every tool is bounded by the engine's existing caps
/// (256 MiB imports, 64 MiB wordlists, per-signature hit caps, step budgets) so
/// no tool can unboundedly consume memory or time.
public enum REMCPTools {
    public static let definitions: [REMCPToolDefinition] = baseDefinitions + REWorkbenchTools.definitions

    static let baseDefinitions: [REMCPToolDefinition] = [
        REMCPToolDefinition(
            name: "import_binary",
            description: "Copy a binary into the app sandbox and run native inspection (file type, format, sections, strings, otool disassembly). 256 MiB import cap.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path to the binary file to import."],
                    "format": ["type": "string", "description": "Optional format hint; otherwise detected from the file."]
                ],
                "required": ["path"],
                "additionalProperties": false
            ],
            readOnly: false
        ),
        REMCPToolDefinition(
            name: "analyze_binary",
            description: "Run an analysis engine over an imported project and save recovered functions and references. engine=ghidra (default) also produces pseudocode; engine=radare2 is a fast fallback with call graph and basic blocks but no decompiler. Launches the analysis engine, never the target binary. Ghidra is bounded to 240 seconds; one analysis at a time. Analyst renames and comments are preserved.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"],
                    "engine": ["type": "string", "description": "ghidra (default) or radare2."]
                ],
                "required": ["project_id"],
                "additionalProperties": false
            ],
            readOnly: false
        ),
        REMCPToolDefinition(
            name: "analyze_function",
            description: "Return the function record (name, signature, callers, callees, analysis status) for one address or name in a project.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"],
                    "address": ["type": "string"],
                    "name": ["type": "string"]
                ],
                "required": ["project_id"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "get_disassembly",
            description: "Return a function's disassembly text as the engine produced it.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"],
                    "address": ["type": "string"]
                ],
                "required": ["project_id", "address"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "get_decompilation",
            description: "Return a function's decompiled pseudocode when the engine produced it (Ghidra analyses only; native otool inspection has none).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"],
                    "address": ["type": "string"]
                ],
                "required": ["project_id", "address"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "search_strings",
            description: "Search a project's extracted strings for a substring, case-sensitive or not.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"],
                    "pattern": ["type": "string"],
                    "case_sensitive": ["type": "boolean"]
                ],
                "required": ["project_id", "pattern"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "get_xrefs",
            description: "Cross-references to or from an address: outgoing calls (callees) and incoming callers.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"],
                    "address": ["type": "string"],
                    "direction": ["type": "string", "description": "'to' (callees), 'from' (callers), or omitted for both."]
                ],
                "required": ["project_id", "address"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "scan_crypto",
            description: "Scan a project's binary for known cryptographic constant tables (AES S-boxes, SHA/MD5 round constants, Blowfish P-array, ChaCha sigma, RSA exponent shapes, …). Evidence only — hits are leads, not conclusions.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"]
                ],
                "required": ["project_id"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "entropy_regions",
            description: "Sliding-window entropy profile of a project's binary; reports contiguous high-entropy regions that may be encrypted or compressed. Read-only.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "Project ID from re_import_binary."]
                ],
                "required": ["project_id"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "digest_file",
            description: "MD5, SHA-1, SHA-256, CRC-32 and byte statistics (entropy, printable ratio, dominant byte) for a project's binary. Read-only.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "Project ID from re_import_binary."]
                ],
                "required": ["project_id"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "wildcard_search",
            description: "Search a project's binary for a hex pattern with ?? byte wildcards (for example 41 42 ?? 44). Returns file offsets. Read-only.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "Project ID from re_import_binary."],
                    "pattern": ["type": "string", "description": "Hex bytes separated by spaces; ?? matches any byte."]
                ],
                "required": ["project_id", "pattern"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "scan_rules",
            description: "Compile YARA-subset rules (literals with nocase/wide/ascii/fullword, hex with wildcards, regex; and/or/not, at/in, N of them, filesize, uint8/16/32) and scan a project's binary. Syntax errors report their position. Read-only.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "Project ID from re_import_binary."],
                    "rules": ["type": "string", "description": "Rule source text."]
                ],
                "required": ["project_id", "rules"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "list_modules",
            description: "Find Mach-O/ELF modules embedded anywhere in a raw memory or flash dump and report each one's offset and size. Read-only; nothing is extracted.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "Project ID from re_import_binary."]
                ],
                "required": ["project_id"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "rename_function",
            description: "Change a function's analyst display name in the saved project. Does not modify the binary or Ghidra's own symbols.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "Project ID."],
                    "address": ["type": "string", "description": "Function address."],
                    "name": ["type": "string", "description": "New name."],
                    "expected_revision": ["type": "integer", "description": "The project's current revision (from re_open or any earlier edit result); a stale value is rejected so edits never overwrite newer work."]
                ],
                "required": ["project_id", "address", "name", "expected_revision"],
                "additionalProperties": false
            ],
            readOnly: false
        ),
        REMCPToolDefinition(
            name: "set_comment",
            description: "Set an analyst note on a function. An empty string clears it.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "Project ID."],
                    "address": ["type": "string", "description": "Function address."],
                    "comment": ["type": "string", "description": "Note text."],
                    "expected_revision": ["type": "integer", "description": "The project's current revision (from re_open or any earlier edit result); a stale value is rejected so edits never overwrite newer work."]
                ],
                "required": ["project_id", "address", "comment", "expected_revision"],
                "additionalProperties": false
            ],
            readOnly: false
        ),
        REMCPToolDefinition(
            name: "toggle_bookmark",
            description: "Add or remove an analyst bookmark on a function.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "Project ID."],
                    "address": ["type": "string", "description": "Function address."],
                    "expected_revision": ["type": "integer", "description": "The project's current revision (from re_open or any earlier edit result); a stale value is rejected so edits never overwrite newer work."]
                ],
                "required": ["project_id", "address", "expected_revision"],
                "additionalProperties": false
            ],
            readOnly: false
        ),
        REMCPToolDefinition(
            name: "undo_edit",
            description: "Revert the most recent analyst rename, comment or bookmark.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "Project ID."],
                    "expected_revision": ["type": "integer", "description": "The project's current revision (from re_open or any earlier edit result); a stale value is rejected so edits never overwrite newer work."]
                ],
                "required": ["project_id", "expected_revision"],
                "additionalProperties": false
            ],
            readOnly: false
        ),
        REMCPToolDefinition(
            name: "redo_edit",
            description: "Re-apply the most recently undone analyst edit.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "Project ID."],
                    "expected_revision": ["type": "integer", "description": "The project's current revision (from re_open or any earlier edit result); a stale value is rejected so edits never overwrite newer work."]
                ],
                "required": ["project_id", "expected_revision"],
                "additionalProperties": false
            ],
            readOnly: false
        ),
        REMCPToolDefinition(
            name: "scan_pointers",
            description: "Offsets of aligned 8-byte values in a plausible arm64 user-space pointer range (a heuristic lead list for memory dumps). Read-only.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string", "description": "Project ID."]
                ],
                "required": ["project_id"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "auto_decrypt",
            description: "Attempt XOR, RC4, AES (ECB/CBC/GCM), Blowfish and ChaCha20-Poly1305 decryption against typed keys, strings found in the binary, and/or a wordlist file. Results carry validator evidence and key fingerprints — never key material.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"],
                    "ciphers": ["type": "array", "items": ["type": "string"], "description": "Subset of xor, rc4, aes-128-ecb, aes-128-cbc, aes-256-ecb, aes-256-cbc, aes-128-gcm, aes-256-gcm, chacha20-poly1305, blowfish-64-ecb, blowfish-64-cbc."],
                    "keys": ["type": "array", "items": ["type": "string"], "description": "Typed key candidates."],
                    "wordlist": ["type": "string", "description": "Path to a wordlist file (64 MiB cap)."]
                ],
                "required": ["project_id"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "find_gadgets",
            description: "ROP/JOP gadget search over a project's disassembly: instruction sequences ending in the given mnemonic (default ret), bounded depth, deduplicated.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"],
                    "ending": ["type": "string", "description": "Terminating mnemonic prefix, default 'ret'."],
                    "depth": ["type": "integer", "description": "Max instructions per chain, default 5, capped at 16."]
                ],
                "required": ["project_id"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "carve_formats",
            description: "Carve embedded file-format signatures anywhere in a project's binary (executables, archives, compression, filesystems, documents, PCAP, …), plus packer fingerprints.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"]
                ],
                "required": ["project_id"],
                "additionalProperties": false
            ],
            readOnly: true
        )
        ,
        REMCPToolDefinition(
            name: "search_packages",
            description: "Look up an app package by name. source=aptoide returns APK results Kiln can download itself (direct_url, md5); apple returns App Store listings; google, apkpure and amazon return only a store search page to open. Only Aptoide and direct URLs can be fetched by re_download_package. Read-only: nothing is downloaded.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "App name or bundle identifier (or, for source=direct, an http(s) URL)."],
                    "source": ["type": "string", "description": "aptoide (default), apple, google, apkpure, amazon or direct."]
                ],
                "required": ["query"],
                "additionalProperties": false
            ],
            readOnly: true
        ),
        REMCPToolDefinition(
            name: "download_package",
            description: "Download an http(s) package file (APK, IPA, DEB, a native bundle archive or a binary) into Kiln's downloads folder and import it as a reverse-engineering project, returning the project_id. Pass the md5 from re_search_packages to verify the file; a mismatch discards it. Only fetch packages the user is authorized to analyze. The package is analyzed, never run.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "http or https link to the package file."],
                    "md5": ["type": "string", "description": "Optional expected MD5 (from re_search_packages) to verify the download."]
                ],
                "required": ["url"],
                "additionalProperties": false
            ],
            readOnly: false
        )
    ]

    /// Route one tool call onto the module service. Result JSON text; throwing
    /// produces an MCP isError response at the transport layer.
    @MainActor
    public static func call(tool name: String, arguments: [String: Any], service: REModule) async throws -> String {
        switch name {
        case "import_binary":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                throw REMToolError.missingArgument("path")
            }
            let analysis = try await service.importBinary(at: URL(fileURLWithPath: path))
            let projectID = await MainActor.run { service.projects.first { $0.analysis?.id == analysis.id }?.id }
            return try text(JSONSerialization.data(withJSONObject: summary(analysis, projectID: projectID)))
        case "search_packages":
            guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw REMToolError.missingArgument("query")
            }
            let sourceName = ((arguments["source"] as? String) ?? "aptoide").lowercased()
            guard let source = KilnPackageSource(rawValue: sourceName) else {
                throw REMToolError.missingArgument("source (aptoide, apple, google, apkpure, amazon or direct)")
            }
            let results = try await KilnPackageCatalog.search(source: source, query: query)
            let rows: [[String: Any]] = results.map { result in
                var row: [String: Any] = ["name": result.name, "detail": result.detail,
                                          "listing_url": result.listingURL.absoluteString,
                                          "can_download": result.directURL != nil]
                if let direct = result.directURL { row["direct_url"] = direct.absoluteString }
                if let md5 = result.md5 { row["md5"] = md5 }
                return row
            }
            return try text(JSONSerialization.data(withJSONObject: ["source": source.rawValue, "results": rows]))
        case "download_package":
            guard let urlText = arguments["url"] as? String, !urlText.isEmpty else {
                throw REMToolError.missingArgument("url")
            }
            let url = try KilnPackageCatalog.downloadableURL(urlText)
            let saved = try await KilnPackageCatalog.download(url, into: KilnPackageCatalog.defaultDownloadsFolder,
                                                              expectedMD5: arguments["md5"] as? String)
            let analysis = try await service.importBinary(at: saved)
            let projectID = await MainActor.run { service.projects.first { $0.analysis?.id == analysis.id }?.id }
            var result = summary(analysis, projectID: projectID)
            result["downloaded_from"] = url.absoluteString
            result["saved_as"] = saved.lastPathComponent
            return try text(JSONSerialization.data(withJSONObject: result))
        case "analyze_binary":
            let projectID = try projectArgument(arguments)
            let engine = ((arguments["engine"] as? String) ?? "ghidra").lowercased()
            guard engine == "ghidra" || engine == "radare2" else { throw REMToolError.missingArgument("engine (ghidra or radare2)") }
            let analysis = engine == "radare2" ? try await service.analyzeWithRadare2(projectID: projectID)
                                               : try await service.analyzeWithGhidra(projectID: projectID)
            return try text(JSONSerialization.data(withJSONObject: summary(analysis, projectID: projectID)))
        case "analyze_function":
            let (projectID, address, name) = try functionArguments(arguments)
            let analysis = try await service.analysis(projectID: projectID)
            let function = try functionInAnalysis(analysis: analysis, address: address, name: name)
            return try text(JSONSerialization.data(withJSONObject: functionRecord(function)))
        case "get_disassembly":
            let (projectID, address) = try addressArguments(arguments)
            let disassembly = try await service.disassembly(projectID: projectID, address: address)
            return try text(JSONSerialization.data(withJSONObject: ["disassembly": disassembly]))
        case "get_decompilation":
            let (projectID, address) = try addressArguments(arguments)
            let decompilation = try await service.decompilation(projectID: projectID, address: address)
            return try text(JSONSerialization.data(withJSONObject: ["decompilation": decompilation]))
        case "search_strings":
            let (projectID, pattern, caseSensitive) = try stringSearchArguments(arguments)
            let matches = try await service.searchStrings(projectID: projectID, pattern: pattern, caseSensitive: caseSensitive)
            return try text(JSONSerialization.data(withJSONObject: matches.map { ["id": $0.record.id, "offset": $0.record.offset, "value": $0.record.value] }))
        case "get_xrefs":
            let (projectID, address, direction) = try xrefArguments(arguments)
            let xrefs = try await service.xrefs(projectID: projectID, address: address, direction: direction)
            return try text(JSONSerialization.data(withJSONObject: xrefs.map { ["from": $0.from, "to": $0.to, "kind": $0.kind] }))
        case "scan_crypto":
            let projectID = try projectArgument(arguments)
            let hits = try await service.scanCrypto(projectID: projectID)
            return try text(JSONSerialization.data(withJSONObject: hits.map { ["offset": $0.offset, "algorithm": $0.algorithm, "kind": $0.kind, "confidence": $0.confidence] }))
        case "auto_decrypt":
            let (projectID, ciphers, keys, wordlistURL) = try decryptArguments(arguments)
            let results = try await service.autoDecrypt(projectID: projectID, ciphers: ciphers, keys: keys, wordlistURL: wordlistURL)
            return try text(JSONSerialization.data(withJSONObject: results.map { [
                "cipher": $0.cipher, "keySource": $0.keySource, "keyFingerprint": $0.keyFingerprint,
                "success": $0.success, "score": $0.score, "outputLength": $0.outputLength,
                "outputPreviewHex": $0.outputPreviewHex, "error": $0.error.map { $0 as Any } ?? NSNull(),
                "validators": $0.validators.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] }
            ]}))
        case "find_gadgets":
            let (projectID, ending, depth) = try gadgetArguments(arguments)
            let gadgets = try await service.findGadgets(projectID: projectID, ending: ending, depth: depth)
            return try text(JSONSerialization.data(withJSONObject: gadgets.map { ["address": $0.address, "instructions": $0.instructions] }))
        case "carve_formats":
            let projectID = try projectArgument(arguments)
            let hits = try await service.carveFormats(projectID: projectID)
            return try text(JSONSerialization.data(withJSONObject: hits.map { ["offset": $0.offset, "format": $0.format, "category": $0.category, "note": $0.note.map { $0 as Any } ?? NSNull(), ]}))
        case "rename_function", "set_comment", "toggle_bookmark", "undo_edit", "redo_edit":
            let projectID = try projectArgument(arguments)
            guard let revision = arguments["expected_revision"] as? Int else { throw REMToolError.missingArgument("expected_revision") }
            let updated: Analysis
            switch name {
            case "rename_function":
                guard let address = arguments["address"] as? String, let newName = arguments["name"] as? String else { throw REMToolError.missingArgument("address and name") }
                updated = try await service.editProject(projectID: projectID, expectedRevision: revision,
                                                        operations: [.function(address: address, name: newName, comment: nil, signature: nil)])
            case "set_comment":
                guard let address = arguments["address"] as? String, let comment = arguments["comment"] as? String else { throw REMToolError.missingArgument("address and comment") }
                updated = try await service.editProject(projectID: projectID, expectedRevision: revision,
                                                        operations: [.function(address: address, name: nil, comment: comment, signature: nil)])
            case "toggle_bookmark":
                guard let address = arguments["address"] as? String else { throw REMToolError.missingArgument("address") }
                updated = try await service.toggleBookmark(projectID: projectID, expectedRevision: revision, address: address)
            case "undo_edit":
                updated = try await service.undo(projectID: projectID, expectedRevision: revision)
            default:
                updated = try await service.redo(projectID: projectID, expectedRevision: revision)
            }
            return try text(JSONSerialization.data(withJSONObject: ["revision": updated.revision]))
        case "scan_pointers":
            let offsets = try await service.scanPointers(projectID: try projectArgument(arguments))
            return try text(JSONSerialization.data(withJSONObject: ["count": offsets.count, "offsets": offsets]))
        case "entropy_regions":
            let regions = try await service.entropyRegions(projectID: try projectArgument(arguments))
            return try text(JSONSerialization.data(withJSONObject: regions.map { ["offset": $0.offset, "length": $0.length, "meanEntropy": $0.meanEntropy] }))
        case "digest_file":
            let report = try await service.digestReport(projectID: try projectArgument(arguments))
            return try text(JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
        case "wildcard_search":
            guard let pattern = arguments["pattern"] as? String, !pattern.isEmpty else { throw REMToolError.missingArgument("pattern") }
            let offsets = try await service.wildcardSearch(projectID: try projectArgument(arguments), pattern: pattern)
            return try text(JSONSerialization.data(withJSONObject: ["count": offsets.count, "offsets": Array(offsets.prefix(500))]))
        case "scan_rules":
            guard let rules = arguments["rules"] as? String, !rules.isEmpty else { throw REMToolError.missingArgument("rules") }
            let matches = try await service.scanRules(projectID: try projectArgument(arguments), source: rules)
            return try text(JSONSerialization.data(withJSONObject: matches.map { match in
                ["rule": match.rule, "tags": match.tags, "meta": match.meta, "matches": match.strings.count]
            }))
        case "list_modules":
            let modules = try await service.dumpForensics(projectID: try projectArgument(arguments)).modules
            return try text(JSONSerialization.data(withJSONObject: modules.map { String(describing: $0) }))
        default:
            if let result = try await REWorkbenchTools.call(tool: name, arguments: arguments, service: service) { return result }
            throw REMToolError.unknownTool(name)
        }
    }

    // MARK: Arguments

    private static func projectArgument(_ arguments: [String: Any]) throws -> String {
        guard let projectID = arguments["project_id"] as? String, !projectID.isEmpty else {
            throw REMToolError.missingArgument("project_id")
        }
        return projectID
    }

    private static func addressArguments(_ arguments: [String: Any]) throws -> (String, String) {
        let projectID = try projectArgument(arguments)
        guard let address = arguments["address"] as? String, !address.isEmpty else {
            throw REMToolError.missingArgument("address")
        }
        return (projectID, address)
    }

    private static func functionArguments(_ arguments: [String: Any]) throws -> (projectID: String, address: String?, name: String?) {
        let projectID = try projectArgument(arguments)
        let address = arguments["address"] as? String
        let name = arguments["name"] as? String
        guard address != nil || name != nil else {
            throw REMToolError.missingArgument("address or name")
        }
        return (projectID, address, name)
    }

    private static func stringSearchArguments(_ arguments: [String: Any]) throws -> (projectID: String, pattern: String, caseSensitive: Bool) {
        let projectID = try projectArgument(arguments)
        guard let pattern = arguments["pattern"] as? String, !pattern.isEmpty else {
            throw REMToolError.missingArgument("pattern")
        }
        let caseSensitive = (arguments["case_sensitive"] as? Bool) ?? false
        return (projectID, pattern, caseSensitive)
    }

    private static func xrefArguments(_ arguments: [String: Any]) throws -> (projectID: String, address: String, direction: String?) {
        let (projectID, address) = try addressArguments(arguments)
        let direction = arguments["direction"] as? String
        return (projectID, address, direction)
    }

    private static func decryptArguments(_ arguments: [String: Any]) throws -> (projectID: String, ciphers: [String]?, keys: [String]?, wordlistURL: URL?) {
        let projectID = try projectArgument(arguments)
        let ciphers = (arguments["ciphers"] as? [String])?.filter { !$0.isEmpty }
        let keys = (arguments["keys"] as? [String])?.filter { !$0.isEmpty }
        let wordlistURL = (arguments["wordlist"] as? String).map { URL(fileURLWithPath: $0) }
        return (projectID, ciphers, keys, wordlistURL)
    }

    private static func gadgetArguments(_ arguments: [String: Any]) throws -> (projectID: String, ending: String?, depth: Int?) {
        let projectID = try projectArgument(arguments)
        let ending = arguments["ending"] as? String
        let depth = (arguments["depth"] as? Int).map { max(1, min(16, $0)) }
        return (projectID, ending, depth)
    }

    private static func functionInAnalysis(analysis: Analysis, address: String?, name: String?) throws -> FunctionRecord {
        if let address {
            guard let function = analysis.functions.first(where: { ProjectStore.normalizedAddress($0.address) == ProjectStore.normalizedAddress(address) }) else {
                throw REMToolError.unknownFunction(address)
            }
            return function
        }
        guard let name, let function = analysis.functions.first(where: { $0.name == name }) else {
            throw REMToolError.unknownFunction(name ?? "")
        }
        return function
    }

    // MARK: Result builders

    private static func functionRecord(_ function: FunctionRecord) -> [String: Any] {
        [
            "address": function.address,
            "name": function.name,
            "signature": function.signature,
            "engineSignature": function.engineSignature.map { $0 as Any } ?? NSNull(),
            "code": function.code,
            "assembly": function.assembly,
            "callers": function.callers,
            "callees": function.callees,
            "comment": function.comment,
            "blockCount": function.blocks.map { $0.count as Any } ?? NSNull(),
            "error": function.error.map { $0 as Any } ?? NSNull(),
        ]
    }

    private static func summary(_ analysis: Analysis, projectID: String? = nil) -> [String: Any] {
        [
            // The value every other re_* tool takes as `project_id`.
            "project_id": projectID ?? analysis.id,
            "id": analysis.id,
            "revision": analysis.revision,
            "binaryPath": analysis.binaryPath,
            "sha256": analysis.sha256,
            "size": analysis.size,
            "format": analysis.format,
            "engine": analysis.engine,
            "functionCount": analysis.functions.count,
            "stringCount": analysis.strings.count,
            "warnings": analysis.warnings,
            "bookmarks": analysis.bookmarks.map { $0 as Any } ?? NSNull(),
        ]
    }

    private static func text(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw REMToolError.encodingFailure
        }
        return text
    }
}

