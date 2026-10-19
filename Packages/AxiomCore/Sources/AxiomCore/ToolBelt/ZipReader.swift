import Foundation
import Compression

// Minimal ZIP reader (supports T5's APK/IPA handling, and general-purpose archive inspection):
// reads the end-of-central-directory record and central directory to list entries, then extracts
// one entry's bytes (stored or DEFLATE, via the system Compression framework — no third-party zip
// library). Read-only: never writes a zip, never executes anything from inside one.

public struct ZipEntry: Codable, Sendable, Equatable {
    public let name: String
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let method: Int           // 0 = stored, 8 = deflate; anything else is unsupported for extraction
    public let localHeaderOffset: Int
}

public enum ZipReader {
    static let maxEntries = 100_000
    static let maxExtractBytes = 256 * 1024 * 1024

    /// Scans backward from the end of the file for the End Of Central Directory record (it can be
    /// followed by a variable-length comment, so its exact position isn't fixed), then walks the
    /// central directory it points to.
    public static func entries(_ data: Data) throws -> [ZipEntry] {
        guard data.count >= 22 else { throw AxiomError.message("Too short to be a ZIP file.") }
        let searchFloor = max(0, data.count - 22 - 65535)
        var eocdOffset: Int?
        var index = data.count - 22
        while index >= searchFloor {
            if u32(data, index) == 0x06054b50 { eocdOffset = index; break }
            index -= 1
        }
        guard let eocd = eocdOffset else { throw AxiomError.message("No End Of Central Directory record found; not a ZIP file (or ZIP64, not yet supported).") }
        guard let entryCount = u16(data, eocd + 10), let centralOffset = u32(data, eocd + 16) else { throw AxiomError.message("Truncated EOCD record.") }
        var entries: [ZipEntry] = []
        var cursor = Int(centralOffset)
        for _ in 0..<min(Int(entryCount), maxEntries) {
            guard u32(data, cursor) == 0x02014b50 else { throw AxiomError.message("Central directory entry at offset \(cursor) has a bad signature; corrupt or truncated archive.") }
            guard let method = u16(data, cursor + 10), let compressedSize = u32(data, cursor + 20), let uncompressedSize = u32(data, cursor + 24),
                  let nameLength = u16(data, cursor + 28), let extraLength = u16(data, cursor + 30), let commentLength = u16(data, cursor + 32),
                  let localOffset = u32(data, cursor + 42) else { throw AxiomError.message("Truncated central directory entry at offset \(cursor).") }
            let nameStart = cursor + 46
            guard nameStart + Int(nameLength) <= data.count else { throw AxiomError.message("Entry name runs past end of file.") }
            let name = String(decoding: data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + nameStart + Int(nameLength))), as: UTF8.self)
            entries.append(ZipEntry(name: name, compressedSize: Int(compressedSize), uncompressedSize: Int(uncompressedSize), method: Int(method), localHeaderOffset: Int(localOffset)))
            cursor = nameStart + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }
        return entries
    }

    /// Reads one entry's local header to find the real compressed-data offset (the central
    /// directory's name/extra lengths can differ from the local header's), then decompresses.
    public static func extract(_ data: Data, entry: ZipEntry) throws -> Data {
        let local = entry.localHeaderOffset
        guard u32(data, local) == 0x04034b50 else { throw AxiomError.message("Local file header at offset \(local) has a bad signature.") }
        guard let nameLength = u16(data, local + 26), let extraLength = u16(data, local + 28) else { throw AxiomError.message("Truncated local file header.") }
        let dataStart = local + 30 + Int(nameLength) + Int(extraLength)
        guard dataStart + entry.compressedSize <= data.count else { throw AxiomError.message("Entry '\(entry.name)' compressed data runs past end of file.") }
        guard entry.uncompressedSize <= maxExtractBytes else { throw AxiomError.message("Entry '\(entry.name)' exceeds the \(maxExtractBytes / 1024 / 1024) MiB extraction cap.") }
        let compressed = data.subdata(in: (data.startIndex + dataStart)..<(data.startIndex + dataStart + entry.compressedSize))
        switch entry.method {
        case 0: return compressed
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            var output = [UInt8](repeating: 0, count: entry.uncompressedSize)
            let written = output.withUnsafeMutableBufferPointer { outBuf -> Int in
                compressed.withUnsafeBytes { inBuf -> Int in
                    compression_decode_buffer(outBuf.baseAddress!, entry.uncompressedSize, inBuf.bindMemory(to: UInt8.self).baseAddress!, compressed.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.uncompressedSize else { throw AxiomError.message("DEFLATE decompression of '\(entry.name)' produced \(written) bytes, expected \(entry.uncompressedSize).") }
            return Data(output)
        default: throw AxiomError.message("Entry '\(entry.name)' uses unsupported compression method \(entry.method) (only stored/DEFLATE are supported).")
        }
    }

    public static func entry(named name: String, in entries: [ZipEntry]) -> ZipEntry? { entries.first { $0.name == name } }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }
}
