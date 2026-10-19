import Foundation

// Capture analysis (docs/KALI_METASPLOIT_PARITY.md T6): classic pcap parsing, TCP stream
// reassembly, and a shallow Ethernet/IP/TCP/UDP dissection. Reads a capture file an analyst
// already has (e.g. pulled off a device during T7 bench work, or handed over for review); this
// module never opens a live interface or injects traffic. pcapng and BLE/SDR capture formats are
// a later add (see docs/OPEN_ITEMS.md) — this covers classic (.pcap) captures, which is what
// most tooling (tcpdump, most USB/serial-to-pcap bridges) still writes by default.

public struct CapturePacket: Codable, Sendable, Equatable {
    public let index: Int
    public let timestamp: Double          // seconds since the Unix epoch, from the per-packet header
    public let capturedLength: Int
    public let originalLength: Int
    /// Offset of this packet's raw bytes within the capture file, for re-reading without copying.
    public let offset: Int
}

public struct Dissection: Codable, Sendable, Equatable {
    public let etherType: String?
    public let sourceMAC: String?
    public let destMAC: String?
    public let ipVersion: Int?
    public let sourceIP: String?
    public let destIP: String?
    public let ipProtocol: String?
    public let sourcePort: Int?
    public let destPort: Int?
    public let tcpFlags: [String]?
    public let payloadOffset: Int?
    public let payloadLength: Int?
}

public enum CaptureError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): return text } }
}

public enum PcapReader {
    static let magicLE: UInt32 = 0xa1b2c3d4   // seconds-resolution, little-endian byte order in the file
    static let magicBE: UInt32 = 0xd4c3b2a1
    static let maxPackets = 200_000

    /// Parses the 24-byte global header and every per-packet record. Read-only; returns metadata
    /// and an offset into `data` per packet rather than copying payloads, since captures can be large.
    public static func packets(in data: Data) throws -> (linkType: UInt32, packets: [CapturePacket]) {
        guard data.count >= 24 else { throw CaptureError.message("Too short to be a pcap file.") }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let bigEndian: Bool
        switch magic {
        case magicLE: bigEndian = false
        case magicBE: bigEndian = true
        default: throw CaptureError.message("Not a classic pcap file (bad magic). pcapng and nanosecond-resolution variants are not yet supported.")
        }
        func u16(_ offset: Int) -> UInt16 { let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }; return bigEndian ? v.bigEndian : v.littleEndian }
        func u32(_ offset: Int) -> UInt32 { let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }; return bigEndian ? v.bigEndian : v.littleEndian }
        let linkType = u32(20)
        var packets: [CapturePacket] = []
        var cursor = 24
        var index = 0
        while cursor + 16 <= data.count, packets.count < maxPackets {
            let seconds = u32(cursor), microseconds = u32(cursor + 4)
            let captured = Int(u32(cursor + 8)), original = Int(u32(cursor + 12))
            guard captured >= 0, captured <= data.count - cursor - 16 else { throw CaptureError.message("Packet \(index) declares a length past the end of the file; truncated or corrupt capture.") }
            packets.append(CapturePacket(index: index, timestamp: Double(seconds) + Double(microseconds) / 1_000_000, capturedLength: captured, originalLength: original, offset: cursor + 16))
            cursor += 16 + captured
            index += 1
        }
        return (linkType, packets)
    }

    /// Shallow dissection of one packet's bytes, assuming Ethernet framing (linkType 1, the common
    /// case). Never fails on an unrecognized/short packet — returns whatever layers it could read.
    public static func dissectEthernet(_ data: Data, at offset: Int, length: Int) -> Dissection {
        func byte(_ at: Int) -> UInt8? { at < offset + length && at < data.count ? data[data.startIndex + at] : nil }
        func u16(_ at: Int) -> UInt16? { guard let a = byte(at), let b = byte(at + 1) else { return nil }; return UInt16(a) << 8 | UInt16(b) }
        func mac(_ at: Int) -> String? {
            var parts: [String] = []
            for index in 0..<6 { guard let value = byte(at + index) else { return nil }; parts.append(String(format: "%02x", value)) }
            return parts.joined(separator: ":")
        }
        guard length >= 14 else { return Dissection(etherType: nil, sourceMAC: nil, destMAC: nil, ipVersion: nil, sourceIP: nil, destIP: nil, ipProtocol: nil, sourcePort: nil, destPort: nil, tcpFlags: nil, payloadOffset: nil, payloadLength: nil) }
        let destMAC = mac(offset), sourceMAC = mac(offset + 6)
        let etherTypeValue = u16(offset + 12) ?? 0
        let etherType = String(format: "0x%04x", etherTypeValue)
        guard etherTypeValue == 0x0800, let versionIHL = byte(offset + 14) else {
            return Dissection(etherType: etherType, sourceMAC: sourceMAC, destMAC: destMAC, ipVersion: nil, sourceIP: nil, destIP: nil, ipProtocol: nil, sourcePort: nil, destPort: nil, tcpFlags: nil, payloadOffset: nil, payloadLength: nil)
        }
        let ipStart = offset + 14
        let version = Int(versionIHL >> 4)
        let ihl = Int(versionIHL & 0x0f) * 4
        guard version == 4, ihl >= 20, let protocolByte = byte(ipStart + 9) else {
            return Dissection(etherType: etherType, sourceMAC: sourceMAC, destMAC: destMAC, ipVersion: version, sourceIP: nil, destIP: nil, ipProtocol: nil, sourcePort: nil, destPort: nil, tcpFlags: nil, payloadOffset: nil, payloadLength: nil)
        }
        func ipAddress(_ at: Int) -> String? {
            var parts: [String] = []
            for index in 0..<4 { guard let value = byte(at + index) else { return nil }; parts.append(String(value)) }
            return parts.joined(separator: ".")
        }
        let sourceIP = ipAddress(ipStart + 12), destIP = ipAddress(ipStart + 16)
        let protocolName: String
        switch protocolByte { case 6: protocolName = "TCP"; case 17: protocolName = "UDP"; case 1: protocolName = "ICMP"; default: protocolName = "0x" + String(format: "%02x", protocolByte) }
        let transportStart = ipStart + ihl
        var sourcePort: Int?, destPort: Int?, flags: [String]?, payloadOffset: Int?, payloadLength: Int?
        if protocolByte == 6, let sp = u16(transportStart), let dp = u16(transportStart + 2), let dataOffsetByte = byte(transportStart + 12), let flagsByte = byte(transportStart + 13) {
            sourcePort = Int(sp); destPort = Int(dp)
            var names: [String] = []
            if flagsByte & 0x01 != 0 { names.append("FIN") }; if flagsByte & 0x02 != 0 { names.append("SYN") }
            if flagsByte & 0x04 != 0 { names.append("RST") }; if flagsByte & 0x08 != 0 { names.append("PSH") }
            if flagsByte & 0x10 != 0 { names.append("ACK") }; if flagsByte & 0x20 != 0 { names.append("URG") }
            flags = names
            let headerLength = Int(dataOffsetByte >> 4) * 4
            payloadOffset = transportStart + headerLength
            payloadLength = max(0, offset + length - (transportStart + headerLength))
        } else if protocolByte == 17, let sp = u16(transportStart), let dp = u16(transportStart + 2) {
            sourcePort = Int(sp); destPort = Int(dp)
            payloadOffset = transportStart + 8
            payloadLength = max(0, offset + length - (transportStart + 8))
        }
        return Dissection(etherType: etherType, sourceMAC: sourceMAC, destMAC: destMAC, ipVersion: version, sourceIP: sourceIP, destIP: destIP, ipProtocol: protocolName, sourcePort: sourcePort, destPort: destPort, tcpFlags: flags, payloadOffset: payloadOffset, payloadLength: payloadLength)
    }
}

public struct ReassembledStream: Codable, Sendable, Equatable {
    public let sourceIP: String, destIP: String, sourcePort: Int, destPort: Int
    public let packetCount: Int
    public let byteCount: Int
}

public enum StreamReassembly {
    /// Groups packets into TCP/UDP 4-tuple flows (both directions share one key, ordered by
    /// whichever side initiated first) and sums their payload bytes. A byte-exact reassembly
    /// (sequence-number ordering, retransmit/out-of-order handling) is a later add; this is the
    /// "which flows exist and how big are they" pass that T1/auto-decrypt can hand ciphertext
    /// candidates off from today (`export-objects` in docs/KALI_METASPLOIT_PARITY.md).
    public static func flows(_ data: Data, packets: [CapturePacket]) -> [ReassembledStream] {
        struct Key: Hashable { let a: String, b: String, pa: Int, pb: Int }
        var order: [Key] = []
        var byTuple: [Key: (count: Int, bytes: Int, src: String, dst: String, sp: Int, dp: Int)] = [:]
        for packet in packets {
            let dissection = PcapReader.dissectEthernet(data, at: packet.offset, length: packet.capturedLength)
            guard let sourceIP = dissection.sourceIP, let destIP = dissection.destIP, let sourcePort = dissection.sourcePort, let destPort = dissection.destPort else { continue }
            let forward = Key(a: sourceIP, b: destIP, pa: sourcePort, pb: destPort)
            let reverse = Key(a: destIP, b: sourceIP, pa: destPort, pb: sourcePort)
            let key = byTuple[forward] != nil ? forward : (byTuple[reverse] != nil ? reverse : forward)
            if byTuple[key] == nil { order.append(key) }
            let payload = dissection.payloadLength ?? 0
            var entry = byTuple[key] ?? (0, 0, sourceIP, destIP, sourcePort, destPort)
            entry.count += 1; entry.bytes += payload
            byTuple[key] = entry
        }
        return order.compactMap { key in byTuple[key].map { ReassembledStream(sourceIP: $0.src, destIP: $0.dst, sourcePort: $0.sp, destPort: $0.dp, packetCount: $0.count, byteCount: $0.bytes) } }
    }
}
