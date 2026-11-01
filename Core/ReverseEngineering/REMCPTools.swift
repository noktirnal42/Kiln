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

    public init(name: String, description: String, inputSchema: [String: Any], readOnly: Bool) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.readOnly = readOnly
    }
}

/// Dispatches the RE module's MCP tools onto `REService`. Results are returned
/// as JSON text; failures are thrown so an MCP transport can render them as
/// isError responses. Every tool is bounded by the engine's existing caps
/// (256 MiB imports, 64 MiB wordlists, per-signature hit caps, step budgets) so
/// no tool can unboundedly consume memory or time.
public enum REMCPTools {
    public static let definitions: [REMCPToolDefinition] = [
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
        default:
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

