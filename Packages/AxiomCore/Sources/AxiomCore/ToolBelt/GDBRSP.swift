import Foundation

// GDB remote-serial-protocol client (docs/KALI_METASPLOIT_PARITY.md T7): speaks the documented
// GDB RSP wire format so Axiom can drive external probe daemons (OpenOCD, QEMU gdbstub, pyOCD)
// that the analyst starts separately. Original implementation from the protocol spec; no GPL
// code or binaries involved. Transport is abstracted so tests run against an in-memory stub.

public protocol GDBTransport: Sendable {
    func send(_ bytes: [UInt8]) throws
    func receive() throws -> UInt8?
    func close()
}

/// Framed RSP connection: `$<payload>#<cksum>` packets with `+` acknowledgements, `}` escapes,
/// and run-length decoding. A checksum-failed packet is negatively acknowledged and retried
/// once before erroring — silently accepting corrupt probe data is not an option here.
public final class GDBRSPClient {
    public private(set) var record: DeviceSessionRecord
    private let transport: GDBTransport
    private let maxPacket = 16384

    public init(transport: GDBTransport, target: String, consent: Bool) throws {
        guard consent else { throw AxiomError.message("Probe I/O requires explicit consent; refused without it.") }
        self.transport = transport
        record = DeviceSessionRecord(kind: "gdb", target: target, sideEffects: "halt/step/memory-read on the attached target")
    }

    /// TCP transport for the usual OpenOCD/QEMU endpoints.
    public static func tcpTransport(host: String, port: Int) throws -> GDBTransport {
        GDBTCPTransport(host: host, port: port)
    }

    /// Sends one command packet and returns the decoded response payload (no framing).
    public func exchange(_ command: String, retries: Int = 1) throws -> String {
        let payload = Array(command.utf8)
        for attempt in 0...retries {
            var packet: [UInt8] = [0x24]   // $
            var checksum = 0
            for byte in payload { packet.append(byte); checksum = (checksum + Int(byte)) & 0xff }
            packet.append(0x23)            // #
            packet += [hexDigit(checksum >> 4), hexDigit(checksum & 0xf)]
            try transport.send(packet)
            guard try readAck() else {
                if attempt < retries { continue }
                throw AxiomError.message("Probe negatively acknowledged \"\(command)\" after retry.")
            }
            let response = try readPacket()
            try transport.send([0x2b])     // + acknowledge the response
            return response
        }
        throw AxiomError.message("unreachable")
    }

    /// `?` — why the target is halted, e.g. "T05" (signal 5 = SIGTRAP).
    public func haltReason() throws -> String { try exchange("?") }

    /// `g` — all registers as one hex blob (layout is target-defined; decoded by the caller).
    public func readRegisters() throws -> [UInt8] {
        let response = try exchange("g")
        return try hexBytes(response, name: "registers")
    }

    /// `m<addr>,<len>` — memory read. Returns the raw bytes; refuses absurd lengths.
    public func readMemory(address: UInt64, length: Int) throws -> [UInt8] {
        guard length > 0, length <= 65536 else { throw AxiomError.message("Memory read length must be 1…65536.") }
        let response = try exchange("m\(String(address, radix: 16)),\(String(length, radix: 16))")
        if response.hasPrefix("E") { throw AxiomError.message("Probe refused memory read: \(response).") }
        return try hexBytes(response, name: "memory")
    }

    /// `M<addr>,<len>:<hex>` — memory write. Side-effecting; recorded in the session audit.
    public func writeMemory(address: UInt64, bytes: [UInt8]) throws {
        guard !bytes.isEmpty, bytes.count <= 65536 else { throw AxiomError.message("Memory write length must be 1…65536.") }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let response = try exchange("M\(String(address, radix: 16)),\(String(bytes.count, radix: 16)):\(hex)")
        guard response == "OK" else { throw AxiomError.message("Probe refused memory write: \(response).") }
        record = DeviceSessionRecord(kind: record.kind, target: record.target, started: record.started,
                                     ended: record.ended, bytesCaptured: record.bytesCaptured, consent: record.consent,
                                     sideEffects: record.sideEffects + "; memory write @0x\(String(address, radix: 16)) len \(bytes.count)",
                                     notes: record.notes)
    }

    /// `Z0/z0` — software breakpoint set/remove at an address.
    public func setBreakpoint(address: UInt64) throws { try breakpoint(address: address, set: true) }
    public func clearBreakpoint(address: UInt64) throws { try breakpoint(address: address, set: false) }
    private func breakpoint(address: UInt64, set: Bool) throws {
        let command = "\(set ? "Z0" : "z0"),\(String(address, radix: 16)),1"
        let response = try exchange(command)
        guard response == "OK" || response.isEmpty else { throw AxiomError.message("Probe refused breakpoint: \(response).") }
    }

    /// `c` / `s` — resume or single-step; RSP sends no reply until the target halts again.
    public func continueExecution() throws { try transport.send(packet("c")); acknowledgeIncoming() }
    public func step() throws { try transport.send(packet("s")); acknowledgeIncoming() }

    /// `D` — detach cleanly, leaving the target running.
    public func detach() throws {
        _ = try exchange("D")
        transport.close()
        record = DeviceSessionRecord(kind: record.kind, target: record.target, started: record.started,
                                     ended: Date(), bytesCaptured: record.bytesCaptured, consent: record.consent,
                                     sideEffects: record.sideEffects, notes: record.notes)
    }

    // MARK: framing

    private func packet(_ command: String) -> [UInt8] {
        var packet: [UInt8] = [0x24]
        var checksum = 0
        for byte in Array(command.utf8) { packet.append(byte); checksum = (checksum + Int(byte)) & 0xff }
        packet.append(0x23)
        packet += [hexDigit(checksum >> 4), hexDigit(checksum & 0xf)]
        return packet
    }

    private func readAck() throws -> Bool {
        guard let ack = try transport.receive() else { throw AxiomError.message("Probe closed the connection mid-acknowledge.") }
        if ack == 0x2b { return true }
        if ack == 0x2d { return false }
        throw AxiomError.message("Expected probe acknowledge, got 0x\(String(ack, radix: 16)).")
    }

    private func acknowledgeIncoming() {
        // Target's stop reply is read lazily by the next exchange(); ack it now if present.
        _ = try? transport.receive()
        try? transport.send([0x2b])
    }

    private func readPacket() throws -> String {
        var byte: UInt8?
        repeat { byte = try transport.receive() } while byte != nil && byte != 0x24
        guard byte == 0x24 else { throw AxiomError.message("Probe closed the connection before a packet arrived.") }
        var payload: [UInt8] = []
        var checksumBytes: [UInt8] = []
        var escaped = false
        while payload.count < maxPacket {
            guard let received = try transport.receive() else { throw AxiomError.message("Probe closed the connection mid-packet.") }
            if received == 0x23 { break }                       // #
            if escaped { payload.append(received ^ 0x20); escaped = false; continue }
            if received == 0x7d { escaped = true; continue }    // } escape
            if received == 0x2a && !payload.isEmpty {           // * run-length
                guard let repeatCount = try transport.receive(), repeatCount >= 29, repeatCount <= 126 else {
                    throw AxiomError.message("Malformed run-length encoding in probe packet.")
                }
                if let last = payload.last { payload.append(contentsOf: [UInt8](repeating: last, count: Int(repeatCount) - 29)) }
                continue
            }
            payload.append(received)
        }
        for _ in 0..<2 { if let digit = try transport.receive() { checksumBytes.append(digit) } }
        guard checksumBytes.count == 2 else { throw AxiomError.message("Probe packet missing checksum.") }
        let expected = (nibble(checksumBytes[0]) << 4) | nibble(checksumBytes[1])
        let actual = payload.reduce(0) { ($0 + Int($1)) & 0xff }
        guard expected == actual else { throw AxiomError.message("Probe packet checksum mismatch (got \(actual), expected \(expected)).") }
        return String(decoding: payload, as: UTF8.self)
    }

    private func hexBytes(_ text: String, name: String) throws -> [UInt8] {
        guard text.count % 2 == 0, !text.isEmpty else { throw AxiomError.message("Probe returned malformed \(name) hex.") }
        var bytes: [UInt8] = []
        var iterator = text.utf8.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let h = Hex.nibble(high), let l = Hex.nibble(low) else { throw AxiomError.message("Probe returned non-hex \(name) data.") }
            bytes.append(h << 4 | l)
        }
        return bytes
    }

    private func hexDigit(_ value: Int) -> UInt8 {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        return digits[value & 0xf]
    }
    private func nibble(_ character: UInt8) -> Int {
        switch character {
        case 0x30...0x39: return Int(character - 0x30)
        case 0x61...0x66: return Int(character - 0x61 + 10)
        case 0x41...0x46: return Int(character - 0x41 + 10)
        default: return 0
        }
    }
}

/// Minimal TCP transport (the shape every probe daemon speaks).
final class GDBTCPTransport: GDBTransport, @unchecked Sendable {
    private let descriptor: Int32
    private var buffer: [UInt8] = []

    init(host: String, port: Int) {
        var info: UnsafeMutablePointer<addrinfo>?
        var hints = addrinfo()
        hints.ai_flags = AI_PASSIVE
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = Int32(IPPROTO_TCP)
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            descriptor = -1
            return
        }
        defer { freeaddrinfo(info) }
        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { descriptor = -1; return }
        var value: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &value, socklen_t(MemoryLayout<Int32>.size))
        guard connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
            Darwin.close(fd); descriptor = -1; return
        }
        descriptor = fd
    }

    func send(_ bytes: [UInt8]) throws {
        guard descriptor >= 0 else { throw AxiomError.message("Probe transport is not connected.") }
        var remaining = bytes[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard written > 0 else { throw AxiomError.message("Probe transport write failed: errno \(errno).") }
            remaining = remaining.dropFirst(written)
        }
    }

    func receive() throws -> UInt8? {
        guard descriptor >= 0 else { throw AxiomError.message("Probe transport is not connected.") }
        while buffer.isEmpty {
            var byte = UInt8(0)
            let n = read(descriptor, &byte, 1)
            guard n > 0 else { return nil }
            buffer.append(byte)
        }
        return buffer.removeFirst()
    }

    func close() { if descriptor >= 0 { Darwin.close(descriptor) } }
}
