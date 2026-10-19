import Foundation

// Signature carving and file identification (docs/KALI_METASPLOIT_PARITY.md T1/T2 core): locate
// embedded file-format signatures at any offset in raw bytes. Read-only byte scanning; reported
// hits are extraction candidates for the analyst, and offsets always point at real matched bytes.

/// One identified format signature. `category` groups hits for filtering; `note` carries caveats
/// such as endianness or ambiguity.
public struct FormatHit: Codable, Sendable, Equatable {
    public let offset: Int
    public let format: String
    public let category: String
    public let note: String?
}

public enum FormatIdentifier {
    /// Byte signatures scanned anywhere in the data. Formats that only mean something at a fixed
    /// offset (superblocks, boot sectors) are checked separately below.
    static let signatures: [(format: String, category: String, bytes: [UInt8], note: String?, anywhere: Bool)] = [
        ("Mach-O 64-bit", "executable", [0xcf, 0xfa, 0xed, 0xfe], "little-endian", true),
        ("Mach-O 64-bit", "executable", [0xfe, 0xed, 0xfa, 0xcf], "big-endian", true),
        ("Mach-O 32-bit", "executable", [0xce, 0xfa, 0xed, 0xfe], "little-endian", true),
        ("Mach-O 32-bit", "executable", [0xfe, 0xed, 0xfa, 0xce], "big-endian", true),
        ("Universal Mach-O / Java class", "executable", [0xca, 0xfe, 0xba, 0xbe], "0xcafebabe is shared by both formats", true),
        ("ELF", "executable", [0x7f, 0x45, 0x4c, 0x46], "class byte follows: 01=32-bit, 02=64-bit", true),
        ("PE/COFF", "executable", [0x50, 0x45, 0x00, 0x00], "PE signature; usually preceded by an MZ header", true),
        ("WebAssembly", "executable", [0x00, 0x61, 0x73, 0x6d], nil, true),
        ("DEX (Android)", "executable", [0x64, 0x65, 0x78, 0x0a], "dex\\n", true),
        ("ZIP local file header", "archive", [0x50, 0x4b, 0x03, 0x04], nil, true),
        ("ZIP end of central directory", "archive", [0x50, 0x4b, 0x05, 0x06], nil, true),
        ("RAR", "archive", [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07], nil, true),
        ("7-Zip", "archive", [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c], nil, true),
        ("CAB", "archive", [0x4d, 0x53, 0x43, 0x46], nil, true),
        ("gzip", "compression", [0x1f, 0x8b], nil, true),
        ("zlib stream", "compression", [0x78, 0x01], "weak magic; verify by inflating", true),
        ("zlib stream", "compression", [0x78, 0x9c], "weak magic; verify by inflating", true),
        ("zlib stream", "compression", [0x78, 0xda], "weak magic; verify by inflating", true),
        ("bzip2", "compression", [0x42, 0x5a, 0x68], nil, true),
        ("xz", "compression", [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00], nil, true),
        ("Zstandard", "compression", [0x28, 0xb5, 0x2f, 0xfd], nil, true),
        ("LZ4 frame", "compression", [0x04, 0x22, 0x4d, 0x18], nil, true),
        ("SquashFS", "filesystem", [0x68, 0x73, 0x71, 0x73], "hsqs, little-endian", true),
        ("SquashFS", "filesystem", [0x73, 0x71, 0x73, 0x68], "sqsh, big-endian", true),
        ("CramFS", "filesystem", [0x28, 0xcd, 0x3d, 0x45], "little-endian", true),
        ("CramFS", "filesystem", [0x45, 0x3d, 0xcd, 0x28], "big-endian", true),
        ("JFFS2", "filesystem", [0x19, 0x85, 0x20, 0x03], "little-endian node header", true),
        ("UBI erase-count header", "filesystem", [0x55, 0x42, 0x49, 0x23], "UBI#", true),
        ("romfs", "filesystem", Array("-rom1fs-".utf8), nil, true),
        ("cpio (newc)", "archive", Array("070701".utf8), nil, true),
        ("OLE/CFB compound file", "container", [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1], "Office 97-2003, MSI, StickyNotes", true),
        ("PDF", "document", Array("%PDF-".utf8), nil, true),
        ("PNG", "media", [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], nil, true),
        ("JPEG", "media", [0xff, 0xd8, 0xff], nil, true),
        ("GIF", "media", Array("GIF8".utf8), nil, true),
        ("SQLite database", "database", Array("SQLite format 3\0".utf8), nil, true),
        ("binary plist", "container", Array("bplist00".utf8), nil, true),
        ("PEM/armor block", "key", Array("-----BEGIN".utf8), "certificate, key, or signed data", true),
        ("LUKS volume", "container", [0x4c, 0x55, 0x4b, 0x53, 0xba, 0xbe], "LUKS\\xba\\xbe header", true),
        ("pcap", "capture", [0xd4, 0xc3, 0xb2, 0xa1], "little-endian", true),
        ("pcap", "capture", [0xa1, 0xb2, 0xc3, 0xd4], "big-endian", true),
        ("pcapng", "capture", [0x0a, 0x0d, 0x0d, 0x0a], nil, true),
    ]

    static let maxPerSignature = 64
    static let maxTotalHits = 1024

    /// Scans file bytes for every known format signature, plus fixed-offset structures
    /// (MBR boot signature, ext superblock, GPT, ISO9660, tar, DMG trailer).
    public static func scan(_ data: Data) -> [FormatHit] {
        guard !data.isEmpty else { return [] }
        var hits: [FormatHit] = []
        func append(_ offset: Int, _ format: String, _ category: String, _ note: String?) {
            guard hits.count < maxTotalHits else { return }
            hits.append(FormatHit(offset: offset, format: format, category: category, note: note))
        }
        for signature in signatures where signature.anywhere {
            var searchStart = data.startIndex
            var found = 0
            while found < maxPerSignature, hits.count < maxTotalHits,
                  let range = data.range(of: Data(signature.bytes), options: [], in: searchStart..<data.endIndex) {
                append(range.lowerBound, signature.format, signature.category, signature.note)
                searchStart = range.upperBound
                found += 1
            }
        }
        // Header-only formats: two-byte or otherwise ambiguous patterns that only identify the file at offset 0.
        if data.count >= 2, data[data.startIndex] == 0x4d, data[data.index(after: data.startIndex)] == 0x5a {
            append(0, "PE/COFF", "executable", "MZ header; a PE signature usually follows inside")
        }
        // Fixed-offset structures.
        if data.count > 512, data.subdata(in: 510..<512) == Data([0x55, 0xaa]) {
            append(510, "MBR boot signature", "filesystem", "0x55AA at the end of sector 0")
        }
        if data.count >= 1082, data.subdata(in: 1080..<1082) == Data([0x53, 0xef]) {
            append(1080, "ext2/3/4 superblock", "filesystem", "magic at offset 1080")
        }
        if data.count >= 520, data.subdata(in: 512..<520) == Data("EFI PART".utf8) {
            append(512, "GPT partition table", "filesystem", nil)
        }
        if data.count >= 32774, data.subdata(in: 32769..<32774) == Data("CD001".utf8) {
            append(32769, "ISO9660", "filesystem", "volume descriptor at 0x8001")
        }
        if data.count >= 262, data.subdata(in: 257..<262) == Data("ustar".utf8) {
            append(257, "tar", "archive", "ustar magic at offset 257")
        }
        if data.count >= 512, data.subdata(in: (data.count - 4)..<data.count) == Data("koly".utf8) {
            append(data.count - 512, "Apple DMG", "container", "koly trailer in the last 512 bytes")
        }
        return hits.sorted { $0.offset < $1.offset }
    }

    /// Packer fingerprints on top of the generic table (docs/KALI_METASPLOIT_PARITY.md T2).
    public static func identifyPacker(_ data: Data) -> [FormatHit] {
        var found: [FormatHit] = []
        var searchStart = data.startIndex
        while found.count < 16, let range = data.range(of: Data("UPX!".utf8), options: [], in: searchStart..<data.endIndex) {
            found.append(FormatHit(offset: range.lowerBound, format: "UPX", category: "packer", note: "UPX! marker; packed sections usually follow"))
            searchStart = range.upperBound
        }
        return found
    }
}
