import Foundation

public enum TokenKind: Sendable {
    case comment, string, number, keyword, type, attribute
}

public struct HighlightSpan: Equatable, Sendable {
    public var range: NSRange
    public var kind: TokenKind
}

/// Small regex-based highlighter. It is deliberately simple (no language server): comments, strings, numbers,
/// keywords and capitalised type names for the languages Kiln users open most.
public enum SyntaxHighlighter {
    public enum Language: String, Sendable {
        case swift, python, javascript, typescript, json, markdown, shell, c, rust, go, yaml, html, plain
    }

    public static func language(for url: URL) -> Language {
        switch url.pathExtension.lowercased() {
        case "swift": .swift
        case "py": .python
        case "js", "jsx", "mjs", "cjs": .javascript
        case "ts", "tsx": .typescript
        case "json", "jsonc": .json
        case "md", "markdown": .markdown
        case "sh", "zsh", "bash": .shell
        case "c", "h", "m", "mm", "cpp", "hpp", "cc", "metal": .c
        case "rs": .rust
        case "go": .go
        case "yml", "yaml", "toml": .yaml
        case "html", "htm", "xml", "plist": .html
        default: .plain
        }
    }

    private static let keywords: [Language: [String]] = [
        .swift: ["actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else",
                 "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init",
                 "inout", "internal", "is", "let", "nil", "nonisolated", "open", "operator", "override", "private", "protocol",
                 "public", "repeat", "return", "self", "Self", "static", "struct", "subscript", "super", "switch", "throw", "throws",
                 "true", "try", "typealias", "var", "where", "while", "some", "any"],
        .python: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except",
                  "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or",
                  "pass", "raise", "return", "True", "try", "while", "with", "yield"],
        .javascript: ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else",
                      "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let",
                      "new", "null", "of", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var",
                      "void", "while", "yield"],
        .shell: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "in", "return",
                 "export", "local", "set", "unset", "echo"],
        .c: ["auto", "break", "case", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extern",
             "float", "for", "if", "inline", "int", "long", "namespace", "nil", "NULL", "return", "short", "signed", "sizeof",
             "static", "struct", "switch", "template", "typedef", "union", "unsigned", "using", "void", "volatile", "while"],
        .rust: ["as", "async", "await", "break", "const", "continue", "crate", "else", "enum", "false", "fn", "for", "if", "impl",
                "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct",
                "super", "trait", "true", "type", "unsafe", "use", "where", "while"],
        .go: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto",
              "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"],
        .json: ["true", "false", "null"],
        .yaml: ["true", "false", "null", "yes", "no"],
    ]

    private struct Rule {
        var pattern: String
        var kind: TokenKind
        var options: NSRegularExpression.Options = []
    }

    private static func rules(for language: Language) -> [Rule] {
        var list: [Rule] = []
        switch language {
        case .plain: return []
        case .markdown:
            return [Rule(pattern: "^#{1,6} .*$", kind: .keyword, options: [.anchorsMatchLines]),
                    Rule(pattern: "`[^`\\n]+`", kind: .string),
                    Rule(pattern: "^```.*$", kind: .comment, options: [.anchorsMatchLines])]
        case .html:
            return [Rule(pattern: "<!--[\\s\\S]*?-->", kind: .comment),
                    Rule(pattern: "\"[^\"\\n]*\"", kind: .string),
                    Rule(pattern: "</?[A-Za-z][A-Za-z0-9:-]*", kind: .keyword)]
        default: break
        }
        switch language {
        case .python, .shell, .yaml:
            list.append(Rule(pattern: "#.*$", kind: .comment, options: [.anchorsMatchLines]))
        case .json:
            break
        default:
            list.append(Rule(pattern: "/\\*[\\s\\S]*?\\*/", kind: .comment))
            list.append(Rule(pattern: "//.*$", kind: .comment, options: [.anchorsMatchLines]))
        }
        list.append(Rule(pattern: "\"\"\"[\\s\\S]*?\"\"\"", kind: .string))
        list.append(Rule(pattern: "\"(?:\\\\.|[^\"\\\\\\n])*\"", kind: .string))
        if language != .json { list.append(Rule(pattern: "'(?:\\\\.|[^'\\\\\\n])*'", kind: .string)) }
        if language == .javascript || language == .typescript { list.append(Rule(pattern: "`(?:\\\\.|[^`\\\\])*`", kind: .string)) }
        list.append(Rule(pattern: "\\b0x[0-9A-Fa-f_]+\\b|\\b\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b", kind: .number))
        if language == .swift { list.append(Rule(pattern: "@[A-Za-z_][A-Za-z0-9_]*|#[a-z]+", kind: .attribute)) }
        let words = keywords[language == .typescript ? .javascript : language] ?? []
        if !words.isEmpty {
            list.append(Rule(pattern: "\\b(?:" + words.joined(separator: "|") + ")\\b", kind: .keyword))
        }
        if language != .json && language != .yaml && language != .shell {
            list.append(Rule(pattern: "\\b[A-Z][A-Za-z0-9_]*\\b", kind: .type))
        }
        return list
    }

    /// Spans in priority order: earlier rules (comments, strings) claim text, later rules never overlap them.
    public static func spans(in text: String, language: Language) -> [HighlightSpan] {
        let source = text as NSString
        guard source.length > 0, source.length < 400_000 else { return [] }
        var claimed = IndexSet()
        var result: [HighlightSpan] = []
        for rule in rules(for: language) {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
                guard let range = match?.range, range.length > 0 else { return }
                let span = range.location..<(range.location + range.length)
                if claimed.intersects(integersIn: span) { return }
                claimed.insert(integersIn: span)
                result.append(HighlightSpan(range: range, kind: rule.kind))
            }
        }
        return result
    }
}
