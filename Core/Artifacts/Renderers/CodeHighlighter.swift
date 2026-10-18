import Foundation

/// Lightweight bounded syntax highlighter for artifact code. Produces spans
/// (not attributed strings) so the SwiftUI layer stays free of text layout.
/// Supports a shared C-family/keyword profile plus Python and shell; anything
/// else falls back to the keyword profile.
public enum CodeHighlighter {
    public enum TokenKind: String, Sendable, CaseIterable {
        case plain, keyword, string, comment, number, type, function
    }

    public struct Span: Equatable, Sendable {
        public let text: String
        public let kind: TokenKind

        public init(text: String, kind: TokenKind) {
            self.text = text
            self.kind = kind
        }
    }

    public static let inputLimit = 256 * 1024

    private static let sharedKeywords: Set<String> = [
        "if", "else", "for", "while", "return", "break", "continue", "switch", "case", "default",
        "func", "fn", "function", "let", "var", "const", "class", "struct", "enum", "protocol",
        "import", "export", "from", "package", "public", "private", "protected", "static", "final",
        "try", "catch", "throw", "throws", "async", "await", "defer", "guard", "in", "is", "as",
        "new", "this", "self", "super", "nil", "null", "true", "false", "typealias", "extension",
        "where", "do", "then", "elif", "with", "lambda", "yield", "match", "impl", "use", "pub",
        "mut", "trait", "unsafe", "when", "and", "or", "not", "None", "True", "False", "pass",
    ]

    private static let lineComments = ["//", "#", "--"]

    public static func highlight(_ code: String, language: String? = nil) -> [Span] {
        guard code.utf8.count <= inputLimit else {
            return [Span(text: String(code.prefix(1024)) + "\n… (truncated at \(inputLimit / 1024) KiB)", kind: .plain)]
        }
        var spans: [Span] = []
        var plain = ""
        var index = code.startIndex
        var previousWord = ""

        func flushPlain() {
            if !plain.isEmpty {
                spans.append(Span(text: plain, kind: .plain))
                plain = ""
            }
        }

        while index < code.endIndex {
            let character = code[index]

            if character == "/" || character == "#" || character == "-" {
                let next = code.index(after: index)
                let two = next < code.endIndex ? String(code[index...next]) : ""
                if two == "//" || two == "/*" || (character == "#" && isHashComment(language)) || two == "--" {
                    flushPlain()
                    let comment = consumeComment(code, from: index, blockStart: two == "/*")
                    spans.append(Span(text: comment, kind: .comment))
                    index = code.index(index, offsetBy: comment.count, limitedBy: code.endIndex) ?? code.endIndex
                    continue
                }
            }

            if character == "\"" || character == "'" {
                flushPlain()
                let string = consumeString(code, from: index, quote: character)
                spans.append(Span(text: string, kind: .string))
                index = code.index(index, offsetBy: string.count, limitedBy: code.endIndex) ?? code.endIndex
                continue
            }

            if character.isNumber, previousWord.allSatisfy({ !$0.isLetter && $0 != "_" }) {
                flushPlain()
                let number = consumeWhile(code, from: index) { $0.isNumber || $0 == "." || $0 == "_" || $0.lowercased() == "x" || ($0.isLetter && isHexDigitContext(code, index)) }
                spans.append(Span(text: number, kind: .number))
                index = code.index(index, offsetBy: number.count, limitedBy: code.endIndex) ?? code.endIndex
                previousWord = ""
                continue
            }

            if character.isLetter || character == "_" {
                let word = consumeWhile(code, from: index) { $0.isLetter || $0.isNumber || $0 == "_" }
                flushPlain()
                let isDeclaration = followedByParen(code, after: index, offset: word.count)
                let kind: TokenKind
                if sharedKeywords.contains(word) {
                    kind = .keyword
                } else if isDeclaration {
                    kind = .function
                } else if word.first?.isUppercase == true {
                    kind = .type
                } else {
                    kind = .plain
                }
                spans.append(Span(text: word, kind: kind))
                index = code.index(index, offsetBy: word.count, limitedBy: code.endIndex) ?? code.endIndex
                previousWord = word
                continue
            }

            plain.append(character)
            if !character.isLetter && !character.isNumber { previousWord = "" }
            index = code.index(after: index)
        }
        flushPlain()
        return spans
    }

    private static func isHashComment(_ language: String?) -> Bool {
        guard let language else { return true }
        let lowered = language.lowercased()
        return ["python", "py", "shell", "sh", "bash", "zsh", "yaml", "yml", "ruby", "rb", "toml", "r", "perl"].contains(lowered)
    }

    private static func isHexDigitContext(_ code: String, _ index: String.Index) -> Bool {
        guard let previous = code.index(index, offsetBy: -1, limitedBy: code.startIndex) else { return false }
        return code[previous] == "0"
    }

    private static func consumeComment(_ code: String, from index: String.Index, blockStart: Bool) -> String {
        if blockStart {
            if let end = code.range(of: "*/", range: index..<code.endIndex)?.lowerBound {
                return String(code[index...end])
            }
            return String(code[index...])
        }
        return String(code[index...].prefix(while: { $0 != "\n" }))
    }

    private static func consumeString(_ code: String, from index: String.Index, quote: Character) -> String {
        var result = String(quote)
        var cursor = code.index(after: index)
        var escaped = false
        while cursor < code.endIndex {
            let character = code[cursor]
            result.append(character)
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == quote || character == "\n" {
                break
            }
            cursor = code.index(after: cursor)
        }
        return result
    }

    private static func consumeWhile(_ code: String, from index: String.Index, _ predicate: (Character) -> Bool) -> String {
        var result = ""
        var cursor = index
        while cursor < code.endIndex, predicate(code[cursor]) {
            result.append(code[cursor])
            cursor = code.index(after: cursor)
        }
        return result
    }

    private static func followedByParen(_ code: String, after index: String.Index, offset: Int) -> Bool {
        guard let after = code.index(index, offsetBy: offset, limitedBy: code.endIndex) else { return false }
        var cursor = after
        while cursor < code.endIndex, code[cursor] == " " {
            cursor = code.index(after: cursor)
        }
        return cursor < code.endIndex && code[cursor] == "("
    }
}
