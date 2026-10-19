import Foundation

/// One line of the agent audit log: who asked for what, what happened, how long it took. Arguments are summarized and
/// secrets (keys, passwords) are never written; results are not stored, only the outcome and the project revision reached.
public struct AuditEntry: Codable, Equatable, Sendable {
    public var time: Date
    public var operationId: String
    public var transport: String
    public var client: String?
    public var tool: String
    public var readOnly: Bool
    public var arguments: [String: String]
    /// "ok", "error", "cancelled" or "refused" (blocked by policy).
    public var outcome: String
    public var error: String?
    public var durationMs: Int
    public var project: String?
    public var resultRevision: Int?
    public init(time: Date = Date(), operationId: String, transport: String, client: String?, tool: String, readOnly: Bool, arguments: [String: String], outcome: String, error: String? = nil, durationMs: Int, project: String? = nil, resultRevision: Int? = nil) {
        self.time = time; self.operationId = operationId; self.transport = transport; self.client = client; self.tool = tool; self.readOnly = readOnly
        self.arguments = arguments; self.outcome = outcome; self.error = error; self.durationMs = durationMs; self.project = project; self.resultRevision = resultRevision
    }
}

/// Append-only JSON-lines audit log of agent operations (`audit.jsonl`, owner-only permissions, rotated at 8 MiB).
/// Default location `~/Library/Application Support/AxiomRE/audit`, overridable with `AXIOM_AUDIT_DIR`.
public final class AuditLog: @unchecked Sendable {
    public static let shared = AuditLog(directory: AuditLog.defaultDirectory())
    public static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["AXIOM_AUDIT_DIR"], !override.isEmpty { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AxiomRE/audit")
    }
    static let rotateBytes = 8 * 1024 * 1024
    public let directory: URL
    private let lock = NSLock()
    public var fileURL: URL { directory.appendingPathComponent("audit.jsonl") }
    public init(directory: URL) { self.directory = directory }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public func record(_ entry: AuditEntry) {
        lock.lock(); defer { lock.unlock() }
        guard let line = try? Self.encoder.encode(entry) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > Self.rotateBytes {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? fm.moveItem(at: fileURL, to: directory.appendingPathComponent("audit-\(stamp).jsonl"))
        }
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line + Data("\n".utf8))
    }

    /// Newest first. `total` counts entries matching the filters.
    public func read(limit: Int = 100, offset: Int = 0, tool: String? = nil, outcome: String? = nil) -> (total: Int, items: [AuditEntry]) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return (0, []) }
        var entries: [AuditEntry] = []
        for line in data.split(separator: 10) { if let entry = try? Self.decoder.decode(AuditEntry.self, from: Data(line)) { entries.append(entry) } }
        entries.reverse()
        if let tool { entries = entries.filter { $0.tool == tool } }
        if let outcome { entries = entries.filter { $0.outcome == outcome } }
        let start = max(0, offset)
        return (entries.count, Array(entries.dropFirst(start).prefix(max(1, min(limit, 1000)))))
    }

    /// Argument summary for the log: secret-looking names are redacted, long strings truncated, collections reduced to a count.
    public static func summarize(arguments: [String: Any]) -> [String: String] {
        let secretNames = ["password", "passphrase", "secret", "token", "key", "keys"]
        var out: [String: String] = [:]
        for (name, value) in arguments {
            let lower = name.lowercased()
            if secretNames.contains(lower) || lower.hasSuffix("key") || lower.contains("password") { out[name] = "[redacted]"; continue }
            switch value {
            case let text as String: out[name] = text.count > 200 ? String(text.prefix(200)) + "… (\(text.count) chars)" : text
            case let list as [Any]: out[name] = "[\(list.count) items]"
            case let map as [String: Any]: out[name] = "{\(map.count) fields}"
            default: out[name] = String(describing: value)
            }
        }
        return out
    }
}
