import Foundation

/// A quick, server-free outline of a source file: declarations found by line patterns, nested by indentation.
/// It is what the jump bar and the Symbols navigator show until (or unless) a language server answers, and the
/// only outline for languages that have no server installed. Positions are 0-based, like the protocol's.
public enum SymbolOutline {
    private struct Rule {
        var regex: NSRegularExpression
        var kind: LSPSymbol.Kind
        var nameGroup: Int
    }

    private static func rules(for language: SyntaxHighlighter.Language) -> [Rule] {
        func rule(_ pattern: String, _ kind: LSPSymbol.Kind, name: Int = 1) -> Rule? {
            (try? NSRegularExpression(pattern: pattern)).map { Rule(regex: $0, kind: kind, nameGroup: name) }
        }
        let modifiers = #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|final|static|class|override|mutating|nonisolated|indirect|required|convenience|lazy|weak|unowned|@MainActor)\s+)*"#
        switch language {
        case .swift:
            return [
                rule(modifiers + #"class\s+(\w+)"#, .class), rule(modifiers + #"struct\s+(\w+)"#, .struct),
                rule(modifiers + #"enum\s+(\w+)"#, .enum), rule(modifiers + #"protocol\s+(\w+)"#, .interface),
                rule(modifiers + #"actor\s+(\w+)"#, .class), rule(modifiers + #"extension\s+([\w.]+)"#, .module),
                rule(modifiers + #"func\s+(\w+|[^\s(<]+)"#, .function), rule(modifiers + #"(init[?!]?)\s*[(<]"#, .constructor),
                rule(modifiers + #"case\s+(\w+)"#, .enumMember), rule(modifiers + #"(?:var|let)\s+(\w+)"#, .property),
            ].compactMap { $0 }
        case .python:
            return [rule(#"^\s*class\s+(\w+)"#, .class), rule(#"^\s*(?:async\s+)?def\s+(\w+)"#, .function)].compactMap { $0 }
        case .javascript, .typescript:
            return [
                rule(#"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+(\w+)"#, .class),
                rule(#"^\s*(?:export\s+)?interface\s+(\w+)"#, .interface), rule(#"^\s*(?:export\s+)?enum\s+(\w+)"#, .enum),
                rule(#"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\*?\s+(\w+)"#, .function),
                rule(#"^\s*(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s*)?(?:\([^)]*\)|\w+)\s*=>"#, .function),
            ].compactMap { $0 }
        case .rust:
            return [
                rule(#"^\s*(?:pub(?:\([^)]*\))?\s+)?struct\s+(\w+)"#, .struct), rule(#"^\s*(?:pub(?:\([^)]*\))?\s+)?enum\s+(\w+)"#, .enum),
                rule(#"^\s*(?:pub(?:\([^)]*\))?\s+)?trait\s+(\w+)"#, .interface), rule(#"^\s*impl(?:<[^>]*>)?\s+([\w:<>]+)"#, .module),
                rule(#"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+(\w+)"#, .function),
            ].compactMap { $0 }
        case .go:
            return [
                rule(#"^type\s+(\w+)\s+struct"#, .struct), rule(#"^type\s+(\w+)\s+interface"#, .interface),
                rule(#"^func\s+(?:\([^)]*\)\s+)?(\w+)"#, .function),
            ].compactMap { $0 }
        case .c:
            return [
                rule(#"^\s*(?:typedef\s+)?(?:struct|class)\s+(\w+)\s*[{:]?"#, .struct), rule(#"^\s*enum\s+(?:class\s+)?(\w+)"#, .enum),
                rule(#"^[A-Za-z_][\w\s\*&:<>,]*?\b(\w+)\s*\([^;]*$"#, .function),
            ].compactMap { $0 }
        case .shell:
            return [rule(#"^\s*(?:function\s+)?(\w+)\s*\(\)\s*\{?"#, .function)].compactMap { $0 }
        case .markdown:
            return [rule(#"^#{1,6}\s+(.+?)\s*#*\s*$"#, .string)].compactMap { $0 }
        default:
            return []
        }
    }

    /// Declarations in `text`, nested by indentation and given an end line (just before the next sibling or parent).
    public static func symbols(in text: String, language: SyntaxHighlighter.Language) -> [LSPSymbol] {
        let rules = rules(for: language)
        guard !rules.isEmpty else { return [] }
        let lines = text.components(separatedBy: "\n")
        struct Flat { var symbol: LSPSymbol; var indent: Int; var depth: Int }
        var flat: [Flat] = []
        var inBlockComment = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlockComment { if trimmed.contains("*/") { inBlockComment = false }; continue }
            if trimmed.hasPrefix("/*") && !trimmed.contains("*/") { inBlockComment = true; continue }
            if trimmed.isEmpty || trimmed.hasPrefix("//") || (trimmed.hasPrefix("#") && language != .markdown && language != .c) { continue }
            let range = NSRange(line.startIndex..., in: line)
            for rule in rules {
                guard let match = rule.regex.firstMatch(in: line, range: range),
                      let nameRange = Range(match.range(at: rule.nameGroup), in: line) else { continue }
                let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                if language == .markdown {
                    let level = line.prefix { $0 == "#" }.count
                    flat.append(Flat(symbol: LSPSymbol(name: String(line[nameRange]), detail: nil, kind: rule.kind, path: nil, line: index,
                                                       column: line.distance(from: line.startIndex, to: nameRange.lowerBound), endLine: index, children: []),
                                     indent: level, depth: 0))
                } else {
                    flat.append(Flat(symbol: LSPSymbol(name: String(line[nameRange]), detail: nil, kind: rule.kind, path: nil, line: index,
                                                       column: line.distance(from: line.startIndex, to: nameRange.lowerBound), endLine: index, children: []),
                                     indent: indent, depth: 0))
                }
                break
            }
        }
        // Build the tree by indentation, dropping variables nested inside functions.
        var roots: [LSPSymbol] = []
        var stack: [(indent: Int, path: [Int])] = []
        func append(_ symbol: LSPSymbol, at path: [Int]) -> [Int] {
            if path.isEmpty { roots.append(symbol); return [roots.count - 1] }
            func insert(_ node: inout LSPSymbol, _ remaining: ArraySlice<Int>) -> Int {
                if let first = remaining.first { return insert(&node.children[first], remaining.dropFirst()) }
                node.children.append(symbol); return node.children.count - 1
            }
            let head = path[0]
            let index = insert(&roots[head], path.dropFirst())
            return path + [index]
        }
        func node(at path: [Int]) -> LSPSymbol {
            var current = roots[path[0]]
            for index in path.dropFirst() { current = current.children[index] }
            return current
        }
        for item in flat {
            while let last = stack.last, last.indent >= item.indent { stack.removeLast() }
            if item.symbol.kind == .property || item.symbol.kind == .variable, let parent = stack.last {
                let parentKind = node(at: parent.path).kind
                if parentKind == .function || parentKind == .constructor || parentKind == .method { continue }
            }
            let path = append(item.symbol, at: stack.last?.path ?? [])
            stack.append((item.indent, path))
        }
        // End lines: a symbol runs until the line before the next symbol at the same or a shallower level.
        func close(_ symbols: inout [LSPSymbol], parentEnd: Int) {
            for index in symbols.indices {
                let end = index + 1 < symbols.count ? symbols[index + 1].line - 1 : parentEnd
                symbols[index].endLine = max(end, symbols[index].line)
                close(&symbols[index].children, parentEnd: symbols[index].endLine)
            }
        }
        close(&roots, parentEnd: max(lines.count - 1, 0))
        return roots
    }
}
