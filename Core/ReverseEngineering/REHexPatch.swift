import Foundation
import CryptoKit
import AxiomCore

// Hex view backing, address <-> file offset mapping, byte search and patching. The original binary is only ever read; patches
// are applied to a copy that Kiln writes next to the project.

public struct RESegment: Sendable, Equatable {
    public let name: String
    public let address: UInt64
    public let size: UInt64
    public let fileOffset: UInt64
    public let fileSize: UInt64
}

/// Virtual address <-> file offset map, read from the load commands text the importer stored (`otool -l`), or identity
/// when the format has none.
public struct REAddressMap: Sendable, Equatable {
    public var segments: [RESegment]
    /// Offset of the analysed slice inside a universal file.
    public var sliceBase: UInt64 = 0

    public static func parse(sections: String, sliceBase: UInt64 = 0) -> REAddressMap {
        var segments: [RESegment] = []
        var fields: [String: String] = [:]
        func flush() {
            defer { fields = [:] }
            guard let name = fields["segname"], let addr = number(fields["vmaddr"]), let size = number(fields["vmsize"]),
                  let off = number(fields["fileoff"]), let fsize = number(fields["filesize"]), size > 0 else { return }
            segments.append(RESegment(name: name, address: addr, size: size, fileOffset: off, fileSize: fsize))
        }
        for raw in sections.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Load command") || line.hasPrefix("Section") { if line.hasPrefix("Load command") { flush() } ; if line.hasPrefix("Section") { continue } }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]); let value = parts[1].trimmingCharacters(in: .whitespaces)
            // Only the first occurrence in a load command (segment fields precede the section blocks).
            if ["segname", "vmaddr", "vmsize", "fileoff", "filesize"].contains(key), fields[key] == nil { fields[key] = value }
        }
        flush()
        return REAddressMap(segments: segments.filter { $0.name != "__PAGEZERO" }, sliceBase: sliceBase)
    }
    private static func number(_ text: String?) -> UInt64? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
    }

    /// File offset for a virtual address (within the slice, plus `sliceBase`).
    public func fileOffset(forAddress address: UInt64) -> UInt64? {
        if segments.isEmpty { return address }
        for segment in segments where address >= segment.address && address - segment.address < segment.fileSize {
            return segment.fileOffset + (address - segment.address) + sliceBase
        }
        return nil
    }

    public func address(forFileOffset offset: UInt64) -> UInt64? {
        if segments.isEmpty { return offset }
        let local = offset >= sliceBase ? offset - sliceBase : offset
        for segment in segments where local >= segment.fileOffset && local - segment.fileOffset < segment.fileSize {
            return segment.address + (local - segment.fileOffset)
        }
        return nil
    }

    /// Segment name containing the address, for the hex view gutter.
    public func segmentName(forAddress address: UInt64) -> String? {
        segments.first { address >= $0.address && address - $0.address < $0.size }?.name
    }
}

public struct REHexRow: Sendable, Equatable, Identifiable {
    public var id: UInt64 { offset }
    public let offset: UInt64
    public let address: UInt64?
    public let bytes: [UInt8]
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }
    public var ascii: String { String(bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." }) }
}

public enum REHex {
    public static let bytesPerRow = 16
    public static let maxRead = 1 << 20

    public static func read(_ url: URL, offset: UInt64, length: Int) throws -> Data {
        guard length >= 0, length <= maxRead else { throw REError.invalidArgument("length must be 0 to \(maxRead) bytes") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }

    public static func rows(_ data: Data, startOffset: UInt64, map: REAddressMap? = nil) -> [REHexRow] {
        stride(from: 0, to: data.count, by: bytesPerRow).map { index in
            let chunk = Array(data[data.startIndex + index ..< min(data.startIndex + index + bytesPerRow, data.endIndex)])
            let offset = startOffset + UInt64(index)
            return REHexRow(offset: offset, address: map?.address(forFileOffset: offset), bytes: chunk)
        }
    }

    /// Parses `de ad ?? ef` (wildcards), `0xdeadbeef`, or a quoted ASCII string (`"KILN"`) into a byte pattern; nil bytes are wildcards.
    public static func pattern(_ text: String) throws -> [UInt8?] {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { return Array(value.dropFirst().dropLast().utf8).map { Optional($0) } }
        var compact = value.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: ",", with: " ")
        if !compact.contains(" ") { compact = stride(from: 0, to: compact.count, by: 2).map { i -> String in
            let start = compact.index(compact.startIndex, offsetBy: i); return String(compact[start..<compact.index(start, offsetBy: min(2, compact.count - i))]) }.joined(separator: " ") }
        var result: [UInt8?] = []
        for token in compact.split(separator: " ") {
            if token == "??" || token == "?" || token == ".." { result.append(nil) }
            else if token.count == 2, let byte = UInt8(token, radix: 16) { result.append(byte) }
            else { throw REError.invalidArgument("'\(token)' is not a hex byte; use pairs like de ad ?? ef, or \"text\" for ASCII") }
        }
        guard !result.isEmpty, result.contains(where: { $0 != nil }) else { throw REError.invalidArgument("pattern needs at least one concrete byte") }
        return result
    }

    /// Offsets of `pattern` in the file, at most `limit`, scanning in 4 MiB windows that overlap by the pattern length.
    public static func search(_ url: URL, pattern: [UInt8?], from start: UInt64 = 0, limit: Int = 500) throws -> [UInt64] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var results: [UInt64] = []
        let window = 4 << 20
        var position = start
        let first = pattern.firstIndex(where: { $0 != nil }) ?? 0
        while results.count < limit {
            try handle.seek(toOffset: position)
            guard let data = try handle.read(upToCount: window + pattern.count), data.count >= pattern.count else { break }
            let bytes = [UInt8](data)
            let lastStart = bytes.count - pattern.count
            var i = 0
            while i <= lastStart, results.count < limit {
                if bytes[i + first] == pattern[first] {
                    var ok = true
                    for (j, want) in pattern.enumerated() { if let want, bytes[i + j] != want { ok = false; break } }
                    if ok { results.append(position + UInt64(i)) }
                }
                i += 1
            }
            if bytes.count <= window { break }
            position += UInt64(window)
        }
        return results
    }
}

// MARK: Patches

public struct REPatch: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID().uuidString
    public var address: String
    public var fileOffset: UInt64
    /// Bytes the patch expects to replace; applying refuses to run if the file differs, so a patch never lands on the wrong build.
    public var original: String
    public var bytes: String
    public var note: String
    public var assembly: String?
    public var created = Date()
    public var applied = false

    public var originalData: Data { Data(hex: original) }
    public var patchData: Data { Data(hex: bytes) }
}

extension Data {
    init(hex: String) {
        let cleaned = hex.filter { $0.isHexDigit }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex, let next = cleaned.index(index, offsetBy: 2, limitedBy: cleaned.endIndex) {
            if let byte = UInt8(cleaned[index..<next], radix: 16) { data.append(byte) }
            index = next
        }
        self = data
    }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

public enum REPatcher {
    /// Builds a patch from replacement bytes, reading the bytes it will replace from the binary.
    public static func makePatch(binary: URL, map: REAddressMap, address: UInt64, bytes: Data, note: String, assembly: String? = nil) throws -> REPatch {
        guard !bytes.isEmpty, bytes.count <= 4096 else { throw REError.invalidArgument("a patch is 1 to 4096 bytes") }
        guard let offset = map.fileOffset(forAddress: address) else { throw REError.invalidArgument("address 0x\(REListing.hex(address)) is not backed by file contents") }
        let original = try REHex.read(binary, offset: offset, length: bytes.count)
        guard original.count == bytes.count else { throw REError.invalidArgument("patch runs past the end of the file") }
        return REPatch(address: REListing.hex(address), fileOffset: offset, original: original.hexString, bytes: bytes.hexString, note: note, assembly: assembly)
    }

    /// Copies `binary` to `output` and writes every patch into the copy. Throws if `output` is the original, if a patch's expected bytes
    /// differ, or if two patches overlap. Returns the SHA-256 of the result.
    @discardableResult
    public static func apply(_ patches: [REPatch], to binary: URL, output: URL) throws -> String {
        let source = binary.standardizedFileURL.resolvingSymlinksInPath()
        let destination = output.standardizedFileURL.resolvingSymlinksInPath()
        guard source != destination else { throw REError.invalidArgument("patches are never applied to the original binary; choose a different output path") }
        let ordered = patches.sorted { $0.fileOffset < $1.fileOffset }
        for (a, b) in zip(ordered, ordered.dropFirst()) where a.fileOffset + UInt64(a.patchData.count) > b.fileOffset {
            throw REError.invalidArgument("patches at 0x\(a.address) and 0x\(b.address) overlap")
        }
        var data = try Data(contentsOf: source)
        for patch in ordered {
            let start = Int(patch.fileOffset), end = start + patch.patchData.count
            guard end <= data.count else { throw REError.invalidArgument("patch at 0x\(patch.address) runs past the end of the file") }
            guard data[start..<end] == patch.originalData else {
                throw REError.invalidArgument("bytes at 0x\(patch.address) are not what the patch expected; the binary has changed")
            }
            data.replaceSubrange(start..<end, with: patch.patchData)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: source.path), let mode = attributes[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A no-op sequence for `length` bytes in the given architecture.
    public static func nop(architecture: String, length: Int) throws -> Data {
        switch architecture {
        case "arm64", "arm64e":
            guard length > 0, length % 4 == 0 else { throw REError.invalidArgument("arm64 instructions are 4 bytes; use a multiple of 4") }
            return Data((0..<(length / 4)).flatMap { _ in [UInt8(0x1f), 0x20, 0x03, 0xd5] })
        case "x86_64", "i386":
            guard length > 0 else { throw REError.invalidArgument("length must be positive") }
            return Data(repeating: 0x90, count: length)
        default: throw REError.invalidArgument("no NOP encoding known for \(architecture)")
        }
    }

    /// Assembles `source` with the toolchain's clang (`xcrun clang -c`) and returns the bytes of its `__text` section. The assembler
    /// never links or runs anything. x86 source is Intel syntax.
    public static func assemble(_ source: String, architecture: String) throws -> Data {
        guard ["arm64", "arm64e", "x86_64"].contains(architecture) else { throw REError.invalidArgument("assembling is supported for arm64 and x86_64") }
        guard source.count <= 16_384 else { throw REError.invalidArgument("assembly source is limited to 16 KiB") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-asm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("patch.s"), object = folder.appendingPathComponent("patch.o")
        let prefix = architecture == "x86_64" ? ".intel_syntax noprefix\n" : ""
        try (prefix + ".text\n" + source + "\n").write(to: input, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run("/usr/bin/xcrun", ["clang", "-arch", architecture == "arm64e" ? "arm64e" : architecture, "-c", "-x", "assembler", input.path, "-o", object.path])
        return try machOTextBytes(Data(contentsOf: object))
    }

    /// The `__text` section of a 64-bit Mach-O object file.
    static func machOTextBytes(_ data: Data) throws -> Data {
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func u64(_ at: Int) -> UInt64 { data[at..<at + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }
        guard data.count > 32, u32(0) == 0xfeedfacf else { throw REError.invalidArgument("assembler output is not a 64-bit Mach-O object") }
        var offset = 32
        for _ in 0..<Int(u32(16)) {
            guard offset + 8 <= data.count else { break }
            let command = u32(offset), size = Int(u32(offset + 4))
            if command == 0x19 {
                let sectionCount = Int(u32(offset + 64))
                var section = offset + 72
                for _ in 0..<sectionCount {
                    let name = String(decoding: data[section..<section + 16].prefix { $0 != 0 }, as: UTF8.self)
                    let length = Int(u64(section + 40)), position = Int(u32(section + 48))
                    if name == "__text", position + length <= data.count { return data[position..<position + length] }
                    section += 80
                }
            }
            offset += size
        }
        throw REError.invalidArgument("assembler produced no code")
    }
}
