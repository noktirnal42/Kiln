import Foundation

// Static crypto identification (docs/DECRYPTION_TOOLING.md stage 2): locate known cryptographic
// constant tables in raw file bytes. This is read-only byte scanning of file contents; it never
// executes anything and never touches key material.

/// One identified constant-table location. `confidence` states how strong the byte evidence is;
/// hits are leads for the analyst, not conclusions.
public struct CryptoHit: Codable, Sendable, Equatable {
    public let offset: Int
    public let algorithm: String
    public let kind: String
    public let confidence: String
    public let note: String?
}

public enum CryptoIdentifier {
    /// Signatures are built from well-known public constant values (S-boxes, round constants,
    /// initial states), the same public knowledge findcrypt/signsrch-class tools scan for.
    /// Word-derived tables are generated in both byte orders because implementations store them either way.
    static let signatures: [(algorithm: String, kind: String, bytes: [UInt8])] = {
        var list: [(String, String, [UInt8])] = []
        func add(_ algorithm: String, _ kind: String, _ bytes: [UInt8]) { list.append((algorithm, kind, bytes)) }
        func words32(_ words: [UInt32], bigEndian: Bool) -> [UInt8] {
            words.flatMap { bigEndian ? withUnsafeBytes(of: $0.bigEndian, Array.init) : withUnsafeBytes(of: $0.littleEndian, Array.init) }
        }
        func words64(_ words: [UInt64], bigEndian: Bool) -> [UInt8] {
            words.flatMap { bigEndian ? withUnsafeBytes(of: $0.bigEndian, Array.init) : withUnsafeBytes(of: $0.littleEndian, Array.init) }
        }
        // AES S-box and inverse S-box (first 64 bytes of each table).
        add("AES", "S-box", [0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
                             0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
                             0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
                             0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75])
        add("AES", "inverse S-box", [0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
                                     0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
                                     0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
                                     0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25])
        // SHA-2/MD5/SHA-1 initial states and round constants, both byte orders.
        let sha256K: [UInt32] = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5]
        add("SHA-256", "round constants (big-endian)", words32(sha256K, bigEndian: true))
        add("SHA-256", "round constants (little-endian)", words32(sha256K, bigEndian: false))
        add("SHA-256", "initial state (big-endian)", words32([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a], bigEndian: true))
        add("SHA-1", "initial state (big-endian)", words32([0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0], bigEndian: true))
        add("MD5", "initial state (little-endian)", words32([0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476], bigEndian: false))
        add("MD5", "round constants (little-endian)", words32([0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501], bigEndian: false))
        let sha512K: [UInt64] = [0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f]
        add("SHA-512", "round constants (big-endian)", words64(sha512K, bigEndian: true))
        add("SHA-512", "round constants (little-endian)", words64(sha512K, bigEndian: false))
        add("SHA-512", "initial state (big-endian)", words64([0x6a09e667f3bcc908, 0xbb67ae8584caa73b], bigEndian: true))
        add("Keccak/SHA-3", "round constants (little-endian)", words64([0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000], bigEndian: false))
        add("Blowfish", "P-array (big-endian)", words32([0x243f6a88, 0x85a308d3, 0x13198a2e, 0x03707344], bigEndian: true))
        add("ChaCha/Salsa", "sigma constant", Array("expand 32-byte k".utf8))
        // CRC-32 (IEEE) table, generated so it cannot drift from the polynomial.
        var crcTable: [UInt8] = []
        for i: UInt32 in 0..<16 {
            var c = i
            for _ in 0..<8 { c = (c & 1) == 1 ? 0xedb88320 ^ (c >> 1) : c >> 1 }
            crcTable += words32([c], bigEndian: false)
        }
        add("CRC-32", "lookup table (little-endian)", crcTable)
        return list
    }()

    /// Maximum reported hits per signature so a pathological file cannot flood output.
    static let maxPerSignature = 32
    static let maxTotalHits = 512

    /// Scans file bytes for known cryptographic constant tables and RSA public-key shapes.
    public static func scan(_ data: Data) -> [CryptoHit] {
        guard !data.isEmpty else { return [] }
        var hits: [CryptoHit] = []
        for signature in signatures {
            var searchStart = data.startIndex
            var found = 0
            while found < maxPerSignature, hits.count < maxTotalHits,
                  let range = data.range(of: Data(signature.bytes), options: [], in: searchStart..<data.endIndex) {
                hits.append(CryptoHit(offset: range.lowerBound, algorithm: signature.algorithm, kind: signature.kind,
                                      confidence: signature.bytes.count >= 24 ? "exact table match" : "short constant run", note: nil))
                searchStart = range.upperBound
                found += 1
            }
        }
        hits += rsaHits(data)
        return hits.sorted { $0.offset < $1.offset }
    }

    /// RSA public keys show up as a DER-encoded 65537 exponent, or as a bare 65537 followed by
    /// a modulus-sized block of high-entropy bytes. Both checks are heuristics; the DER form is strong.
    static func rsaHits(_ data: Data) -> [CryptoHit] {
        var hits: [CryptoHit] = []
        let der = Data([0x02, 0x03, 0x01, 0x00, 0x01])
        var searchStart = data.startIndex
        while hits.count < maxPerSignature, let range = data.range(of: der, options: [], in: searchStart..<data.endIndex) {
            hits.append(CryptoHit(offset: range.lowerBound, algorithm: "RSA", kind: "public exponent 65537 (DER-encoded)",
                                  confidence: "exact DER sequence", note: "modulus usually follows within a few bytes"))
            searchStart = range.upperBound
        }
        let bare = Data([0x01, 0x00, 0x01])
        searchStart = data.startIndex
        var heuristicHits = 0
        while heuristicHits < 8, let range = data.range(of: bare, options: [], in: searchStart..<data.endIndex) {
            let after = range.upperBound
            if data.count - after >= 128 {
                let modulus = data.subdata(in: after..<min(after + 256, data.count))
                if EntropyScanner.score(modulus) > 6.0 {
                    hits.append(CryptoHit(offset: range.lowerBound, algorithm: "RSA", kind: "public exponent 65537 followed by modulus-sized data",
                                          confidence: "heuristic", note: "verify by parsing the key structure"))
                    heuristicHits += 1
                }
            }
            searchStart = range.upperBound
        }
        return hits
    }
}
