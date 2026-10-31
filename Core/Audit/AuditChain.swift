import Foundation
import CryptoKit

// Append-only, hash-chained audit log, ported from System5's audit.py (design and test intent,
// not code).
//
// Chain rule for event n:
//     body_n = canonical({seq, run_id, ts, type, payload})
//     hash_n = sha256(hash_{n-1} + body_n)
// Changing any historical row breaks its hash and every hash after it.
//
// Truncation is what a chain alone cannot catch: remove the newest rows and what remains is a
// shorter chain that verifies perfectly. So the head (highest seq and its hash) is also written to
// a separate file. Verification compares the two. An attacker must now alter the log AND the head
// consistently; deleting rows or rewriting the tail alone is reported.
//
// What this is not: protection against someone who can write both files. Agents get no tool that
// addresses either, and the tripwire layer is expected to flag any that names the path.

public struct AuditEvent: Codable, Sendable, Equatable {
    public let seq: Int
    public let runID: String?
    public let ts: String
    public let type: String
    public let payload: [String: AuditValue]
    public let prevHash: String
    public let hash: String

    enum CodingKeys: String, CodingKey {
        case seq, ts, type, payload, hash
        case runID = "run_id"
        case prevHash = "prev_hash"
    }

    /// The whole event as a canonical value, for bundles.
    var value: AuditValue {
        .object([
            "seq": .int(seq),
            "run_id": runID.map(AuditValue.string) ?? .null,
            "ts": .string(ts),
            "type": .string(type),
            "payload": .object(payload),
            "prev_hash": .string(prevHash),
            "hash": .string(hash),
        ])
    }
}

public struct AuditVerification: Sendable, Equatable {
    public let ok: Bool
    public let checked: Int
    /// A row whose hash, link or numbering is wrong.
    public let brokenSeq: Int?
    /// Rows removed from the end (or from the middle, by numbering), as opposed to altered.
    public let truncated: Bool
    /// The event count the recorded head expects; nil when no head was ever recorded.
    public let expectedEvents: Int?
    public let headHash: String?
    /// 1-based line of the log that is not a valid event, when there is one.
    public let unreadableLine: Int?
}

public struct AuditSummary: Sendable, Equatable {
    public let events: Int
    public let headHash: String
    public let truncated: Bool
    public let expectedEvents: Int?
}

public enum AuditError: LocalizedError, Equatable {
    case unreadableTail(line: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadableTail(let line):
            "Audit log line \(line) is not a valid event. Appending would extend a broken chain, so nothing was written."
        }
    }
}

/// A self-verifying export of the whole chain.
public struct AuditBundle: Codable, Sendable, Equatable {
    public let generatedAt: String
    public let seqFrom: Int
    public let seqTo: Int
    public let count: Int
    public let chainOK: Bool
    public let headHash: String
    public let sha256: String
    /// HMAC-SHA256 over the canonical events, hex; empty when unsigned.
    public let signature: String
    public let events: [AuditEvent]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at", seqFrom = "seq_from", seqTo = "seq_to", count
        case chainOK = "chain_ok", headHash = "head_hash", sha256, signature, events
    }

    /// Re-derives everything from the events themselves: the chain links, the digest and, when a
    /// key is given, the signature. A bundle that claims `chainOK` proves nothing until this holds.
    public func isSelfConsistent(signKey: Data? = nil) -> Bool {
        guard chainIsValid else { return false }
        let canonical = AuditValue.array(events.map(\.value)).canonical
        guard AuditChain.sha256Hex(canonical) == sha256 else { return false }
        if let signKey {
            return !signature.isEmpty && AuditChain.signatureMatches(signature, over: canonical, key: signKey)
        }
        return true
    }

    private var chainIsValid: Bool {
        var previous = AuditChain.genesis
        for (index, event) in events.enumerated() {
            let body = AuditChain.body(seq: event.seq, runID: event.runID, ts: event.ts,
                                       type: event.type, payload: event.payload)
            guard event.seq == index + 1, event.prevHash == previous,
                  event.hash == AuditChain.hash(previous: previous, body: body) else { return false }
            previous = event.hash
        }
        return true
    }
}

public actor AuditChain {
    public static let genesis = String(repeating: "0", count: 64)

    private let logURL: URL
    private let headURL: URL
    private let clock: @Sendable () -> Date
    private var tail: (seq: Int, hash: String)?

    /// Set when the last attempt to record the head failed. The event itself is already
    /// committed; only the truncation check is degraded, and verification reports the gap.
    public private(set) var headWriteError: String?

    /// - Parameters:
    ///   - directory: holds `audit-events.jsonl`.
    ///   - headDirectory: where `audit-head.json` goes. Defaults to `directory`; a different
    ///     location makes consistent tampering harder.
    public init(directory: URL, headDirectory: URL? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.logURL = directory.appendingPathComponent("audit-events.jsonl")
        self.headURL = (headDirectory ?? directory).appendingPathComponent("audit-head.json")
        self.clock = clock
    }

    // MARK: Appending

    /// Appends one event. Serialized by the actor, so concurrent callers still get a linear chain.
    ///
    /// The chain tail is cached after the first append. If the log is edited from outside while
    /// this instance is alive, later appends continue from the cached tail and `verify()` reports
    /// the break.
    @discardableResult
    public func append(type: String, payload: [String: AuditValue] = [:], runID: String? = nil) throws -> AuditEvent {
        let current = try loadTail()
        let seq = current.seq + 1
        let ts = Self.timestamp(clock())
        let body = Self.body(seq: seq, runID: runID, ts: ts, type: type, payload: payload)
        let event = AuditEvent(seq: seq, runID: runID, ts: ts, type: type, payload: payload,
                               prevHash: current.hash, hash: Self.hash(previous: current.hash, body: body))
        try appendLine(event)
        tail = (seq, event.hash)
        recordHead(seq: seq, hash: event.hash)
        return event
    }

    // MARK: Checking

    /// Size and head of the chain without rehashing it, so it is cheap enough to poll. It still
    /// catches truncation, since that only needs the head comparison.
    public func summary() throws -> AuditSummary {
        let (events, _) = try readEvents()
        let seq = events.last?.seq ?? 0
        let digest = events.last?.hash ?? Self.genesis
        let report = truncationReport(seq: seq, hash: digest)
        return AuditSummary(events: seq, headHash: digest, truncated: report.truncated,
                            expectedEvents: report.expected)
    }

    /// Recomputes the whole chain and compares its head with the recorded one.
    /// `brokenSeq` means a row was altered; `truncated` means rows were removed.
    public func verify() throws -> AuditVerification {
        let (events, unreadable) = try readEvents()
        var previous = Self.genesis
        for (index, event) in events.enumerated() {
            let body = Self.body(seq: event.seq, runID: event.runID, ts: event.ts,
                                 type: event.type, payload: event.payload)
            if event.prevHash != previous || event.hash != Self.hash(previous: previous, body: body) {
                return AuditVerification(ok: false, checked: events.count, brokenSeq: event.seq,
                                         truncated: false, expectedEvents: nil, headHash: nil,
                                         unreadableLine: unreadable)
            }
            if event.seq != index + 1 {
                // Hashes link up but the numbering skips: something was taken out of the middle.
                return AuditVerification(ok: false, checked: events.count, brokenSeq: event.seq,
                                         truncated: true, expectedEvents: nil, headHash: nil,
                                         unreadableLine: unreadable)
            }
            previous = event.hash
        }
        let report = truncationReport(seq: events.last?.seq ?? 0, hash: previous)
        return AuditVerification(ok: !report.truncated && unreadable == nil, checked: events.count,
                                 brokenSeq: nil, truncated: report.truncated,
                                 expectedEvents: report.expected, headHash: previous,
                                 unreadableLine: unreadable)
    }

    /// A self-verifying export of the whole chain, optionally signed with HMAC-SHA256.
    public func export(signKey: Data? = nil) throws -> AuditBundle {
        let (events, _) = try readEvents()
        let verification = try verify()
        let canonical = AuditValue.array(events.map(\.value)).canonical
        let signature = signKey.map { Self.sign(canonical, key: $0) } ?? ""
        return AuditBundle(
            generatedAt: Self.timestamp(clock()),
            seqFrom: events.first?.seq ?? 0, seqTo: events.last?.seq ?? 0, count: events.count,
            chainOK: verification.ok, headHash: verification.headHash ?? Self.genesis,
            sha256: Self.sha256Hex(canonical), signature: signature, events: events
        )
    }

    // MARK: Hashing (shared with bundle verification)

    static func body(seq: Int, runID: String?, ts: String, type: String, payload: [String: AuditValue]) -> String {
        AuditValue.object([
            "seq": .int(seq),
            "run_id": runID.map(AuditValue.string) ?? .null,
            "ts": .string(ts),
            "type": .string(type),
            "payload": .object(payload),
        ]).canonical
    }

    static func hash(previous: String, body: String) -> String { sha256Hex(previous + body) }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sign(_ text: String, key: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison via CryptoKit rather than comparing hex strings.
    static func signatureMatches(_ signature: String, over text: String, key: Data) -> Bool {
        var bytes: [UInt8] = []
        var index = signature.startIndex
        while index < signature.endIndex {
            guard let next = signature.index(index, offsetBy: 2, limitedBy: signature.endIndex),
                  let byte = UInt8(signature[index..<next], radix: 16) else { return false }
            bytes.append(byte)
            index = next
        }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: Data(text.utf8),
                                                      using: SymmetricKey(data: key))
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: Storage

    private func loadTail() throws -> (seq: Int, hash: String) {
        if let tail { return tail }
        let (events, unreadable) = try readEvents()
        if let unreadable { throw AuditError.unreadableTail(line: unreadable) }
        let loaded = events.last.map { ($0.seq, $0.hash) } ?? (0, Self.genesis)
        tail = loaded
        return loaded
    }

    /// Events up to the first line that is not a valid event, and that line's number if there is one.
    private func readEvents() throws -> (events: [AuditEvent], unreadableLine: Int?) {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return ([], nil) }
        let data = try Data(contentsOf: logURL)
        let decoder = JSONDecoder()
        var events: [AuditEvent] = []
        var lineNumber = 0
        for raw in data.split(separator: 0x0a, omittingEmptySubsequences: true) {
            lineNumber += 1
            guard let event = try? decoder.decode(AuditEvent.self, from: Data(raw)) else {
                return (events, lineNumber)
            }
            events.append(event)
        }
        return (events, nil)
    }

    private func appendLine(_ event: AuditEvent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(event)
        line.append(0x0a)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: logURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        }
    }

    private struct Head: Codable { let seq: Int; let hash: String }

    private func readHead() -> Head? {
        guard let data = try? Data(contentsOf: headURL) else { return nil }
        return try? JSONDecoder().decode(Head.self, from: data)
    }

    /// Writes the head atomically, owner-only. Never throws: an event already committed must not
    /// be lost to a head-write failure. The failure is kept in `headWriteError` instead.
    private func recordHead(seq: Int, hash: String) {
        let fileManager = FileManager.default
        let temporary = headURL.deletingLastPathComponent().appendingPathComponent(".\(headURL.lastPathComponent).tmp")
        do {
            try fileManager.createDirectory(at: headURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Head(seq: seq, hash: hash)).write(to: temporary)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: headURL.path) {
                _ = try fileManager.replaceItemAt(headURL, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: headURL)
            }
            headWriteError = nil
        } catch {
            try? fileManager.removeItem(at: temporary)
            headWriteError = error.localizedDescription
        }
    }

    private func truncationReport(seq: Int, hash: String) -> (truncated: Bool, expected: Int?) {
        guard let recorded = readHead() else { return (false, nil) }
        if seq < recorded.seq { return (true, recorded.seq) }
        // Same length but a different head: the newest row was rewritten rather than removed.
        if seq == recorded.seq, !recorded.hash.isEmpty, hash != recorded.hash { return (true, recorded.seq) }
        return (false, recorded.seq)
    }
}
