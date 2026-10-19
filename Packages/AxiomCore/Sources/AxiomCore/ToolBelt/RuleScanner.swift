import Foundation

// Rule scanner (docs/KALI_METASPLOIT_PARITY.md T3): an original pattern-matching engine that
// reads the common YARA rule syntax as data, so public rule packs work without bundling anyone's
// engine. Implemented subset, stated plainly: literal strings (nocase/wide/ascii/fullword),
// hex patterns with ?? and nibble wildcards, [n]/[n-m]/[+] jumps and single-byte alternations,
// regular expressions over Latin-1 bytes, and a condition language of and/or/not, string
// presence, `at`/`in` placement, `N of them|($a,$b)`, any/all, filesize and uint8/16/32
// (little-endian) comparisons. Anything outside the subset is a compile error, never a silent
// approximation. Matching is bounded by per-string hit caps and a step budget.

public enum RuleSyntaxError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): return text } }
}

public indirect enum RuleCondition {
    case boolLit(Bool)
    case stringPresent(String)
    case at(String, Int)
    case inRange(String, ClosedRange<Int>)
    case of(count: Int, identifiers: [String]?, them: Bool)
    case comparison(RuleValue, RuleComparison, RuleValue)
    case uintComparison(Int, Int, RuleComparison, Int)   // size in bytes, offset, comparison, constant
    case not(RuleCondition)
    case all([RuleCondition])
    case any([RuleCondition])
}

public enum RuleValue {
    case constant(Int)
    case filesize
}

public enum RuleComparison: String {
    case eq = "==", ne = "!=", lt = "<", le = "<=", gt = ">", ge = ">="
    func evaluate(_ left: Int, _ right: Int) -> Bool {
        switch self {
        case .eq: return left == right
        case .ne: return left != right
        case .lt: return left < right
        case .le: return left <= right
        case .gt: return left > right
        case .ge: return left >= right
        }
    }
}

public struct RuleStringDef {
    public enum Kind { case literal(String), hex([HexToken]), regex(String) }
    public var identifier: String
    public var kind: Kind
    public var nocase = false
    public var wide = false
    public var ascii = false
    public var fullword = false
}

public enum HexToken {
    case oneOf([UInt8?])          // a byte, ??, a nibble wildcard, or a (AA|BB|??) single-byte alternation
    case jump(Int, Int?)          // [n], [n-m]; nil max = unbounded (capped at match time)
}

public struct Rule {
    public let name: String
    public let tags: [String]
    public let meta: [String: String]
    public let strings: [RuleStringDef]
    public let condition: RuleCondition
}

public struct RuleStringMatch: Codable, Sendable {
    public let identifier: String
    public let offsets: [Int]
}

public struct RuleMatch: Codable, Sendable {
    public let rule: String
    public let tags: [String]
    public let meta: [String: String]
    public let strings: [RuleStringMatch]
}

public enum RuleScanner {
    static let maxRules = 256
    static let maxStringsPerRule = 64
    static let maxHitsPerString = 1024
    static let maxUnboundedJump = 65536
    static let maxMatchSteps = 4_000_000

    // MARK: Compilation

    public static func compile(_ source: String) throws -> [Rule] {
        var rules: [Rule] = []
        var cursor = source.startIndex
        while let header = source.range(of: "rule ", options: [.caseInsensitive], range: cursor..<source.endIndex) {
            let nameStart = header.upperBound
            guard let openBrace = source.range(of: "{", range: nameStart..<source.endIndex) else { break }
            let nameAndTags = source[nameStart..<openBrace.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let closeBrace = try matchingBrace(source, from: openBrace.upperBound)
            let body = String(source[openBrace.upperBound..<closeBrace])
            rules.append(try parseRule(nameAndTags: nameAndTags, body: body))
            guard rules.count <= maxRules else { throw RuleSyntaxError.message("Rule pack exceeds \(maxRules) rules.") }
            cursor = source.index(after: closeBrace)
        }
        guard !rules.isEmpty else { throw RuleSyntaxError.message("No rules found. Expected: rule name { … } blocks.") }
        return rules
    }

    static func matchingBrace(_ source: String, from: String.Index) throws -> String.Index {
        var depth = 1; var index = from; var inQuote = false
        while index < source.endIndex {
            let character = source[index]
            if character == "\"" { inQuote.toggle() }
            else if !inQuote {
                if character == "{" { depth += 1 }
                if character == "}" { depth -= 1; if depth == 0 { return index } }
            }
            index = source.index(after: index)
        }
        throw RuleSyntaxError.message("Unbalanced braces in rule body.")
    }

    static func parseRule(nameAndTags: String, body: String) throws -> Rule {
        let parts = nameAndTags.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.first, !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw RuleSyntaxError.message("Invalid rule name: \(nameAndTags.prefix(40))")
        }
        let tags = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
        let (metaText, stringsText, conditionText) = try splitSections(body)
        var meta: [String: String] = [:]
        let metaPattern = try NSRegularExpression(pattern: "(\\w+)\\s*=\\s*(\"[^\"]*\"|[-\\w]+)")
        for match in metaPattern.matches(in: metaText, range: NSRange(metaText.startIndex..., in: metaText)) {
            guard let keyRange = Range(match.range(at: 1), in: metaText), let valueRange = Range(match.range(at: 2), in: metaText) else { continue }
            var value = String(metaText[valueRange])
            if value.hasPrefix("\"") { value = String(value.dropFirst().dropLast()) }
            meta[String(metaText[keyRange])] = value
        }
        let strings = try parseStrings(stringsText)
        let condition = try parseCondition(conditionText)
        return Rule(name: name, tags: tags, meta: meta, strings: strings, condition: condition)
    }

    static func splitSections(_ body: String) throws -> (String, String, String) {
        var sections: [String: Range<String.Index>] = [:]
        for keyword in ["meta:", "strings:", "condition:"] {
            if let range = body.range(of: keyword) { sections[String(keyword.dropLast())] = range }
        }
        guard sections["condition"] != nil else { throw RuleSyntaxError.message("Rule is missing a condition section.") }
        let keys = sections.keys.sorted { sections[$0]!.lowerBound < sections[$1]!.lowerBound }
        var slices: [String: String] = [:]
        for (position, key) in keys.enumerated() {
            let start = body.index(after: sections[key]!.upperBound)
            let end = position + 1 < keys.count ? sections[keys[position + 1]]!.lowerBound : body.endIndex
            slices[key] = String(body[start..<end])
        }
        return (slices["meta"] ?? "", slices["strings"] ?? "", slices["condition"] ?? "")
    }

    // MARK: Strings section

    static func parseStrings(_ text: String) throws -> [RuleStringDef] {
        // Definitions start at every `$name =` regardless of line breaks; hex patterns may span lines.
        let boundary = try NSRegularExpression(pattern: "\\$[A-Za-z0-9_]+\\s*=")
        let boundaryMatches = boundary.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var definitions: [String] = []
        for (position, match) in boundaryMatches.enumerated() {
            guard let start = Range(match.range, in: text) else { continue }
            let end = position + 1 < boundaryMatches.count ? Range(boundaryMatches[position + 1].range, in: text)!.lowerBound : text.endIndex
            definitions.append(String(text[start.lowerBound..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var defs: [RuleStringDef] = []
        for full in definitions {
            guard defs.count < maxStringsPerRule else { throw RuleSyntaxError.message("More than \(maxStringsPerRule) strings in one rule.") }
            guard let equals = full.range(of: "=") else { throw RuleSyntaxError.message("String definition missing '=': \(full.prefix(40))") }
            let identifier = String(full[..<equals.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard identifier.hasPrefix("$"), identifier.count > 1 else { throw RuleSyntaxError.message("Invalid string identifier: \(identifier)") }
            let rest = String(full[equals.upperBound...]).trimmingCharacters(in: .whitespaces)
            var def = RuleStringDef(identifier: identifier, kind: .literal(""))
            if rest.hasPrefix("{") {
                guard let close = rest.firstIndex(of: "}") else { throw RuleSyntaxError.message("Unterminated hex pattern on \(identifier).") }
                def.kind = try .hex(parseHex(String(rest[rest.index(after: rest.startIndex)..<close])))
            } else if rest.hasPrefix("/") {
                guard let closing = rest.range(of: "/", options: [], range: rest.index(after: rest.startIndex)..<rest.endIndex) else {
                    throw RuleSyntaxError.message("Unterminated regular expression: \(rest.prefix(40))")
                }
                let pattern = String(rest[rest.index(after: rest.startIndex)..<closing.lowerBound])
                def.nocase = rest[closing.upperBound...].contains("i")
                def.kind = .regex(pattern)
            } else {
                let pieces = rest.split(separator: " ")
                guard let quoted = pieces.first, quoted.hasPrefix("\""), quoted.hasSuffix("\""), quoted.count >= 2 else {
                    throw RuleSyntaxError.message("String must be quoted, a hex { } pattern, or /regex/: \(rest.prefix(40))")
                }
                let literal = String(quoted.dropFirst().dropLast())
                for modifier in pieces.dropFirst() {
                    switch modifier.lowercased() {
                    case "nocase": def.nocase = true
                    case "wide": def.wide = true
                    case "ascii": def.ascii = true
                    case "fullword": def.fullword = true
                    default: throw RuleSyntaxError.message("Unknown modifier \"\(modifier)\" on \(identifier) (subset: nocase wide ascii fullword)")
                    }
                }
                def.kind = .literal(literal)
            }
            defs.append(def)
        }
        return defs
    }

    static func parseHex(_ text: String) throws -> [HexToken] {
        var tokens: [HexToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace { index = text.index(after: index); continue }
            if character == "[" {
                guard let end = text.firstIndex(of: "]") else { throw RuleSyntaxError.message("Unterminated jump.") }
                let spec = String(text[text.index(after: index)..<end]).trimmingCharacters(in: .whitespaces)
                if spec == "+" { tokens.append(.jump(0, nil)) }
                else if spec.contains("-") {
                    let bounds = spec.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    guard bounds.count == 2, bounds[0] <= bounds[1] else { throw RuleSyntaxError.message("Bad jump [\(spec)].") }
                    tokens.append(.jump(bounds[0], bounds[1]))
                } else {
                    guard let count = Int(spec), count >= 0 else { throw RuleSyntaxError.message("Bad jump [\(spec)].") }
                    tokens.append(.jump(count, count))
                }
                index = text.index(after: end)
                continue
            }
            if character == "(" {
                guard let end = text.firstIndex(of: ")") else { throw RuleSyntaxError.message("Unterminated alternation.") }
                let alternatives = String(text[text.index(after: index)..<end]).split(separator: "|")
                var options: [UInt8?] = []
                for alternative in alternatives {
                    let value = alternative.trimmingCharacters(in: .whitespaces)
                    guard value.count == 2 else { throw RuleSyntaxError.message("Alternation supports single bytes only: (\(value))") }
                    options.append(hexByte(value))
                }
                tokens.append(.oneOf(options))
                index = text.index(after: end)
                continue
            }
            let word = String(text[index...].prefix { !$0.isWhitespace && $0 != "}" })
            guard word.count == 2 else { throw RuleSyntaxError.message("Bad hex token \"\(word)\".") }
            tokens.append(.oneOf([hexByte(word)]))
            index = text.index(index, offsetBy: word.count)
        }
        guard case .oneOf? = tokens.first else { throw RuleSyntaxError.message("Hex pattern must start with a byte (leading jumps are outside the supported subset).") }
        return tokens
    }

    static func hexByte(_ text: String) -> UInt8? {
        var byte: UInt8 = 0
        for character in text.utf8 {
            if character == UInt8(ascii: "?") { byte = byte << 4; continue }
            guard let value = Hex.nibble(character) else { return nil }
            byte = byte << 4 | value
        }
        return text.contains("?") ? nil : byte
    }

    // MARK: Condition section

    static func parseCondition(_ text: String) throws -> RuleCondition {
        let parser = ConditionParser(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        let condition = try parser.parseOr()
        guard parser.isAtEnd() else { throw RuleSyntaxError.message("Unexpected condition text after: \(parser.remaining().prefix(30))") }
        return condition
    }

    final class ConditionParser {
        let tokens: [String]
        var position = 0
        init(text: String) {
            var collected: [String] = []; var current = ""
            for character in text {
                if character.isWhitespace { if !current.isEmpty { collected.append(current); current = "" } }
                else if "(),".contains(character) { if !current.isEmpty { collected.append(current); current = "" }; collected.append(String(character)) }
                else { current.append(character) }
            }
            if !current.isEmpty { collected.append(current) }
            tokens = collected
        }
        func peek() -> String? { position < tokens.count ? tokens[position] : nil }
        func advance() -> String { defer { position += 1 }; return tokens[position] }
        func isAtEnd() -> Bool { position >= tokens.count }
        func remaining() -> String { tokens[position...].joined(separator: " ") }
        func expect(_ token: String) throws { guard peek() == token else { throw RuleSyntaxError.message("Expected \"\(token)\", found \"\(peek() ?? "end")\".") }; position += 1 }

        func parseOr() throws -> RuleCondition {
            var terms = [try parseAnd()]
            while peek()?.lowercased() == "or" { position += 1; terms.append(try parseAnd()) }
            return terms.count == 1 ? terms[0] : .any(terms)
        }
        func parseAnd() throws -> RuleCondition {
            var terms = [try parseNot()]
            while peek()?.lowercased() == "and" { position += 1; terms.append(try parseNot()) }
            return terms.count == 1 ? terms[0] : .all(terms)
        }
        func parseNot() throws -> RuleCondition {
            if peek()?.lowercased() == "not" { position += 1; return .not(try parseNot()) }
            return try parsePrimary()
        }
        func parsePrimary() throws -> RuleCondition {
            guard let token = peek() else { throw RuleSyntaxError.message("Condition ended unexpectedly.") }
            if token == "(" { position += 1; let inner = try parseOr(); try expect(")"); return inner }
            switch token.lowercased() {
            case "true": position += 1; return .boolLit(true)
            case "false": position += 1; return .boolLit(false)
            case "filesize": position += 1; return try comparison(after: .filesize)
            case "any", "all":
                position += 1
                try expect("of")
                return try ofClause(required: token.lowercased() == "all" ? Int.max : 1, word: token)
            case "uint8", "uint16", "uint32":
                position += 1
                try expect("(")
                let offset = try parseConstant()
                try expect(")")
                let size = token.hasSuffix("8") ? 1 : (token.hasSuffix("16") ? 2 : 4)
                guard let opToken = peek(), let comparison = RuleComparison(rawValue: opToken) else { throw RuleSyntaxError.message("Expected comparison after \(token)(…).") }
                position += 1
                return .uintComparison(size, offset, comparison, try parseConstant())
            default: break
            }
            if let count = Int(token), position + 1 < tokens.count, tokens[position + 1].lowercased() == "of" {
                position += 2
                return try ofClause(required: count, word: token)
            }
            if token.hasPrefix("$") {
                position += 1
                if peek()?.lowercased() == "at" { position += 1; return .at(token, try parseConstant()) }
                if peek()?.lowercased() == "in" {
                    position += 1; try expect("(")
                    let low = try parseConstant(); try expect(".."); let high = try parseConstant(); try expect(")")
                    guard low <= high else { throw RuleSyntaxError.message("Range \(low)..\(high) is inverted.") }
                    return .inRange(token, low...high)
                }
                return .stringPresent(token)
            }
            if let constant = parseNumber(token) { position += 1; return try comparison(after: .constant(constant)) }
            throw RuleSyntaxError.message("Unsupported condition token \"\(token)\" (subset: and/or/not, $s [at/in], N of them|($a,$b), any, all, filesize, uint8/16/32(n), ==/!=/</<=/>/>=)")
        }
        func ofClause(required: Int, word: String) throws -> RuleCondition {
            if peek()?.lowercased() == "them" { position += 1; return .of(count: required, identifiers: nil, them: true) }
            try expect("(")
            var identifiers: [String] = []
            while let token = peek(), token != ")" {
                guard token.hasPrefix("$") else { throw RuleSyntaxError.message("of (…) takes string identifiers, found \(token).") }
                identifiers.append(token); position += 1
                if peek() == "," { position += 1 }
            }
            try expect(")")
            guard !identifiers.isEmpty else { throw RuleSyntaxError.message("Empty of (…) list after \(word).") }
            return .of(count: required, identifiers: identifiers, them: false)
        }
        func comparison(after left: RuleValue) throws -> RuleCondition {
            guard let opToken = peek(), let comparison = RuleComparison(rawValue: opToken) else { throw RuleSyntaxError.message("Expected a comparison operator.") }
            position += 1
            if peek()?.lowercased() == "filesize" { position += 1; return .comparison(left, comparison, .filesize) }
            return .comparison(left, comparison, .constant(try parseConstant()))
        }
        func parseConstant() throws -> Int {
            guard let token = peek(), let value = parseNumber(token) else { throw RuleSyntaxError.message("Expected a number, found \"\(peek() ?? "end")\".") }
            position += 1
            return value
        }
        func parseNumber(_ token: String) -> Int? {
            if let value = Int(token) { return value }
            if token.lowercased().hasPrefix("0x"), let value = Int(token.dropFirst(2), radix: 16) { return value }
            return nil
        }
    }

    // MARK: Matching

    public static func scan(_ data: Data, rules: [Rule]) -> [RuleMatch] {
        var results: [RuleMatch] = []
        for rule in rules {
            var matchSets: [String: [Int]] = [:]
            for definition in rule.strings { matchSets[definition.identifier] = occurrences(of: definition, in: data) }
            if evaluate(rule.condition, matches: matchSets, data: data) {
                results.append(RuleMatch(rule: rule.name, tags: rule.tags, meta: rule.meta,
                                         strings: matchSets.map { RuleStringMatch(identifier: $0.key, offsets: $0.value) }.sorted { $0.identifier < $1.identifier }))
            }
        }
        return results
    }

    static func occurrences(of definition: RuleStringDef, in data: Data) -> [Int] {
        switch definition.kind {
        case .literal(let literal):
            let utf8 = Array(literal.utf8)
            var variants: [[UInt8]] = []
            if definition.ascii || (!definition.wide && !definition.ascii) { variants.append(utf8) }
            if definition.wide { variants.append(utf8.flatMap { [$0, 0] }) }
            if definition.nocase { variants = variants.map { $0.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 } } }
            let folded = definition.nocase ? Data(data.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }) : data
            var hits: [Int] = []
            for variant in variants {
                guard variant.count <= folded.count else { continue }
                var searchStart = folded.startIndex
                while hits.count < maxHitsPerString,
                      let range = folded.range(of: Data(variant), options: [], in: searchStart..<folded.endIndex) {
                    let offset = folded.distance(from: folded.startIndex, to: range.lowerBound)
                    if !definition.fullword || isWordBoundary(folded, at: range) { hits.append(offset) }
                    searchStart = range.upperBound
                }
            }
            return Array(Set(hits)).sorted()
        case .hex(let tokens):
            return hexOccurrences(tokens: tokens, data: data)
        case .regex(let pattern):
            guard let regular = try? NSRegularExpression(pattern: pattern, options: definition.nocase ? [.caseInsensitive] : []) else { return [] }
            // Latin-1 gives a 1:1 byte↔scalar mapping, so character distances are byte offsets.
            let text = String(String.UnicodeScalarView(data.map { UnicodeScalar($0) }))
            let matches = regular.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)).prefix(maxHitsPerString)
            return matches.compactMap { match in
                Range(match.range, in: text).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
            }
        }
    }

    static func isWordBoundary(_ data: Data, at range: Range<Data.Index>) -> Bool {
        func alphanumeric(_ byte: UInt8?) -> Bool {
            guard let byte else { return false }
            return (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        }
        let before = range.lowerBound > data.startIndex ? data[data.index(before: range.lowerBound)] : nil
        let after = range.upperBound < data.endIndex ? data[range.upperBound] : nil
        return !alphanumeric(before) && !alphanumeric(after)
    }

    static func hexOccurrences(tokens: [HexToken], data: Data) -> [Int] {
        guard case .oneOf(let firstOptions) = tokens.first else { return [] }
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return [] }
        var hits: [Int] = []
        var steps = 0
        for start in 0...(bytes.count - 1) {
            if hits.count >= maxHitsPerString || steps > maxMatchSteps { break }
            guard firstOptions.contains(where: { $0 == nil || $0 == bytes[start] }) else { continue }
            if matchTail(tokens: Array(tokens.dropFirst()), bytes: bytes, position: start + 1, steps: &steps) != nil {
                hits.append(start)
            }
        }
        return hits
    }

    static func matchTail(tokens: [HexToken], bytes: [UInt8], position: Int, steps: inout Int) -> Int? {
        steps += 1
        if steps > maxMatchSteps { return nil }
        guard let token = tokens.first else { return position }
        let rest = Array(tokens.dropFirst())
        switch token {
        case .oneOf(let options):
            guard position < bytes.count, options.contains(where: { $0 == nil || $0 == bytes[position] }) else { return nil }
            return matchTail(tokens: rest, bytes: bytes, position: position + 1, steps: &steps)
        case .jump(let minimum, let maximum):
            let ceiling = min(maximum ?? maxUnboundedJump, maxUnboundedJump, bytes.count - position)
            guard minimum <= ceiling else { return nil }
            var taken = max(minimum, 0)
            // A zero-length option is tried first so [0-2] and [+] behave like YARA's.
            if minimum == 0, let result = matchTail(tokens: rest, bytes: bytes, position: position, steps: &steps) { return result }
            while taken <= ceiling {
                if let result = matchTail(tokens: rest, bytes: bytes, position: position + taken, steps: &steps) { return result }
                taken += 1
            }
            return nil
        }
    }

    // MARK: Condition evaluation

    static func evaluate(_ condition: RuleCondition, matches: [String: [Int]], data: Data) -> Bool {
        switch condition {
        case .boolLit(let value): return value
        case .stringPresent(let id): return !(matches[id] ?? []).isEmpty
        case .at(let id, let offset): return (matches[id] ?? []).contains(offset)
        case .inRange(let id, let range): return (matches[id] ?? []).contains { range.contains($0) }
        case .of(let count, let identifiers, let them):
            let pools = them ? Array(matches.keys) : identifiers ?? []
            let satisfied = pools.filter { !(matches[$0] ?? []).isEmpty }.count
            return count == Int.max ? satisfied == pools.count : satisfied >= count
        case .comparison(let left, let comparison, let right):
            return comparison.evaluate(resolved(left, data: data), resolved(right, data: data))
        case .uintComparison(let size, let offset, let comparison, let constant):
            guard offset >= 0, offset + size <= data.count else { return false }
            let slice = data.subdata(in: data.startIndex + offset..<data.startIndex + offset + size)
            var value = 0
            for byte in slice.reversed() { value = value << 8 | Int(byte) }   // little-endian, per YARA semantics
            return comparison.evaluate(value, constant)
        case .not(let inner): return !evaluate(inner, matches: matches, data: data)
        case .all(let terms): return terms.allSatisfy { evaluate($0, matches: matches, data: data) }
        case .any(let terms): return terms.contains { evaluate($0, matches: matches, data: data) }
        }
    }

    static func resolved(_ value: RuleValue, data: Data) -> Int {
        switch value {
        case .constant(let constant): return constant
        case .filesize: return data.count
        }
    }
}
