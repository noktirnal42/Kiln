import Foundation
import Testing
import AxiomCore
@testable import Kiln

/// In-memory GDB remote-serial-protocol peer: acknowledges each command packet and answers
/// with a correctly framed (checksummed) reply, so the real client wire path is exercised.
final class FakeProbe: GDBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var outgoing: [UInt8] = []
    private var seen: [String] = []
    private var closed = false
    private let reply: @Sendable (String) -> String

    init(reply: @escaping @Sendable (String) -> String) { self.reply = reply }

    var commands: [String] { lock.withLock { seen } }
    var isClosed: Bool { lock.withLock { closed } }

    func send(_ bytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        if bytes == [0x2b] { return }
        guard bytes.first == 0x24, let hash = bytes.lastIndex(of: 0x23) else { return }
        let command = String(decoding: bytes[1..<hash], as: UTF8.self)
        seen.append(command)
        outgoing.append(0x2b)
        outgoing += Self.frame(reply(command))
    }

    func receive() throws -> UInt8? {
        lock.lock()
        defer { lock.unlock() }
        return outgoing.isEmpty ? nil : outgoing.removeFirst()
    }

    func close() { lock.withLock { closed = true } }

    static func frame(_ payload: String) -> [UInt8] {
        let body = Array(payload.utf8)
        let sum = body.reduce(0) { ($0 + Int($1)) & 0xff }
        return [0x24] + body + [0x23] + Array(String(format: "%02x", sum).utf8)
    }
}

struct REDeviceBenchTests {
    private func auditURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-bench-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("bench-sessions.jsonl")
    }

    private func standardProbe() -> FakeProbe {
        FakeProbe { command in
            switch command {
            case "?": "T05"
            case "g": "0102030405060708"
            case "D": "OK"
            case let c where c.hasPrefix("m"): "deadbeef"
            default: ""
            }
        }
    }

    private func bench(probe: FakeProbe, audit: URL, allowRemote: Bool = false) -> REDeviceBench {
        REDeviceBench(auditLog: audit, allowRemoteHosts: allowRemote, transport: { _, _ in probe })
    }

    @Test func connectionIsRefusedWithoutConsent() async throws {
        let bench = bench(probe: standardProbe(), audit: auditURL())
        await #expect(throws: REDeviceBench.BenchError.consentRequired) {
            try await bench.connect(host: "127.0.0.1", port: 3333, consent: false)
        }
        #expect(await bench.isConnected == false)
    }

    @Test func remoteHostsAreRefusedByDefault() async throws {
        let bench = bench(probe: standardProbe(), audit: auditURL())
        await #expect(throws: REDeviceBench.BenchError.hostNotAllowed("192.168.1.50")) {
            try await bench.connect(host: "192.168.1.50", port: 3333, consent: true)
        }
    }

    @Test func remoteHostsWorkOnlyWhenEnabledAtConstruction() async throws {
        let bench = bench(probe: standardProbe(), audit: auditURL(), allowRemote: true)
        try await bench.connect(host: "192.168.1.50", port: 3333, consent: true)
        #expect(await bench.isConnected)
    }

    @Test func invalidPortIsRefused() async throws {
        let bench = bench(probe: standardProbe(), audit: auditURL())
        await #expect(throws: REDeviceBench.BenchError.invalidPort(0)) {
            try await bench.connect(host: "localhost", port: 0, consent: true)
        }
    }

    @Test func operationsFailBeforeConnecting() async throws {
        let bench = bench(probe: standardProbe(), audit: auditURL())
        await #expect(throws: REDeviceBench.BenchError.notConnected) {
            _ = try await bench.haltReason()
        }
    }

    @Test func haltReasonRegistersAndMemoryAreReadOverRealFraming() async throws {
        let probe = standardProbe()
        let bench = bench(probe: probe, audit: auditURL())
        try await bench.connect(host: "127.0.0.1", port: 3333, consent: true)

        #expect(try await bench.haltReason() == "T05")
        #expect(try await bench.readRegisters() == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(try await bench.readMemory(address: 0x1000, length: 4) == [0xde, 0xad, 0xbe, 0xef])
        #expect(probe.commands.contains("m1000,4"))
    }

    @Test func secondConnectionWhileOpenIsRefused() async throws {
        let bench = bench(probe: standardProbe(), audit: auditURL())
        try await bench.connect(host: "127.0.0.1", port: 3333, consent: true)
        await #expect(throws: REDeviceBench.BenchError.alreadyConnected) {
            try await bench.connect(host: "127.0.0.1", port: 3333, consent: true)
        }
    }

    @Test func disconnectDetachesCleanlyAndClosesTheTransport() async throws {
        let probe = standardProbe()
        let bench = bench(probe: probe, audit: auditURL())
        try await bench.connect(host: "127.0.0.1", port: 3333, consent: true)
        try await bench.disconnect()

        #expect(probe.commands.last == "D")
        #expect(probe.isClosed)
        #expect(await bench.isConnected == false)
    }

    @Test func auditLogRecordsSessionButNeverTargetBytes() async throws {
        let audit = auditURL()
        let bench = bench(probe: standardProbe(), audit: audit)
        try await bench.connect(host: "127.0.0.1", port: 3333, consent: true)
        _ = try await bench.readMemory(address: 0x1000, length: 4)
        try await bench.disconnect()

        let text = try String(contentsOf: audit, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"event\":\"opened\""))
        #expect(lines[1].contains("\"event\":\"closed\""))
        #expect(text.contains("\"kind\":\"gdb\""))
        #expect(text.contains("127.0.0.1:3333"))
        #expect(text.contains("\"bytesCaptured\":4"))
        // The bytes read from the target (0xdeadbeef) must never reach the log.
        #expect(!text.lowercased().contains("deadbeef"))
    }
}
