import Foundation
import AxiomCore

// Per-project analyst data that does not belong in the engine's analysis file: data types and structures, address bookmarks,
// patches, and findings. It lives beside `analysis.json` in `kiln-workspace.json`, so re-analysing a binary never touches it.

public struct REStructField: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(offset):\(name)" }
    public var offset: Int
    public var name: String
    public var type: String
    public var size: Int
    public var comment: String = ""
}

public struct REStructure: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var size: Int
    public var alignment: Int
    public var isUnion = false
    public var fields: [REStructField]

    /// The C declaration this structure round-trips through.
    public var declaration: String {
        let keyword = isUnion ? "union" : "struct"
        var lines = ["\(keyword) \(name) {"]
        var cursor = 0
        for field in fields {
            if !isUnion, field.offset > cursor { lines.append("    char _pad_\(String(cursor, radix: 16))[\(field.offset - cursor)];") }
            let declarator = field.type.contains("[") ? field.type.replacingOccurrences(of: "[", with: " \(field.name)[") : "\(field.type) \(field.name)"
            lines.append("    \(declarator);" + (field.comment.isEmpty ? "" : " // \(field.comment)") + "   /* +0x\(String(field.offset, radix: 16)), \(field.size) */")
            cursor = field.offset + field.size
        }
        if !isUnion, size > cursor { lines.append("    char _pad_\(String(cursor, radix: 16))[\(size - cursor)];") }
        return lines.joined(separator: "\n") + "\n};"
    }

    public func field(at offset: Int) -> REStructField? { fields.first { offset >= $0.offset && offset < $0.offset + max($0.size, 1) } }
}

/// Parses C-style `struct` and `union` declarations into laid-out structures with natural alignment (the layout a C compiler
/// would give them on arm64 and x86_64), and renders structures back out.
public enum REStructureParser {
    static let primitives: [String: Int] = [
        "char": 1, "signed char": 1, "unsigned char": 1, "bool": 1, "_Bool": 1, "int8_t": 1, "uint8_t": 1, "byte": 1, "BOOL": 1,
        "short": 2, "unsigned short": 2, "int16_t": 2, "uint16_t": 2, "wchar_t": 4,
        "int": 4, "unsigned": 4, "unsigned int": 4, "int32_t": 4, "uint32_t": 4, "float": 4, "dword": 4,
        "long": 8, "unsigned long": 8, "long long": 8, "unsigned long long": 8, "int64_t": 8, "uint64_t": 8, "size_t": 8, "ssize_t": 8,
        "uintptr_t": 8, "intptr_t": 8, "double": 8, "qword": 8, "off_t": 8, "time_t": 8,
    ]

    public static func parse(_ source: String, existing: [REStructure] = []) throws -> [REStructure] {
        var cleaned = ""
        // Strip comments.
        var index = source.startIndex
        while index < source.endIndex {
            if source[index...].hasPrefix("//") { while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) } }
            else if source[index...].hasPrefix("/*"), let end = source.range(of: "*/", range: index..<source.endIndex) { index = end.upperBound }
            else { cleaned.append(source[index]); index = source.index(after: index) }
        }
        var known = Dictionary(existing.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [REStructure] = []
        var rest = cleaned[...]
        while let keyword = rest.range(of: #"\b(struct|union)\s+([A-Za-z_]\w*)\s*\{"#, options: .regularExpression) {
            let header = String(rest[keyword])
            let isUnion = header.hasPrefix("union")
            let name = header.dropFirst(isUnion ? 5 : 6).replacingOccurrences(of: "{", with: "").trimmingCharacters(in: .whitespaces)
            guard let close = matchingBrace(in: rest, from: rest.index(before: keyword.upperBound)) else { throw REError.invalidArgument("unterminated struct \(name)") }
            let body = rest[keyword.upperBound..<close]
            let structure = try layout(name: name, isUnion: isUnion, body: String(body), known: known)
            known[name] = structure; result.append(structure)
            rest = rest[rest.index(after: close)...]
        }
        guard !result.isEmpty else { throw REError.invalidArgument("no struct or union declaration found; expected `struct Name { int field; ... };`") }
        return result
    }

    private static func matchingBrace(in text: Substring, from open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 } else if text[index] == "}" { depth -= 1; if depth == 0 { return index } }
            index = text.index(after: index)
        }
        return nil
    }

    static func layout(name: String, isUnion: Bool, body: String, known: [String: REStructure]) throws -> REStructure {
        var fields: [REStructField] = []
        var offset = 0, maxAlign = 1, maxSize = 0
        for statement in body.split(separator: ";") {
            let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if text.contains(":") && !text.contains("::") { throw REError.invalidArgument("bit-fields are not supported: \(text)") }
            // Split `type name[N]` / `type *name` into type and declarator.
            guard let match = text.range(of: #"([A-Za-z_]\w*)\s*((\[\s*\w+\s*\])*)\s*$"#, options: .regularExpression) else { throw REError.invalidArgument("cannot read field: \(text)") }
            let tail = String(text[match])
            let fieldName = String(tail.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            var baseType = String(text[text.startIndex..<match.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !fieldName.isEmpty, !baseType.isEmpty else { throw REError.invalidArgument("cannot read field: \(text)") }
            var count = 1
            let arrays = tail.dropFirst(fieldName.count).split(separator: "[").map { $0.replacingOccurrences(of: "]", with: "").trimmingCharacters(in: .whitespaces) }
            for dimension in arrays {
                guard let n = Int(dimension.hasPrefix("0x") ? String(dimension.dropFirst(2)) : dimension, radix: dimension.hasPrefix("0x") ? 16 : 10), n > 0, n <= 1 << 20 else {
                    throw REError.invalidArgument("array size '\(dimension)' must be a number from 1 to 1048576") }
                count *= n
            }
            baseType = baseType.replacingOccurrences(of: "const ", with: "").replacingOccurrences(of: "volatile ", with: "").replacingOccurrences(of: "struct ", with: "")
                .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            let (size, align) = try measure(baseType, known: known)
            if !isUnion { offset = (offset + align - 1) / align * align }
            let total = size * count
            let displayType = baseType + (arrays.isEmpty ? "" : arrays.map { "[\($0)]" }.joined())
            fields.append(REStructField(offset: isUnion ? 0 : offset, name: fieldName, type: displayType, size: total))
            maxAlign = max(maxAlign, align)
            if isUnion { maxSize = max(maxSize, total) } else { offset += total }
        }
        guard !fields.isEmpty else { throw REError.invalidArgument("struct \(name) has no fields") }
        let raw = isUnion ? maxSize : offset
        return REStructure(name: name, size: (raw + maxAlign - 1) / maxAlign * maxAlign, alignment: maxAlign, isUnion: isUnion, fields: fields)
    }

    static func measure(_ type: String, known: [String: REStructure]) throws -> (size: Int, align: Int) {
        if type.contains("*") { return (8, 8) }
        if let size = primitives[type] { return (size, size) }
        if let nested = known[type] { return (nested.size, nested.alignment) }
        throw REError.invalidArgument("unknown type '\(type)'; define it first or use a basic type (int, uint64_t, char *, ...)")
    }
}

public struct REBookmark: Codable, Sendable, Equatable, Identifiable {
    public var id: String { address }
    public var address: String
    public var note: String
    public var date = Date()
}

public struct REFinding: Codable, Sendable, Equatable, Identifiable {
    public enum Severity: String, Codable, Sendable, CaseIterable { case info, low, medium, high, critical }
    public var id = UUID().uuidString
    public var title: String
    public var severity: Severity = .info
    public var summary: String
    /// Address and function the finding is about (links in the pane); evidence is free text such as a listing excerpt.
    public var address: String?
    public var function: String?
    public var evidence: [String] = []
    /// File names under the project's `attachments` folder (screenshots).
    public var attachments: [String] = []
    public var source: String = "analyst"
    public var created = Date()
}

public struct REWorkspace: Codable, Sendable, Equatable {
    public var structures: [REStructure] = []
    public var structureHistory: [[REStructure]] = []
    public var structureRedo: [[REStructure]] = []
    public var bookmarks: [REBookmark] = []
    public var patches: [REPatch] = []
    public var findings: [REFinding] = []

    public mutating func setStructures(_ new: [REStructure]) {
        structureHistory.append(structures); if structureHistory.count > 50 { structureHistory.removeFirst() }
        structureRedo = []; structures = new
    }
    public mutating func undoStructures() -> Bool {
        guard let previous = structureHistory.popLast() else { return false }
        structureRedo.append(structures); structures = previous; return true
    }
    public mutating func redoStructures() -> Bool {
        guard let next = structureRedo.popLast() else { return false }
        structureHistory.append(structures); structures = next; return true
    }
}

public enum REWorkspaceStore {
    public static func url(_ projectFolder: URL) -> URL { projectFolder.appendingPathComponent("kiln-workspace.json") }
    public static func load(_ projectFolder: URL) -> REWorkspace {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(projectFolder)), let workspace = try? decoder.decode(REWorkspace.self, from: data) else { return REWorkspace() }
        return workspace
    }
    public static func save(_ workspace: REWorkspace, to projectFolder: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(workspace).write(to: url(projectFolder), options: .atomic)
    }
    public static func attachmentsFolder(_ projectFolder: URL) -> URL { projectFolder.appendingPathComponent("attachments", isDirectory: true) }
}
