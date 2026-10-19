import Foundation

// DEX (Dalvik Executable) parser (docs/KALI_METASPLOIT_PARITY.md T5): original implementation
// from the public Android DEX format spec (source.android.com/docs/core/runtime/dex-format).
// Scope: the fixed header, string/type/method/field tables, and class definitions with names
// resolved — a "what's in this dex" listing (class/method/field names), not a disassembler.
// Bytecode disassembly (walking class_data_item and the instruction stream) is a later add; this
// gives apktool/jadx-class static identification without it.

public struct DexHeader: Codable, Sendable, Equatable {
    public let version: String
    public let checksum: UInt32
    public let signatureHex: String
    public let fileSize: Int
    public let stringCount: Int, typeCount: Int, protoCount: Int, fieldCount: Int, methodCount: Int, classCount: Int
}

public struct DexMethod: Codable, Sendable, Equatable { public let className: String; public let name: String; public let shorty: String }
public struct DexField: Codable, Sendable, Equatable { public let className: String; public let typeName: String; public let name: String }
public struct DexClass: Codable, Sendable, Equatable { public let name: String; public let superclassName: String?; public let accessFlags: UInt32; public let sourceFile: String? }

public struct DexListing: Codable, Sendable, Equatable {
    public let header: DexHeader
    public let types: [String]
    public let methods: [DexMethod]
    public let fields: [DexField]
    public let classes: [DexClass]
}

public enum DexFile {
    static let headerSize = 112
    static let maxItems = 500_000

    public static func parse(_ data: Data) throws -> DexListing {
        guard data.count >= headerSize else { throw AxiomError.message("Too short to be a DEX file.") }
        guard data[data.startIndex] == 0x64, data[data.startIndex + 1] == 0x65, data[data.startIndex + 2] == 0x78, data[data.startIndex + 3] == 0x0a else {
            throw AxiomError.message("Not a DEX file (bad magic; expected 'dex\\n').")
        }
        let version = String(decoding: data.subdata(in: (data.startIndex + 4)..<(data.startIndex + 7)), as: UTF8.self)
        guard let checksum = u32(data, 8) else { throw AxiomError.message("Truncated DEX header.") }
        let signature = data.subdata(in: (data.startIndex + 12)..<(data.startIndex + 32))
        guard let fileSize = u32(data, 32),
              let stringIdsSize = u32(data, 56), let stringIdsOff = u32(data, 60),
              let typeIdsSize = u32(data, 64), let typeIdsOff = u32(data, 68),
              let protoIdsSize = u32(data, 72),
              let fieldIdsSize = u32(data, 80), let fieldIdsOff = u32(data, 84),
              let methodIdsSize = u32(data, 88), let methodIdsOff = u32(data, 92),
              let classDefsSize = u32(data, 96), let classDefsOff = u32(data, 100) else { throw AxiomError.message("Truncated DEX header.") }
        guard Int(stringIdsSize) <= maxItems, Int(typeIdsSize) <= maxItems, Int(methodIdsSize) <= maxItems, Int(fieldIdsSize) <= maxItems, Int(classDefsSize) <= maxItems else {
            throw AxiomError.message("Declared table size exceeds the parser's bound; truncated or corrupt DEX.")
        }

        var strings: [String] = []
        for index in 0..<Int(stringIdsSize) {
            guard let dataOffset = u32(data, Int(stringIdsOff) + index * 4), let (_, consumed) = uleb128(data, Int(dataOffset)) else { strings.append(""); continue }
            strings.append(readMUTF8(data, from: Int(dataOffset) + consumed))
        }
        func string(_ index: UInt32) -> String { Int(index) < strings.count ? strings[Int(index)] : "" }

        var types: [String] = []
        for index in 0..<Int(typeIdsSize) {
            guard let descriptorIndex = u32(data, Int(typeIdsOff) + index * 4) else { types.append(""); continue }
            types.append(typeDescriptorToName(string(descriptorIndex)))
        }
        func type(_ index: UInt32) -> String { Int(index) < types.count ? types[Int(index)] : "" }

        var protoShorties: [String] = []
        let protoIdsOff = u32(data, 76) ?? 0
        for index in 0..<Int(protoIdsSize) {
            guard let shortyIndex = u32(data, Int(protoIdsOff) + index * 12) else { protoShorties.append(""); continue }
            protoShorties.append(string(shortyIndex))
        }

        var methods: [DexMethod] = []
        for index in 0..<Int(methodIdsSize) {
            let base = Int(methodIdsOff) + index * 8
            guard let classIndex = u16(data, base), let protoIndex = u16(data, base + 2), let nameIndex = u32(data, base + 4) else { continue }
            methods.append(DexMethod(className: type(UInt32(classIndex)), name: string(nameIndex), shorty: Int(protoIndex) < protoShorties.count ? protoShorties[Int(protoIndex)] : ""))
        }

        var fields: [DexField] = []
        for index in 0..<Int(fieldIdsSize) {
            let base = Int(fieldIdsOff) + index * 8
            guard let classIndex = u16(data, base), let typeIndex = u16(data, base + 2), let nameIndex = u32(data, base + 4) else { continue }
            fields.append(DexField(className: type(UInt32(classIndex)), typeName: type(UInt32(typeIndex)), name: string(nameIndex)))
        }

        var classes: [DexClass] = []
        for index in 0..<Int(classDefsSize) {
            let base = Int(classDefsOff) + index * 32
            guard let classIndex = u32(data, base), let accessFlags = u32(data, base + 4), let superclassIndex = u32(data, base + 8), let sourceFileIndex = u32(data, base + 16) else { continue }
            let superclass = superclassIndex == 0xFFFFFFFF ? nil : type(superclassIndex)
            let sourceFile = sourceFileIndex == 0xFFFFFFFF ? nil : string(sourceFileIndex)
            classes.append(DexClass(name: type(classIndex), superclassName: superclass, accessFlags: accessFlags, sourceFile: sourceFile))
        }

        let header = DexHeader(version: version, checksum: checksum, signatureHex: signature.map { String(format: "%02x", $0) }.joined(), fileSize: Int(fileSize),
                                stringCount: Int(stringIdsSize), typeCount: Int(typeIdsSize), protoCount: Int(protoIdsSize), fieldCount: Int(fieldIdsSize), methodCount: Int(methodIdsSize), classCount: Int(classDefsSize))
        return DexListing(header: header, types: types, methods: methods, fields: fields, classes: classes)
    }

    /// "Lcom/example/Foo;" -> "com.example.Foo"; primitives map to their names (I → int, Z →
    /// boolean, …); array descriptors are returned as-is (no package-style name to resolve).
    static func typeDescriptorToName(_ descriptor: String) -> String {
        guard descriptor.hasPrefix("L"), descriptor.hasSuffix(";") else {
            switch descriptor {
            case "B": return "byte"
            case "C": return "char"
            case "D": return "double"
            case "F": return "float"
            case "I": return "int"
            case "J": return "long"
            case "S": return "short"
            case "V": return "void"
            case "Z": return "boolean"
            default: return descriptor
            }
        }
        return String(descriptor.dropFirst().dropLast()).replacingOccurrences(of: "/", with: ".")
    }

    /// Modified UTF-8: identical to UTF-8 for the ASCII/BMP common case (which covers virtually
    /// all real class/method/field names); the embedded-NUL and surrogate-pair encodings DEX's
    /// MUTF-8 uses for codepoints outside that range are a follow-on, not handled here.
    static func readMUTF8(_ data: Data, from offset: Int) -> String {
        var end = offset
        while end < data.count, data[data.startIndex + end] != 0 { end += 1 }
        guard end > offset else { return "" }
        return String(decoding: data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end)), as: UTF8.self)
    }

    static func uleb128(_ data: Data, _ offset: Int) -> (value: UInt32, bytesConsumed: Int)? {
        var result: UInt32 = 0, shift: UInt32 = 0, consumed = 0
        while offset + consumed < data.count, consumed < 5 {
            let byte = data[data.startIndex + offset + consumed]
            result |= UInt32(byte & 0x7f) << shift
            consumed += 1
            if byte & 0x80 == 0 { return (result, consumed) }
            shift += 7
        }
        return nil
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }
}
