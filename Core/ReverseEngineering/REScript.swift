import Foundation
import JavaScriptCore
import AxiomCore

/// The `re` object in the Analyze scripting console. It exposes the same operations the `re_*` agent tools perform, over a snapshot of the
/// project taken when the script starts, so a script and an agent see identical data. Reads are immediate; `rename`, `comment` and
/// `annotate` are queued and applied as one undoable transaction after the script finishes without error.
@objc protocol REScriptExports: JSExport {
    func functions() -> NSArray
    func fn(_ addressOrName: String) -> NSDictionary
    func references(_ target: String) -> NSArray
    func strings(_ pattern: String) -> NSArray
    func bytes(_ address: String, _ length: Int) -> NSString
    func search(_ pattern: String) -> NSArray
    func cfg(_ address: String) -> NSDictionary
    func callGraph(_ address: String, _ depth: Int) -> NSDictionary
    func rename(_ address: String, _ name: String)
    func comment(_ address: String, _ text: String)
    func label(_ address: String, _ name: String)
}

final class REScriptAPI: NSObject, REScriptExports, @unchecked Sendable {
    let analysis: Analysis
    let index: REXrefIndex
    let binary: URL
    let map: REAddressMap
    private(set) var queued: [ProjectStore.EditOperation] = []
    static let maxQueued = 1000

    init(analysis: Analysis, index: REXrefIndex, binary: URL, map: REAddressMap) {
        self.analysis = analysis; self.index = index; self.binary = binary; self.map = map
    }

    private func find(_ key: String) -> FunctionRecord? {
        let normalized = ProjectStore.normalizedAddress(key)
        return analysis.functions.first { $0.name == key || ProjectStore.normalizedAddress($0.address) == normalized }
    }

    func functions() -> NSArray {
        analysis.functions.prefix(20_000).map { ["address": $0.address, "name": $0.name, "callers": $0.callers.count, "callees": $0.callees.count] as NSDictionary } as NSArray
    }
    func fn(_ addressOrName: String) -> NSDictionary {
        guard let f = find(addressOrName) else { return ["error": "function not found"] }
        return ["address": f.address, "name": f.name, "signature": f.signature, "comment": f.comment, "callers": f.callers, "callees": f.callees,
                "assembly": f.assembly, "code": f.code]
    }
    func references(_ target: String) -> NSArray {
        let rows: [REReference]
        if let address = REListing.address(target), index.functionStarts[address] != nil || target.lowercased().hasPrefix("0x") { rows = index.references(to: address) }
        else if let address = index.functionNames[target] { rows = index.references(to: address) }
        else { rows = index.references(toString: target) }
        return rows.prefix(500).map { $0.json as NSDictionary } as NSArray
    }
    func strings(_ pattern: String) -> NSArray {
        let needle = pattern.lowercased()
        return analysis.strings.filter { needle.isEmpty || $0.value.lowercased().contains(needle) }.prefix(500)
            .map { ["offset": $0.offset, "value": $0.value] as NSDictionary } as NSArray
    }
    func bytes(_ address: String, _ length: Int) -> NSString {
        guard length > 0, length <= 4096, let value = REListing.address(address) else { return "" }
        let offset = map.fileOffset(forAddress: value) ?? value
        return ((try? REHex.read(binary, offset: offset, length: length))?.hexString ?? "") as NSString
    }
    func search(_ pattern: String) -> NSArray {
        guard let parsed = try? REHex.pattern(pattern), let hits = try? REHex.search(binary, pattern: parsed, limit: 500) else { return [] }
        return hits.map { NSNumber(value: $0) } as NSArray
    }
    func cfg(_ address: String) -> NSDictionary {
        guard let f = find(address) else { return ["error": "function not found"] }
        return CFGBuilder.build(function: f, symbols: index.functionNames, names: index.functionStarts).json() as NSDictionary
    }
    func callGraph(_ address: String, _ depth: Int) -> NSDictionary {
        guard let f = find(address), let graph = CallGraph.build(analysis: analysis, root: f.address, depth: max(1, min(depth, 6))) else { return ["error": "function not found"] }
        return graph.json() as NSDictionary
    }
    func rename(_ address: String, _ name: String) { enqueue(.function(address: find(address)?.address ?? address, name: name, comment: nil, signature: nil)) }
    func comment(_ address: String, _ text: String) {
        if let f = find(address) { enqueue(.function(address: f.address, name: nil, comment: text, signature: nil)) }
        else { enqueue(.addressNote(address: address, comment: text, label: nil)) }
    }
    func label(_ address: String, _ name: String) { enqueue(.addressNote(address: address, comment: nil, label: name)) }
    private func enqueue(_ operation: ProjectStore.EditOperation) { if queued.count < Self.maxQueued { queued.append(operation) } }
}

public struct REScriptRun: Sendable {
    public let value: String
    public let output: [String]
    public let queuedEdits: Int
}

enum REScriptEngine {
    /// Runs on a dedicated thread; gives up after `timeout` (a runaway script keeps its thread until the process exits, as in the base console).
    static func run(source: String, api: REScriptAPI, binaryPath: String, timeout: Duration) async throws -> (REScriptRun, [ProjectStore.EditOperation]) {
        let encoded = (try? JSONSerialization.data(withJSONObject: [binaryPath])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let script = "var binary = \(encoded.dropFirst().dropLast());\n" + source
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeOnce()
            let worker = Thread {
                let console = ScriptConsole()
                console.install("re", api)
                let outcome: Result<(REScriptRun, [ProjectStore.EditOperation]), Error>
                switch console.run(script: script) {
                case .success(let (value, output)): outcome = .success((REScriptRun(value: value, output: output, queuedEdits: api.queued.count), api.queued))
                case .failure(let error): outcome = .failure(error)
                }
                if gate.claim() { continuation.resume(with: outcome) }
            }
            worker.stackSize = 8 * 1024 * 1024
            worker.start()
            Task.detached {
                try? await Task.sleep(for: timeout)
                if gate.claim() { continuation.resume(throwing: REError.scriptTimedOut(Int(timeout.components.seconds))) }
            }
        }
    }
}
