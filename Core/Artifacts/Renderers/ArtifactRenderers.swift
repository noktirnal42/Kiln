import Foundation

/// Bounded GFM-subset block parser for artifact markdown. The UI renders the
/// returned blocks; inline formatting (bold/italic/code/links) is applied via
/// AttributedString(markdown:) in the view layer. Tables and fences are
/// parsed structurally; everything unsupported stays as a paragraph rather
/// than being dropped.
public enum MarkdownRenderer {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case codeFence(language: String?, code: String)
        case listItem(ordered: Bool, text: String, indent: Int)
        case blockquote(text: String)
        case table(header: [String], rows: [[String]])
        case divider
    }

    public static let inputLimit = 1024 * 1024

    public static func parse(_ markdown: String) -> [Block] {
        guard markdown.utf8.count <= inputLimit else {
            return [.paragraph(text: "… (markdown truncated at \(inputLimit / 1024) KiB)")]
        }
        var blocks: [Block] = []
        let lines = markdown.components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.codeFence(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                continue
            }

            if let heading = Self.headingLevel(of: line) {
                blocks.append(.heading(level: heading, text: String(line.dropFirst(heading)).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }

            if isDivider(line) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if isTableLine(line), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                let header = parseTableRow(line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, isTableLine(lines[index]) {
                    rows.append(parseTableRow(lines[index]))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let list = Self.listItem(of: line) {
                blocks.append(.listItem(ordered: list.ordered, text: list.text, indent: list.indent))
                index += 1
                continue
            }

            if line.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count, lines[index].hasPrefix(">") {
                    quote.append(String(lines[index].dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.blockquote(text: quote.joined(separator: " ")))
                continue
            }

            var paragraph: [String] = []
            while index < lines.count {
                let current = lines[index]
                if current.trimmingCharacters(in: .whitespaces).isEmpty
                    || current.hasPrefix("```")
                    || current.hasPrefix(">")
                    || current.hasPrefix("#")
                    || Self.listItem(of: current) != nil
                    || isDivider(current) {
                    break
                }
                paragraph.append(current)
                index += 1
            }
            blocks.append(.paragraph(text: paragraph.joined(separator: " ")))
        }
        return blocks
    }

    static func headingLevel(of line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return level
    }

    static func listItem(of line: String) -> (ordered: Bool, text: String, indent: Int)? {
        let leading = line.prefix(while: { $0 == " " }).count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return (false, String(trimmed.dropFirst(2)), leading)
        }
        if let match = trimmed.firstIndex(of: "."), trimmed.startIndex..<trimmed.endIndex ~= match {
            let prefix = trimmed[trimmed.startIndex..<match]
            if !prefix.isEmpty, prefix.allSatisfy(\.isNumber) {
                let after = trimmed.index(after: match)
                guard after < trimmed.endIndex, trimmed[after] == " " else { return nil }
                return (true, String(trimmed[trimmed.index(after: after)...]), leading)
            }
        }
        return nil
    }

    static func isDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return (trimmed == "---" || trimmed == "***" || trimmed == "___") && !trimmed.isEmpty
    }

    static func isTableLine(_ line: String) -> Bool {
        line.contains("|") && line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { $0 == "-" || $0 == "|" || $0 == ":" || $0 == " " }
    }

    static func parseTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Parses CSV or JSON array-of-objects into a display table. Bounded.
public enum DataTableParser {
    public struct Table: Equatable, Sendable {
        public var columns: [String]
        public var rows: [[String]]

        public init(columns: [String], rows: [[String]]) {
            self.columns = columns
            self.rows = rows
        }
    }

    public static let maxRows = 10_000
    public static let maxColumns = 256

    public enum ParseError: Error, Equatable, Sendable {
        case unsupported(String)
        case tooManyRows(limit: Int)
    }

    public static func parse(_ content: Data) throws -> Table {
        if let object = try? JSONSerialization.jsonObject(with: content) {
            if let array = object as? [[String: Any]] {
                return try table(fromObjects: array)
            }
            if let array = object as? [Any] {
                return Table(columns: ["value"], rows: array.prefix(maxRows).map { [stringify($0)] })
            }
        }
        guard let text = String(data: content, encoding: .utf8) else {
            throw ParseError.unsupported("content is neither JSON nor UTF-8 CSV")
        }
        return try parseCSV(text)
    }

    static func table(fromObjects array: [[String: Any]]) throws -> Table {
        guard array.count <= maxRows else { throw ParseError.tooManyRows(limit: maxRows) }
        var columnSet: Set<String> = []
        for object in array.prefix(100) {
            columnSet.formUnion(object.keys)
        }
        // JSONSerialization loses key order; sort for a stable column layout.
        let columns = columnSet.sorted()
        guard columns.count <= maxColumns else { throw ParseError.unsupported("more than \(maxColumns) columns") }
        let rows = array.map { object in columns.map { stringify(object[$0]) } }
        return Table(columns: columns, rows: rows)
    }

    static func parseCSV(_ text: String) throws -> Table {
        var rows: [[String]] = []
        var current: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var character = iterator.next()

        func endField() {
            current.append(field)
            field = ""
        }

        func endRow() {
            endField()
            if !(current.count == 1 && current[0].isEmpty) {
                rows.append(current)
            }
            current = []
        }

        while let c = character {
            if inQuotes {
                if c == "\"" {
                    let peek = iterator.next()
                    if peek == "\"" {
                        field.append("\"")
                        character = iterator.next()
                        continue
                    } else {
                        inQuotes = false
                        character = peek
                        continue
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    endField()
                case "\r":
                    break
                case "\n":
                    endRow()
                default:
                    field.append(c)
                }
            }
            character = iterator.next()
        }
        if !field.isEmpty || !current.isEmpty { endRow() }
        guard rows.count <= maxRows + 1 else { throw ParseError.tooManyRows(limit: maxRows) }
        guard var columns = rows.first else { return Table(columns: [], rows: []) }
        columns = columns.map { $0.isEmpty ? "column" : $0 }
        let dataRows = rows.dropFirst().prefix(maxRows).map { row -> [String] in
            var padded = row
            if padded.count < columns.count {
                padded.append(contentsOf: Array(repeating: "", count: columns.count - padded.count))
            }
            return Array(padded.prefix(columns.count))
        }
        return Table(columns: columns, rows: Array(dataRows))
    }

    static func stringify(_ value: Any?) -> String {
        switch value {
        case nil: return ""
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case let bool as Bool: return bool ? "true" : "false"
        default: return String(describing: value)
        }
    }
}
