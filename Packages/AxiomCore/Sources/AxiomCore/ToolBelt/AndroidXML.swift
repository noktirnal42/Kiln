import Foundation

// Android binary XML (AXML) parser (docs/KALI_METASPLOIT_PARITY.md T5): reads the chunk-based
// format Android stores AndroidManifest.xml and compiled layout/resource XML in — original
// implementation from the public AOSP chunk-format documentation (frameworks/base ResourceTypes.h
// layout), not a wrapped third-party library. Supports UTF-8 and UTF-16 string pools. Attribute
// values are reported with their raw typed-value data; resolving resource references/styles
// against resources.arsc is a follow-on (needs the ARSC parser's resource table, not just its
// string pool).

public struct AXMLAttribute: Codable, Sendable, Equatable {
    public let name: String
    public let namespace: String?
    /// "string", "reference", "int", "bool", "float", "color", or "raw(0xNN)" for an unrecognized type.
    public let dataType: String
    public let value: String
}

public enum AXMLEvent: Codable, Sendable, Equatable {
    case startElement(name: String, namespace: String?, attributes: [AXMLAttribute])
    case endElement(name: String, namespace: String?)
    case cdata(String)
}

public enum AXMLError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): return text } }
}

public enum AndroidXML {
    static let typeStringPool: UInt16 = 0x0001
    static let typeXML: UInt16 = 0x0003
    static let typeStartElement: UInt16 = 0x0102
    static let typeEndElement: UInt16 = 0x0103
    static let typeCData: UInt16 = 0x0104
    static let maxEvents = 200_000

    public static func parse(_ data: Data) throws -> [AXMLEvent] {
        guard let rootType = u16(data, 0), rootType == typeXML else { throw AxiomError.message("Not AXML (expected RES_XML_TYPE chunk at offset 0).") }
        guard let rootSize = u32(data, 4) else { throw AxiomError.message("Truncated AXML header.") }
        var strings: [String] = []
        var events: [AXMLEvent] = []
        var cursor = 8   // past the 8-byte top-level ResChunk_header (type, headerSize, size)
        let end = min(Int(rootSize), data.count)
        while cursor + 8 <= end, events.count < maxEvents {
            guard let chunkType = u16(data, cursor), let chunkHeaderSize = u16(data, cursor + 2), let chunkSize = u32(data, cursor + 4), chunkSize >= 8 else { break }
            let chunkEnd = cursor + Int(chunkSize)
            switch chunkType {
            case typeStringPool:
                strings = try parseStringPool(data, at: cursor, headerSize: Int(chunkHeaderSize))
            case typeStartElement:
                guard let namespaceIndex = i32(data, cursor + 16), let nameIndex = i32(data, cursor + 20), let attributeCount = u16(data, cursor + 28) else { break }
                let attributeStart = cursor + 36   // past ResXMLTree_node(16) + ResXMLTree_attrExt fixed fields up to attributeCount
                var attributes: [AXMLAttribute] = []
                for index in 0..<Int(attributeCount) {
                    let base = attributeStart + index * 20
                    guard let attrNamespace = i32(data, base), let attrName = i32(data, base + 4), let rawValue = i32(data, base + 8),
                          let dataType = u8(data, base + 15), let value = i32(data, base + 16) else { break }
                    attributes.append(AXMLAttribute(name: name(strings, attrName), namespace: attrNamespace >= 0 ? name(strings, attrNamespace) : nil,
                                                     dataType: typeName(UInt8(dataType)), value: formatValue(strings, dataType: Int32(dataType), rawValue: rawValue, value: value)))
                }
                events.append(.startElement(name: name(strings, nameIndex), namespace: namespaceIndex >= 0 ? name(strings, namespaceIndex) : nil, attributes: attributes))
            case typeEndElement:
                guard let namespaceIndex = i32(data, cursor + 16), let nameIndex = i32(data, cursor + 20) else { break }
                events.append(.endElement(name: name(strings, nameIndex), namespace: namespaceIndex >= 0 ? name(strings, namespaceIndex) : nil))
            case typeCData:
                guard let valueIndex = i32(data, cursor + 16) else { break }
                events.append(.cdata(name(strings, valueIndex)))
            default: break   // namespace start/end and the resource-id map are structural, not reported as events
            }
            guard chunkEnd > cursor else { break }
            cursor = chunkEnd
        }
        return events
    }

    private static func name(_ strings: [String], _ index: Int32) -> String { index >= 0 && Int(index) < strings.count ? strings[Int(index)] : "" }

    private static func typeName(_ dataType: UInt8) -> String {
        switch dataType { case 3: return "string"; case 1: return "reference"; case 0x10: return "int"; case 0x12: return "bool"; case 4: return "float"; case 0x1c, 0x1d, 0x1e, 0x1f: return "color"; default: return "raw(0x" + String(dataType, radix: 16) + ")" }
    }
    private static func formatValue(_ strings: [String], dataType: Int32, rawValue: Int32, value: Int32) -> String {
        if dataType == 3 { return rawValue >= 0 ? name(strings, rawValue) : name(strings, value) }   // TYPE_STRING
        if dataType == 0x12 { return value != 0 ? "true" : "false" }   // TYPE_INT_BOOLEAN
        return String(format: "0x%08x", UInt32(bitPattern: value))
    }

    /// ResStringPool_header: stringCount/styleCount/flags/stringsStart/stylesStart, then an array
    /// of u32 offsets, then the string data itself (UTF-8 or UTF-16, each length-prefixed).
    static func parseStringPool(_ data: Data, at chunkStart: Int, headerSize: Int) throws -> [String] {
        guard let stringCount = u32(data, chunkStart + 8), let flags = u32(data, chunkStart + 16), let stringsStart = u32(data, chunkStart + 20) else {
            throw AxiomError.message("Truncated string pool header.")
        }
        let utf8 = (flags & 0x100) != 0
        let offsetsStart = chunkStart + headerSize
        var result: [String] = []
        for index in 0..<Int(stringCount) {
            guard let relativeOffset = u32(data, offsetsStart + index * 4) else { break }
            let stringOffset = chunkStart + Int(stringsStart) + Int(relativeOffset)
            if utf8 {
                guard let (_, lenBytesConsumed1) = decodeLength8(data, stringOffset),
                      let (byteLength, lenBytesConsumed2) = decodeLength8(data, stringOffset + lenBytesConsumed1) else { result.append(""); continue }
                let start = stringOffset + lenBytesConsumed1 + lenBytesConsumed2
                guard start + byteLength <= data.count else { result.append(""); continue }
                result.append(String(decoding: data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + byteLength)), as: UTF8.self))
            } else {
                guard let (charLength, lenBytesConsumed) = decodeLength16(data, stringOffset) else { result.append(""); continue }
                let start = stringOffset + lenBytesConsumed
                var units: [UInt16] = []
                for unitIndex in 0..<charLength { guard let unit = u16(data, start + unitIndex * 2) else { break }; units.append(unit) }
                result.append(String(decoding: units, as: UTF16.self))
            }
        }
        return result
    }

    /// AXML's variable-length encoding: a length that fits in 7 bits is one byte; otherwise the
    /// high bit is set and two bytes together hold a 15-bit length (used for the UTF-8 pool).
    private static func decodeLength8(_ data: Data, _ offset: Int) -> (length: Int, bytesConsumed: Int)? {
        guard let first = u8(data, offset) else { return nil }
        if first & 0x80 == 0 { return (Int(first), 1) }
        guard let second = u8(data, offset + 1) else { return nil }
        return (Int(first & 0x7f) << 8 | Int(second), 2)
    }
    /// Same idea in 16-bit units (used for the UTF-16 pool): a length under 0x8000 is one u16.
    private static func decodeLength16(_ data: Data, _ offset: Int) -> (length: Int, bytesConsumed: Int)? {
        guard let first = u16(data, offset) else { return nil }
        if first & 0x8000 == 0 { return (Int(first), 2) }
        guard let second = u16(data, offset + 2) else { return nil }
        return (Int(first & 0x7fff) << 16 | Int(second), 4)
    }

    private static func u8(_ data: Data, _ offset: Int) -> UInt8? { offset >= 0 && offset < data.count ? data[data.startIndex + offset] : nil }
    private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }
    private static func i32(_ data: Data, _ offset: Int) -> Int32? { u32(data, offset).map { Int32(bitPattern: $0) } }
}
