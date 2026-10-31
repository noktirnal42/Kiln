import Foundation
import AxiomCore

/// Consent-gated, read-only access to an external debug probe (OpenOCD, a QEMU gdbstub,
/// pyOCD) that the analyst runs separately and speaks GDB remote-serial-protocol.
///
/// Guardrails, all enforced here rather than left to the UI:
/// - No session opens without explicit consent.
/// - Only loopback hosts are accepted unless remote hosts are enabled at construction.
/// - Only observation is exposed: halt reason, registers, memory reads. Memory writes,
///   breakpoints and resume exist in AxiomCore but are deliberately not surfaced.
/// - Every session is appended to a JSONL audit log. The log records what was done
///   (target, byte counts, side effects), never the bytes read from the target.
public actor REDeviceBench {
    public enum BenchError: LocalizedError, Equatable {
        case consentRequired
        case hostNotAllowed(String)
        case invalidPort(Int)
        case alreadyConnected
        case notConnected

        public var errorDescription: String? {
            switch self {
            case .consentRequired: "Probe access needs your explicit consent; nothing was opened."
            case .hostNotAllowed(let host): "Host \(host) is not allowed. Only loopback probes (127.0.0.1, localhost, ::1) are enabled."
            case .invalidPort(let port): "Port \(port) is outside 1–65535."
            case .alreadyConnected: "A probe session is already open. Disconnect it first."
            case .notConnected: "No probe session is open."
            }
        }
    }

    public typealias TransportFactory = @Sendable (String, Int) throws -> GDBTransport

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    private let auditLog: URL
    private let allowRemoteHosts: Bool
    private let makeTransport: TransportFactory
    private var client: GDBRSPClient?
    private var bytesRead = 0

    /// The open session's audit record, nil when disconnected.
    public private(set) var activeRecord: DeviceSessionRecord?

    public init(
        auditLog: URL,
        allowRemoteHosts: Bool = false,
        transport: @escaping TransportFactory = { try GDBRSPClient.tcpTransport(host: $0, port: $1) }
    ) {
        self.auditLog = auditLog
        self.allowRemoteHosts = allowRemoteHosts
        self.makeTransport = transport
    }

    public var isConnected: Bool { client != nil }

    public func connect(host: String, port: Int, consent: Bool) throws {
        guard consent else { throw BenchError.consentRequired }
        guard client == nil else { throw BenchError.alreadyConnected }
        let normalized = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard allowRemoteHosts || Self.loopbackHosts.contains(normalized) else {
            throw BenchError.hostNotAllowed(host)
        }
        guard (1...65535).contains(port) else { throw BenchError.invalidPort(port) }

        let session = try GDBRSPClient(transport: try makeTransport(normalized, port),
                                       target: "\(normalized):\(port)", consent: consent)
        client = session
        bytesRead = 0
        activeRecord = session.record
        try appendAudit(session.record, event: "opened")
    }

    /// `?` — why the target is halted, for example `T05`.
    public func haltReason() throws -> String {
        try requireSession().haltReason()
    }

    public func readRegisters() throws -> [UInt8] {
        let bytes = try requireSession().readRegisters()
        bytesRead += bytes.count
        return bytes
    }

    public func readMemory(address: UInt64, length: Int) throws -> [UInt8] {
        let bytes = try requireSession().readMemory(address: address, length: length)
        bytesRead += bytes.count
        return bytes
    }

    /// Detaches cleanly, leaving the target running, and writes the closing audit entry.
    /// The session is cleared even if the probe does not answer the detach.
    public func disconnect() throws {
        let session = try requireSession()
        let detachError: Error?
        do {
            try session.detach()
            detachError = nil
        } catch {
            detachError = error
        }
        let closed = DeviceSessionRecord(
            kind: session.record.kind, target: session.record.target, started: session.record.started,
            ended: Date(), bytesCaptured: bytesRead, consent: session.record.consent,
            sideEffects: session.record.sideEffects,
            notes: detachError.map { ["detach failed: \($0.localizedDescription)"] } ?? []
        )
        client = nil
        activeRecord = nil
        try appendAudit(closed, event: "closed")
        if let detachError { throw detachError }
    }

    private func requireSession() throws -> GDBRSPClient {
        guard let client else { throw BenchError.notConnected }
        return client
    }

    private struct AuditLine: Encodable {
        let event: String
        let record: DeviceSessionRecord
    }

    private func appendAudit(_ record: DeviceSessionRecord, event: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(AuditLine(event: event, record: record))
        line.append(0x0a)
        try FileManager.default.createDirectory(at: auditLog.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: auditLog.path) {
            let handle = try FileHandle(forWritingTo: auditLog)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: auditLog, options: .atomic)
        }
    }
}
