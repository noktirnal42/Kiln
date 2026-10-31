import Foundation

/// A JSON value with one canonical text form. The audit chain hashes that text, so it must be
/// byte-stable across runs, machines and Foundation versions: keys sorted, no whitespace, strings
/// escaped by our own rules rather than a library's, and numbers rendered one way only.
public enum AuditValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AuditValue])
    case object([String: AuditValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([AuditValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: AuditValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Compact, key-sorted JSON. This exact text is what gets hashed.
    ///
    /// Numbers: integral doubles render as integers so `1` and `1.0` hash alike, because a value
    /// that round-trips through JSON may come back as either. Non-finite doubles render as `null`
    /// (JSON has no representation for them).
    public var canonical: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return Self.canonicalDouble(value)
        case .string(let value): return Self.quote(value)
        case .array(let values): return "[" + values.map(\.canonical).joined(separator: ",") + "]"
        case .object(let pairs):
            let body = pairs.keys.sorted().map { Self.quote($0) + ":" + pairs[$0]!.canonical }
            return "{" + body.joined(separator: ",") + "}"
        }
    }

    private static func canonicalDouble(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 9.0e15 { return String(Int64(value)) }
        return "\(value)"
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let s where s.value < 0x20: out += String(format: "\\u%04x", s.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension AuditValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: AuditValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, AuditValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
