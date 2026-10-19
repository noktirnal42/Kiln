import Foundation
import CryptoKit

// Utility belt (docs/KALI_METASPLOIT_PARITY.md T11): digests, checksums, conversions, and
// pattern search as in-process Swift so the common one-liners never need a terminal.

public enum UtilityBelt {
    /// CRC-32 (IEEE 802.3, reflected, init/xorout 0xFFFFFFFF): "123456789" → 0xCBF43926.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<raw.count {
                crc ^= UInt32(raw[index])
                for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    /// Common digests keyed by algorithm name; values are lowercase hex.
    public static func digests(_ data: Data) -> [String: String] {
        ["md5": CryptoKit.Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(),
         "sha1": CryptoKit.Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined(),
         "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }

    /// Complete digest-command report, preserving statistics alongside cryptographic digests.
    public static func digestReport(_ data: Data) -> [String: String] {
        stats(data).merging(digests(data)) { _, digest in digest }
    }

    /// Quick byte statistics for a selection: printable ratio and entropy, plus the dominant byte.
    public static func stats(_ data: Data) -> [String: String] {
        var bins = [Int](repeating: 0, count: 256)
        var printable = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<raw.count {
                bins[Int(raw[index])] += 1
                if (32...126).contains(raw[index]) { printable += 1 }
            }
        }
        let dominant = bins.enumerated().max { $0.element < $1.element }.map { String(format: "0x%02x (%d)", $0.offset, $0.element) } ?? "n/a"
        return ["size": String(data.count),
                "printableRatio": String(format: "%.3f", data.isEmpty ? 0 : Double(printable) / Double(data.count)),
                "entropy": String(format: "%.3f", EntropyScanner.score(data)),
                "dominantByte": dominant,
                "crc32": String(format: "%08x", crc32(data))]
    }

    /// rax2-class base conversion: parses `value` in `from` (2, 8, 10 or 16) and renders it in `to`.
    /// Accepts an optional `0x`/`0b`/`0o` prefix on the input regardless of `from`.
    public static func convert(_ value: String, from: Int, to: Int) throws -> String {
        for base in [from, to] { guard [2, 8, 10, 16].contains(base) else { throw AxiomError.message("Base must be 2, 8, 10 or 16.") } }
        var text = value.trimmingCharacters(in: .whitespaces)
        var negative = false
        if text.hasPrefix("-") { negative = true; text.removeFirst() }
        for prefix in ["0x", "0X", "0b", "0B", "0o", "0O"] { if text.hasPrefix(prefix) { text.removeFirst(2) } }
        guard !text.isEmpty, let parsed = UInt64(text, radix: from) else { throw AxiomError.message("\"\(value)\" is not valid base-\(from).") }
        let rendered = String(parsed, radix: to)
        return (negative ? "-" : "") + (to == 16 ? "0x" + rendered : rendered)
    }

    /// Hex string (whitespace-tolerant, odd nibble count is an error) to raw bytes and back.
    public static func hexToData(_ hex: String) throws -> Data {
        let clean = hex.filter { !$0.isWhitespace }
        guard clean.count % 2 == 0, !clean.isEmpty else { throw AxiomError.message("Hex input must have an even number of digits.") }
        var bytes: [UInt8] = []; var iterator = clean.makeIterator()
        while let high = iterator.next() {
            guard let low = iterator.next(), let byte = UInt8(String([high, low]), radix: 16) else { throw AxiomError.message("Invalid hex digit.") }
            bytes.append(byte)
        }
        return Data(bytes)
    }
    public static func dataToHex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// rafind2-class wildcard byte search: space-separated hex bytes, `??` or `?` as a one-byte wildcard
    /// (e.g. "41 42 ?? 44"). Returns every match offset, bounded by `limit`.
    public static func wildcardSearch(_ data: Data, pattern: String, limit: Int = 10_000) throws -> [Int] {
        let tokens = pattern.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { throw AxiomError.message("Pattern is empty.") }
        let needle: [UInt8?] = try tokens.map { token in
            if token == "??" || token == "?" { return nil }
            guard token.count == 2, let byte = UInt8(token, radix: 16) else { throw AxiomError.message("Invalid pattern token: \(token) (use hex byte pairs or ??).") }
            return byte
        }
        guard !needle.isEmpty, data.count >= needle.count else { return [] }
        var hits: [Int] = []
        let bytes = [UInt8](data)
        let last = bytes.count - needle.count
        guard last >= 0 else { return [] }
        for start in 0...last {
            if hits.count >= limit { break }
            var matched = true
            for (offset, expected) in needle.enumerated() where expected != nil {
                if bytes[start + offset] != expected! { matched = false; break }
            }
            if matched { hits.append(start) }
        }
        return hits
    }
}
