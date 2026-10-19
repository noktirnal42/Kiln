import Foundation

/// radare2 provider: fast independent disassembly, call graph and basic blocks (no decompiler).
/// Never executes the target; radare2 is asked for static analysis only (`aa`).
extension Analyzer {
    public static let defaultRadare2 = "/opt/homebrew/bin/r2"

    public static func radare2Available(_ r2: String = defaultRadare2) -> Bool { FileManager.default.isExecutableFile(atPath: r2) }

    public static func radare2(_ path: String, arch: String? = nil, r2: String = defaultRadare2) throws -> Analysis {
        guard radare2Available(r2) else { throw AxiomError.message("radare2 not found at \(r2). Install it with `brew install radare2`.") }
        var base = try inspect(path, arch: arch)
        let resolution = try resolveSlice(path, arch: arch)
        defer { resolution.cleanup() }
        let script = "aa; echo AXIOM_AFL; aflj; echo AXIOM_PDF; pdfj @@F; echo AXIOM_BB; afbj @@F"
        // stderr is merged into the captured output; only JSON lines are consumed below.
        let output = try ProcessRunner.run(r2, ["-2", "-q", "-e", "bin.relocs.apply=true", "-c", script, resolution.path], timeout: 240)
        let parsed = parseRadare2(output)
        base.functions = parsed.functions
        base.engine = "radare2 · native analysis"
        base.warnings = ["radare2 provides disassembly, calls and basic blocks. Pseudocode requires Ghidra."] + parsed.warnings
        return base
    }

    /// Exposed for tests: converts radare2's JSON stream (`aflj`, `pdfj @@F`, `afbj @@F`) into function records.
    public static func parseRadare2(_ output: String) -> (functions: [FunctionRecord], warnings: [String]) {
        enum Section { case none, functions, disassembly, blocks }
        var section = Section.none
        var listing: [[String: Any]] = []; var disassemblies: [[String: Any]] = []; var blockSets: [[[String: Any]]] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            switch line {
            case "AXIOM_AFL": section = .functions; continue
            case "AXIOM_PDF": section = .disassembly; continue
            case "AXIOM_BB": section = .blocks; continue
            default: break
            }
            guard line.first == "[" || line.first == "{", let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            switch section {
            case .functions: listing = json as? [[String: Any]] ?? []
            case .disassembly: if let object = json as? [String: Any] { disassemblies.append(object) }
            case .blocks: if let array = json as? [[String: Any]] { blockSets.append(array) }
            case .none: break
            }
        }
        func hex(_ value: Any?) -> String? { (value as? NSNumber).map { String($0.uint64Value, radix: 16) } }
        func clean(_ name: String) -> String { name.hasPrefix("sym.") ? String(name.dropFirst(4)) : name }
        var records: [String: FunctionRecord] = [:]; var order: [String] = []
        for item in listing.prefix(20_000) {
            guard let address = hex(item["addr"]), let name = item["name"] as? String else { continue }
            var record = FunctionRecord(address: address, name: clean(name), signature: item["signature"] as? String ?? "")
            record.blocks = []
            records[address] = record; order.append(address)
        }
        for function in disassemblies {
            guard let address = hex(function["addr"]), var record = records[address], let ops = function["ops"] as? [[String: Any]] else { continue }
            var lines: [String] = []; var lastSource = ""
            for (index, op) in ops.enumerated() {
                if index >= 4096 { lines.append("[instruction listing truncated]"); break }
                guard let opAddress = hex(op["addr"]), let text = op["disasm"] as? String else { continue }
                if let source = op["addrline"] as? [String: Any], let file = source["file"] as? String, let number = source["line"] {
                    let label = URL(fileURLWithPath: file).lastPathComponent + ":\(number)"
                    if label != lastSource { lines.append("; " + label); lastSource = label }
                }
                lines.append(opAddress + "  " + text)
                if let type = op["type"] as? String, type == "call" || type == "ucall", let target = hex(op["jump"]), target != address, record.callees.count < 1000, !record.callees.contains(target) { record.callees.append(target) }
            }
            record.assembly = lines.joined(separator: "\n")
            records[address] = record
        }
        for (address, record) in records { for callee in record.callees { if var target = records[callee], target.callers.count < 1000, !target.callers.contains(address) { target.callers.append(address); records[callee] = target } } }
        for set in blockSets {
            guard let entry = set.compactMap({ hex($0["addr"]) }).first, var record = records[entry] ?? records.values.first(where: { function in set.contains { hex($0["addr"]) == function.address } }) else { continue }
            record.blocks = set.compactMap { block in
                guard let address = hex(block["addr"]) else { return nil }
                return BasicBlock(address: address, destinations: [hex(block["jump"]), hex(block["fail"])].compactMap { $0 })
            }
            records[record.address] = record
        }
        var warnings: [String] = []
        if listing.count > 20_000 { warnings.append("Function listing limited to 20,000 entries.") }
        if listing.isEmpty { warnings.append("radare2 found no functions; the format may need explicit analysis options.") }
        let sorted = order.sorted { (UInt64($0, radix: 16) ?? 0) < (UInt64($1, radix: 16) ?? 0) }
        return (sorted.compactMap { records[$0] }, warnings)
    }
}
