import Foundation
import CryptoKit

// The agent tool surface shared by the MCP server, the ACP agent and (via the same table) the CLI: one definition per tool and
// one dispatcher, so every transport exposes identical, validated operations. Moved out of the CLI so it can be unit-tested.

public func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
public func decodeHexOrThrow(_ text: String) throws -> Data {
    guard let data = Hex.decode(text) else { throw AxiomError.message("Salt must be even-length hex.") }
    return data
}

public enum AgentTools {
    struct ExtractedModule: Encodable { let bytes: Int; let sha256: String; let hex: String }
    struct PacketListing: Encodable { let linkType: UInt32; let packets: [CapturePacket] }
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func required(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else { throw AxiomError.message("Missing string argument: \(key)") }; return value
    }

    /// Tools that change a project (or create one). Everything else is read-only; transports use this for annotations and policy.
    public static let mutating: Set<String> = ["rename_function", "set_comment", "annotate_address", "change_variable", "toggle_bookmark", "undo_edit", "redo_edit", "inspect_binary", "analyze_binary",
                                              "propose_edit", "withdraw_proposal", "cancel_operation"]
    /// Tools that change a project's analysis directly; refused under a propose-only policy (agents use `propose_edit` instead).
    public static let directEdits: Set<String> = ["rename_function", "set_comment", "annotate_address", "change_variable", "toggle_bookmark", "undo_edit", "redo_edit"]
    /// Test hook: extra tools handled before the table lookup (never populated in production).
    nonisolated(unsafe) static var extra: [String: ([String: Any]) throws -> String] = [:]
    public static func isReadOnly(_ name: String) -> Bool { !mutating.contains(name) }

    public static let definitions: [(String, String, [String: String], [String])] = [
        ("inspect_binary", "Inspect binary metadata, strings and native Mach-O assembly without executing it.", ["path":"string", "project":"string", "arch":"string"], ["path"]),
        ("analyze_binary", "Analyze with Ghidra (default; decompiles, up to 240 seconds) or engine=radare2 (disassembly, calls, blocks; no decompiler).", ["path":"string", "project":"string", "ghidraHome":"string", "scriptPath":"string", "engine":"string", "arch":"string"], ["path", "project"]),
        ("open_project", "Read project metadata and revision.", ["project":"string"], ["project"]),
        ("list_functions", "Page through functions with optional search, offset and limit (max 500).", ["project":"string", "query":"string", "offset":"integer", "limit":"integer"], ["project"]),
        ("get_function", "Read assembly, decompilation, callers, callees and notes by address.", ["project":"string", "address":"string"], ["project", "address"]),
        ("list_strings", "Page through printable strings by file offset with optional search.", ["project":"string", "query":"string", "offset":"integer", "limit":"integer"], ["project"]),
        ("rename_function", "Change analyst display name in saved Axiom project; does not modify Ghidra symbols or binary.", ["project":"string", "address":"string", "name":"string", "expectedRevision":"integer"], ["project", "address", "name", "expectedRevision"]),
        ("annotate_address", "Set or clear (empty string) an analyst comment and/or label on any address in a saved Axiom project; logged for review and undo. Does not modify the binary or engine data.", ["project":"string", "address":"string", "comment":"string", "label":"string", "expectedRevision":"integer"], ["project", "address", "expectedRevision"]),
        ("change_variable", "Record an analyst rename and/or retype of a parameter or local (engine variable id from the live worker) in a saved Axiom project; empty string clears that part. Logged and undoable; applied to the engine when live analysis runs.", ["project":"string", "address":"string", "id":"string", "name":"string", "type":"string", "expectedRevision":"integer"], ["project", "address", "id", "expectedRevision"]),
        ("list_annotations", "List analyst address comments and labels stored in a saved Axiom project. Read-only.", ["project":"string"], ["project"]),
        ("set_comment", "Set analyst note in saved Axiom project with revision conflict protection.", ["project":"string", "address":"string", "comment":"string", "expectedRevision":"integer"], ["project", "address", "comment", "expectedRevision"]),
        ("list_bookmarks", "List analyst-bookmarked functions.", ["project":"string"], ["project"]),
        ("toggle_bookmark", "Add or remove an analyst bookmark on a function, with revision conflict protection.", ["project":"string", "address":"string", "expectedRevision":"integer"], ["project", "address", "expectedRevision"]),
        ("list_changes", "List the analyst edit log (renames and comments, oldest first) and the undone edits that can be redone.", ["project":"string"], ["project"]),
        ("undo_edit", "Revert the most recent analyst rename or comment, with revision conflict protection.", ["project":"string", "expectedRevision":"integer"], ["project", "expectedRevision"]),
        ("redo_edit", "Re-apply the most recently undone analyst edit, with revision conflict protection.", ["project":"string", "expectedRevision":"integer"], ["project", "expectedRevision"]),
        ("scan_crypto", "Scan file bytes for known cryptographic constant tables (AES S-boxes, SHA/MD5/Keccak constants, Blowfish P-array, ChaCha sigma) and RSA public-key shapes. Read-only static analysis; hits are evidence, not conclusions.", ["path":"string"], ["path"]),
        ("carve_signatures", "Locate embedded file-format signatures (executables, archives, filesystems, compression, media, databases, captures) at any offset in the file. Read-only.", ["path":"string"], ["path"]),
        ("entropy_regions", "Sliding-window entropy profile of the file; reports contiguous high-entropy regions that may be encrypted or compressed. Read-only.", ["path":"string"], ["path"]),
        ("auto_decrypt", "Attempt standard decryption transforms (XOR, AES ECB/CBC/GCM, ChaCha20-Poly1305) on the file using analyst-supplied keys and/or a wordlist file. Returns ranked candidates with structural evidence; keys are used in memory only and results carry fingerprints, never key material. Read-only; the file is never executed.", ["path":"string", "keys":"array", "wordlist":"string", "ciphers":"array", "maxLines":"integer"], ["path"]),
        ("scan_rules", "Compile a rule file (YARA-syntax subset: literals with nocase/wide/ascii/fullword, hex with wildcards/jumps/alternations, regex; conditions with and/or/not, at/in, N of them|($a,$b), filesize, uint8/16/32) and scan the file with it. Read-only.", ["path":"string", "rules":"string"], ["path", "rules"]),
        ("flashdump_info", "Flash-dump import: hash, entropy regions, carved signatures, fixed-offset structures, and labeled layout leads (erased regions, boot-image position). Read-only static analysis of the file.", ["path":"string"], ["path"]),
        ("kdf_derive", "Replay a key-derivation function on recovered parameters (pbkdf2-sha1/sha256/sha512, hkdf-sha256) and return the derived key hex. On-device only; the caller supplies parameters recovered during analysis. Read-only computation.", ["algorithm":"string", "password":"string", "saltHex":"string", "iterations":"integer", "keyLength":"integer"], ["algorithm", "password", "saltHex", "iterations", "keyLength"]),
        ("find_gadgets", "Search project disassembly for ROP/JOP gadget chains ending in a mnemonic (default ret). Analysis over engine output; read-only.", ["project":"string", "ending":"string", "depth":"integer", "limit":"integer"], ["project"]),
        ("convert_base", "Convert an integer between base 2, 8, 10 and 16.", ["value":"string", "from":"integer", "to":"integer"], ["value", "from", "to"]),
        ("wildcard_search", "Search file bytes for a hex pattern with ?? byte wildcards (e.g. \"41 42 ?? 44\"). Read-only.", ["path":"string", "pattern":"string"], ["path", "pattern"]),
        ("digest_file", "Digests (MD5/SHA-1/SHA-256), CRC-32 and byte statistics (entropy, printable ratio, dominant byte) for a file. Read-only.", ["path":"string"], ["path"]),
        ("list_modules", "Dump forensics: find Mach-O/ELF modules embedded anywhere in a raw memory/flash dump and compute each one's real on-disk extent by walking its own headers. Read-only.", ["path":"string"], ["path"]),
        ("list_core_regions", "Dump forensics: read the memory-region table of an ELF or Mach-O core-dump file (as declared by the container; no inference about heap/stack). Returns null for non-core files. Read-only.", ["path":"string"], ["path"]),
        ("extract_module", "Dump forensics: slice one module out of a dump at a given offset/size (from list_modules). Read-only on the source; writes nothing unless the caller saves the returned bytes.", ["path":"string", "offset":"integer", "size":"integer"], ["path", "offset", "size"]),
        ("scan_pointers", "Dump forensics: offsets of aligned 8-byte little-endian values that fall in a plausible pointer range (default arm64 user space). A heuristic lead list, not a claim. Read-only.", ["path":"string", "rangeLow":"string", "rangeHigh":"string"], ["path"]),
        ("list_packets", "Capture analysis: parse a classic (non-pcapng) pcap file's global header and every packet's timestamp/length. Read-only; never opens a live interface.", ["path":"string"], ["path"]),
        ("dissect_packet", "Capture analysis: shallow Ethernet/IPv4/TCP/UDP dissection of one packet by index (from list_packets). Read-only.", ["path":"string", "index":"integer"], ["path", "index"]),
        ("list_flows", "Capture analysis: groups a pcap's packets into TCP/UDP 4-tuple flows (both directions together) with packet/byte counts. Read-only.", ["path":"string"], ["path"]),
        ("list_operations", "List running and recently finished agent operations (operation id, tool, state, timing). Read-only.", [:], []),
        ("cancel_operation", "Cancel a running operation by its operation id (also returned in every tool result's _meta). Long-running tools (auto_decrypt, analyze_binary, wordlist/KDF sweeps) stop promptly and their engine processes are terminated.", ["operationId":"string"], ["operationId"]),
        ("list_audit", "List the agent audit log, newest first: who ran which tool, with summarized arguments (secrets redacted), outcome and timing. Read-only.", ["limit":"integer", "offset":"integer", "tool":"string", "outcome":"string"], []),
        ("propose_edit", "Propose an analyst edit for human review instead of applying it. kind: rename_function (name), set_comment (comment), set_signature (signature), annotate_address (comment and/or label), change_variable (variableId, name and/or type). A rationale is required; cite evidence addresses. Proposals sharing a groupId are accepted together or not at all. The analyst accepts or rejects in the app or CLI.", ["project":"string", "kind":"string", "address":"string", "name":"string", "comment":"string", "label":"string", "type":"string", "variableId":"string", "signature":"string", "rationale":"string", "evidence":"array", "groupId":"string"], ["project", "kind", "address", "rationale"]),
        ("list_proposals", "List edit proposals in a project with their status (pending, accepted, rejected, withdrawn, failed). Read-only.", ["project":"string", "status":"string"], ["project"]),
        ("withdraw_proposal", "Withdraw one of your pending proposals.", ["project":"string", "proposalId":"string"], ["project", "proposalId"])
    ]

    public static func call(_ name: String, _ args: [String: Any]) throws -> String {
        if let handler = extra[name] { return try handler(args) }
        guard let definition = definitions.first(where: { $0.0 == name }) else { throw AxiomError.message("Unknown tool: \(name)") }
        for key in args.keys { guard let type = definition.2[key] else { throw AxiomError.message("Unexpected argument: \(key)") }; if type == "string" && !(args[key] is String) { throw AxiomError.message("Expected string: \(key)") }; if type == "array" && !(args[key] is [Any]) { throw AxiomError.message("Expected array: \(key)") }; if type == "integer", let number = args[key] as? NSNumber { guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue) else { throw AxiomError.message("Expected integer: \(key)") } } else if type == "integer" { throw AxiomError.message("Expected integer: \(key)") } }
        for key in definition.3 { guard args[key] != nil else { throw AxiomError.message("Missing argument: \(key)") } }
        if name == "scan_crypto" { return try encode(CryptoIdentifier.scan(try ToolBelt.readData(required(args, "path")))) }
        if name == "carve_signatures" { let data = try ToolBelt.readData(required(args, "path")); return try encode(FormatIdentifier.scan(data)) }
        if name == "entropy_regions" { return try encode(EntropyScanner.regions(in: try ToolBelt.readData(required(args, "path")))) }
        if name == "auto_decrypt" {
            let data = try ToolBelt.readData(required(args, "path"))
            var options = AutoDecryptor.Options()
            if let names = args["ciphers"] as? [Any] { options.ciphers = try names.map { guard let text = $0 as? String, let cipher = Cipher(rawValue: text) else { throw AxiomError.message("Unknown cipher: \($0). Use: \([String](Cipher.allCases.map(\.rawValue)).joined(separator: ", "))") } ; return cipher } }
            if let lines = (args["maxLines"] as? NSNumber)?.intValue { options.maxWordlistEntries = min(max(1, lines), 1_000_000) }
            let keys = (args["keys"] as? [Any])?.compactMap { $0 as? String } ?? []
            var wordlist: Data?; var wordlistName = "wordlist"
            if let wordlistPath = args["wordlist"] as? String { wordlist = try ToolBelt.readData(wordlistPath, limit: ToolBelt.wordlistLimit); wordlistName = URL(fileURLWithPath: wordlistPath).lastPathComponent }
            let results = try AutoDecryptor.run(data: data, typedKeys: keys, wordlist: wordlist, wordlistName: wordlistName, options: options)
            return try encode(results)
        }
        if name == "convert_base" {
            guard let from = args["from"] as? Int, let to = args["to"] as? Int else { throw AxiomError.message("from and to must be integers.") }
            return try encode(["result": try UtilityBelt.convert(required(args, "value"), from: from, to: to)])
        }
        if name == "wildcard_search" { return try encode(try UtilityBelt.wildcardSearch(try ToolBelt.readData(required(args, "path")), pattern: required(args, "pattern"))) }
        if name == "digest_file" { return try encode(UtilityBelt.digestReport(try ToolBelt.readData(required(args, "path")))) }
        if name == "list_core_regions" { return try encode(DumpForensics.parseCore(try ToolBelt.readData(required(args, "path")))) }
        if name == "list_modules" { return try encode(DumpForensics.listModules(try ToolBelt.readData(required(args, "path")))) }
        if name == "extract_module" {
            guard let offset = args["offset"] as? Int, let size = args["size"] as? Int else { throw AxiomError.message("offset and size must be integers.") }
            let data = try DumpForensics.extractModule(try ToolBelt.readData(required(args, "path")), offset: offset, size: size)
            return try encode(ExtractedModule(bytes: data.count, sha256: sha256Hex(data), hex: UtilityBelt.dataToHex(data.prefix(256))))
        }
        if name == "scan_pointers" {
            let data = try ToolBelt.readData(required(args, "path"))
            var range = DumpForensics.arm64UserSpaceRange
            if let low = args["rangeLow"] as? String, let high = args["rangeHigh"] as? String,
               let loValue = UInt64(low.hasPrefix("0x") ? String(low.dropFirst(2)) : low, radix: 16),
               let hiValue = UInt64(high.hasPrefix("0x") ? String(high.dropFirst(2)) : high, radix: 16), loValue <= hiValue {
                range = loValue...hiValue
            }
            return try encode(DumpForensics.scanPointers(data, range: range))
        }
        if name == "list_packets" {
            let (linkType, packets) = try PcapReader.packets(in: try ToolBelt.readData(required(args, "path")))
            return try encode(PacketListing(linkType: linkType, packets: packets))
        }
        if name == "dissect_packet" {
            guard let index = args["index"] as? Int else { throw AxiomError.message("index must be an integer.") }
            let data = try ToolBelt.readData(required(args, "path"))
            let (_, packets) = try PcapReader.packets(in: data)
            guard packets.indices.contains(index) else { throw AxiomError.message("No packet at index \(index); capture has \(packets.count).") }
            return try encode(PcapReader.dissectEthernet(data, at: packets[index].offset, length: packets[index].capturedLength))
        }
        if name == "list_flows" {
            let data = try ToolBelt.readData(required(args, "path"))
            let (_, packets) = try PcapReader.packets(in: data)
            return try encode(StreamReassembly.flows(data, packets: packets))
        }
        if name == "flashdump_info" {
            let data = try ToolBelt.readData(required(args, "path"))
            return try encode(FlashDump.analyze(data, path: required(args, "path")))
        }
        if name == "kdf_derive" {
            guard let saltHex = args["saltHex"] as? String else { throw AxiomError.message("Missing string argument: saltHex") }
            let salt = try decodeHexOrThrow(saltHex)
            guard let iterations = (args["iterations"] as? NSNumber)?.intValue, let keyLength = (args["keyLength"] as? NSNumber)?.intValue else {
                throw AxiomError.message("iterations and keyLength must be integers.")
            }
            let key = try KDFReplay.derive(KDFReplayParameters(algorithm: required(args, "algorithm"), password: required(args, "password"),
                                                               salt: salt, iterations: iterations, keyLength: keyLength))
            return try encode(["algorithm": args["algorithm"] as? String ?? "", "keyHex": Hex.encode(key)])
        }
        if name == "scan_rules" {
            let data = try ToolBelt.readData(required(args, "path"))
            let source = try String(contentsOf: URL(fileURLWithPath: required(args, "rules")), encoding: .utf8)
            return try encode(RuleScanner.scan(data, rules: try RuleScanner.compile(source)))
        }
        if name == "inspect_binary" {
            let analysis = try Analyzer.inspect(required(args, "path"), arch: args["arch"] as? String); if let project = args["project"] as? String { try ProjectStore.create(analysis, to: project) }; return try encode(analysis)
        }
        if name == "analyze_binary", (args["engine"] as? String) == "radare2" {
            let project = try required(args, "project"); let path = try required(args, "path")
            let arch = args["arch"] as? String
            let initial = try Analyzer.inspect(path, arch: arch); try ProjectStore.create(initial, to: project)
            let result = try Analyzer.radare2(path, arch: arch)
            let analysis = try ProjectStore.replace(result, to: project, expectedID: initial.id, expectedRevision: initial.revision, preserveAnnotations: true)
            return try encode(analysis)
        }
        if name == "analyze_binary", let engine = args["engine"] as? String, engine != "ghidra" { throw AxiomError.message("Unknown engine: \(engine). Use ghidra or radare2.") }
        if name == "analyze_binary" {
            let project = try required(args, "project")
            let home = (args["ghidraHome"] as? String) ?? ProcessInfo.processInfo.environment["GHIDRA_HOME"] ?? ""
            let scripts = (args["scriptPath"] as? String) ?? ProcessInfo.processInfo.environment["AXIOM_SCRIPT_PATH"] ?? ""
            guard !home.isEmpty, !scripts.isEmpty else { throw AxiomError.message("Configure GHIDRA_HOME and AXIOM_SCRIPT_PATH or pass engine arguments.") }
            guard !FileManager.default.fileExists(atPath: project) else { throw AxiomError.message("Choose a new project folder to preserve existing work.") }
            let analysis = try Analyzer.analyzeProject(required(args, "path"), project: project, home: home, scriptPath: scripts, arch: args["arch"] as? String)
             return try encode(analysis)
        }
        if let handler = extra[name] { return try handler(args) }
        if name == "list_operations" {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            return String(decoding: try encoder.encode(["operations": (OperationContext.current?.registry ?? .shared).list()]), as: UTF8.self)
        }
        if name == "cancel_operation" {
            let id = try required(args, "operationId")
            guard OperationContext.current?.id != id else { throw AxiomError.message("An operation cannot cancel itself.") }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["operationId": id, "cancelled": (OperationContext.current?.registry ?? .shared).cancel(id)] as [String: Any], options: [.sortedKeys]), as: UTF8.self)
        }
        if name == "list_audit" {
            let limit = min(1000, max(1, (args["limit"] as? Int) ?? 100)); let offset = max(0, (args["offset"] as? Int) ?? 0)
            let page = AuditLog.shared.read(limit: limit, offset: offset, tool: args["tool"] as? String, outcome: args["outcome"] as? String)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let items = try JSONSerialization.jsonObject(with: try encoder.encode(page.items))
            return String(decoding: try JSONSerialization.data(withJSONObject: ["total": page.total, "offset": offset, "items": items] as [String: Any], options: [.sortedKeys]), as: UTF8.self)
        }
        if name == "propose_edit" {
            let evidence = (args["evidence"] as? [Any])?.compactMap { $0 as? String } ?? []
            let proposal = try ProposalStore.propose(project: required(args, "project"), kind: required(args, "kind"), address: required(args, "address"), name: args["name"] as? String,
                                                     comment: args["comment"] as? String, label: args["label"] as? String, type: args["type"] as? String, variableId: args["variableId"] as? String,
                                                     signature: args["signature"] as? String, rationale: required(args, "rationale"), evidence: evidence,
                                                     source: EditSource.current ?? "agent", groupId: args["groupId"] as? String)
            return try encode(["proposalId": proposal.id, "status": proposal.status.rawValue, "summary": proposal.summary])
        }
        if name == "list_proposals" {
            let status = try (args["status"] as? String).map { text -> EditProposal.Status in guard let s = EditProposal.Status(rawValue: text) else { throw AxiomError.message("Unknown status \(text).") }; return s }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let items = try JSONSerialization.jsonObject(with: try encoder.encode(try ProposalStore.list(project: required(args, "project"), status: status)))
            return String(decoding: try JSONSerialization.data(withJSONObject: ["items": items] as [String: Any], options: [.sortedKeys]), as: UTF8.self)
        }
        if name == "withdraw_proposal" {
            try ProposalStore.withdraw(project: required(args, "project"), id: required(args, "proposalId"))
            return try encode(["withdrawn": try required(args, "proposalId")])
        }
        let project = try required(args, "project"); let analysis = try ProjectStore.load(project)
        let query = (args["query"] as? String) ?? ""
        let offset = max(0, (args["offset"] as? Int) ?? 0); let limit = min(500, max(1, (args["limit"] as? Int) ?? 100))
        switch name {
        case "open_project": return try encode(["id": analysis.id, "revision": String(analysis.revision), "path": analysis.binaryPath, "engine": analysis.engine, "format": analysis.format, "sha256": analysis.sha256, "functions": String(analysis.functions.count)])
        case "find_gadgets":
            let depth = (args["depth"] as? Int) ?? 5
            let limit = min(max(1, (args["limit"] as? Int) ?? 256), 1024)
            let ending = (args["ending"] as? String) ?? "ret"
            let gadgets = GadgetSearch.search(functions: analysis.functions, depth: depth, ending: ending, limit: limit)
            // Gadget is Codable but not a plist type; bridge through JSON for the MCP envelope.
            let items = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gadgets))
            let value: [String: Any] = ["total": gadgets.count, "ending": ending, "items": items]
            return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        case "list_functions":
            let matches = analysis.functions.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.address.contains(query) }
            let rows = matches.dropFirst(offset).prefix(limit).map { ["address": $0.address, "name": $0.name, "signature": $0.signature] }
            let value: [String: Any] = ["total": matches.count, "offset": offset, "items": rows, "revision": analysis.revision]; return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        case "get_function":
            guard let function = analysis.functions.first(where: { $0.address == args["address"] as? String }) else { throw AxiomError.message("Unknown function address.") }; return try encode(function)
        case "list_strings": return try encode(Array(analysis.strings.filter { query.isEmpty || $0.value.localizedCaseInsensitiveContains(query) }.dropFirst(offset).prefix(limit)))
        case "rename_function", "set_comment":
            guard let revision = args["expectedRevision"] as? Int else { throw AxiomError.message("expectedRevision must be an integer.") }
            let edited = try ProjectStore.edit(project, expectedRevision: revision, address: required(args, "address"), name: name == "rename_function" ? required(args, "name") : nil, comment: name == "set_comment" ? required(args, "comment") : nil)
            return try encode(["revision": edited.revision])
        case "annotate_address":
            guard let revision = args["expectedRevision"] as? Int else { throw AxiomError.message("expectedRevision must be an integer.") }
            guard args["comment"] is String || args["label"] is String else { throw AxiomError.message("Provide comment and/or label (an empty string clears).") }
            let edited = try ProjectStore.annotate(project, expectedRevision: revision, address: required(args, "address"), comment: args["comment"] as? String, label: args["label"] as? String)
            return try encode(["revision": edited.revision])
        case "change_variable":
            guard let revision = args["expectedRevision"] as? Int else { throw AxiomError.message("expectedRevision must be an integer.") }
            guard args["name"] is String || args["type"] is String else { throw AxiomError.message("Provide name and/or type (an empty string clears).") }
            let edited = try ProjectStore.changeVariable(project, expectedRevision: revision, address: required(args, "address"), id: required(args, "id"), name: args["name"] as? String, type: args["type"] as? String)
            return try encode(["revision": edited.revision])
        case "list_annotations":
            let variables = (analysis.variableChanges ?? [:]).mapValues { $0.mapValues { change in ["name": change.name ?? "", "type": change.type ?? ""] } }
            let value: [String: Any] = ["comments": analysis.addressComments ?? [:], "labels": analysis.addressLabels ?? [:], "variables": variables, "revision": analysis.revision]
            return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        case "list_bookmarks":
            let marks = Set(analysis.bookmarks ?? [])
            let rows = analysis.functions.filter { marks.contains(ProjectStore.normalizedAddress($0.address)) }.map { ["address": $0.address, "name": $0.name] }
            let value: [String: Any] = ["total": rows.count, "items": rows, "revision": analysis.revision]; return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        case "list_changes": return try encode(["edits": analysis.edits ?? [], "redoable": [AnalystEdit](analysis.undone ?? [])] as [String: [AnalystEdit]])
        case "toggle_bookmark", "undo_edit", "redo_edit":
            guard let revision = args["expectedRevision"] as? Int else { throw AxiomError.message("expectedRevision must be an integer.") }
            let updated = name == "toggle_bookmark" ? try ProjectStore.toggleBookmark(project, expectedRevision: revision, address: required(args, "address"))
                : name == "undo_edit" ? try ProjectStore.undo(project, expectedRevision: revision) : try ProjectStore.redo(project, expectedRevision: revision)
            return try encode(["revision": updated.revision])
        default: throw AxiomError.message("Unsupported operation.")
        }
    }
}
