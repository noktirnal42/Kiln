import Foundation

// Android resource table (resources.arsc) parser (docs/KALI_METASPLOIT_PARITY.md T5): original
// implementation from the public AOSP chunk-format documentation (frameworks/base
// ResourceTypes.h), reusing AndroidXML's string-pool reader (resources.arsc uses the same pool
// format AndroidManifest.xml does). Scope: package name, type names, key names, and the flat
// (resource ID -> type/key name) listing every type's entry table declares. Resolving each
// entry's actual typed value (including complex types: arrays, styles, config-specific
// overrides) is a follow-on — this gives "what resource IDs and names exist," which is what a
// resource decoding step needs first, without claiming to resolve values it doesn't walk yet.

public struct ResourceEntry: Codable, Sendable, Equatable {
    public let id: UInt32          // packageId<<24 | typeIndex<<16 | entryIndex
    public let type: String
    public let key: String
}

public struct ResourceTable: Codable, Sendable, Equatable {
    public let packageName: String
    public let packageId: UInt32
    public let entries: [ResourceEntry]
}

public enum AndroidResources {
    static let typeTable: UInt16 = 0x0002
    static let typePackage: UInt16 = 0x0200
    static let typeTypeSpec: UInt16 = 0x0202
    static let typeType: UInt16 = 0x0201
    static let typeStringPool: UInt16 = 0x0001
    static let maxEntries = 500_000

    public static func parse(_ data: Data) throws -> [ResourceTable] {
        guard let rootType = u16(data, 0), rootType == typeTable else { throw AxiomError.message("Not a resource table (expected RES_TABLE_TYPE chunk at offset 0).") }
        guard let packageCount = u32(data, 8) else { throw AxiomError.message("Truncated resource table header.") }
        var tables: [ResourceTable] = []
        var cursor = 12   // past ResChunk_header(8) + packageCount(4)
        var sawStringPool = false
        while cursor + 8 <= data.count, tables.count < Int(packageCount) {
            guard let chunkType = u16(data, cursor), let chunkSize = u32(data, cursor + 4), chunkSize >= 8 else { break }
            let chunkEnd = cursor + Int(chunkSize)
            if chunkType == typeStringPool, !sawStringPool {
                sawStringPool = true   // the table's one global string pool (string resource values) — not needed for the id/name listing
            } else if chunkType == typePackage {
                tables.append(try parsePackage(data, at: cursor, size: Int(chunkSize)))
            }
            guard chunkEnd > cursor else { break }
            cursor = chunkEnd
        }
        return tables
    }

    private static func parsePackage(_ data: Data, at start: Int, size: Int) throws -> ResourceTable {
        guard let packageId = u32(data, start + 8), let typeStringsOffset = u32(data, start + 268), let keyStringsOffset = u32(data, start + 276) else {
            throw AxiomError.message("Truncated package header at offset \(start).")
        }
        let nameStart = start + 12
        var nameUnits: [UInt16] = []
        var index = 0
        while index < 128, let unit = u16(data, nameStart + index * 2), unit != 0 { nameUnits.append(unit); index += 1 }
        let packageName = String(decoding: nameUnits, as: UTF16.self)
        let typeNames = try AndroidXML.parseStringPool(data, at: start + Int(typeStringsOffset), headerSize: 28)
        let keyNames = try AndroidXML.parseStringPool(data, at: start + Int(keyStringsOffset), headerSize: 28)
        var entries: [ResourceEntry] = []
        var cursor = start + 12 + 256 + 4 + 4 + 4 + 4   // past the fixed ResTable_package header (id, name[128 UTF-16 units], typeStrings, lastPublicType, keyStrings, lastPublicKey)
        let end = start + size
        while cursor + 8 <= end, entries.count < maxEntries {
            guard let chunkType = u16(data, cursor), let chunkSize = u32(data, cursor + 4), chunkSize >= 8 else { break }
            let chunkEnd = cursor + Int(chunkSize)
            if chunkType == typeType {
                entries += try parseType(data, at: cursor, packageId: packageId, typeNames: typeNames, keyNames: keyNames)
            }
            guard chunkEnd > cursor else { break }
            cursor = chunkEnd
        }
        return ResourceTable(packageName: packageName, packageId: packageId, entries: entries)
    }

    private static func parseType(_ data: Data, at start: Int, packageId: UInt32, typeNames: [String], keyNames: [String]) throws -> [ResourceEntry] {
        guard let typeId = u8(data, start + 8), let flags = u8(data, start + 9), let entryCount = u32(data, start + 12), let entriesStart = u32(data, start + 16) else {
            throw AxiomError.message("Truncated type chunk at offset \(start).")
        }
        guard flags & 0x01 == 0 else { return [] }   // FLAG_SPARSE entry-offset table: a later add, skip rather than misparse
        let typeName = Int(typeId) >= 1 && Int(typeId) - 1 < typeNames.count ? typeNames[Int(typeId) - 1] : "type\(typeId)"
        var results: [ResourceEntry] = []
        let offsetsStart = start + Int(entriesStart) >= start ? start + 20 : start   // offsets array immediately follows the fixed header + config
        _ = offsetsStart
        let offsetTableStart = start + 20 + configSize(data, start + 20)
        for entryIndex in 0..<Int(entryCount) {
            guard let relativeOffset = u32(data, offsetTableStart + entryIndex * 4), relativeOffset != 0xFFFFFFFF else { continue }
            let entryStart = start + Int(entriesStart) + Int(relativeOffset)
            guard let keyIndex = u32(data, entryStart + 4) else { continue }
            let keyName = Int(keyIndex) < keyNames.count ? keyNames[Int(keyIndex)] : ""
            let id = (packageId << 24) | (UInt32(typeId) << 16) | UInt32(entryIndex)
            results.append(ResourceEntry(id: id, type: typeName, key: keyName))
        }
        return results
    }

    /// ResTable_config's own first field is its byte size, so the offsets array position is
    /// `20 (fixed ResTable_type fields) + config.size`, not a hardcoded constant across versions.
    private static func configSize(_ data: Data, _ offset: Int) -> Int { Int(u32(data, offset) ?? 32) }

    private static func u8(_ data: Data, _ offset: Int) -> UInt8? { offset >= 0 && offset < data.count ? data[data.startIndex + offset] : nil }
    private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }
}
