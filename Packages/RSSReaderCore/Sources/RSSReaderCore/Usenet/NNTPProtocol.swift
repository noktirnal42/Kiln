import Foundation

public enum NNTPError: Error, LocalizedError, Sendable {
    case invalidCommand(String)
    case invalidResponse(String)
    case unexpectedStatus(Int, String)
    case notConnected
    case connectionFailed(String)
    case connectionClosed
    case authenticationRequired
    case protocolViolation(String)
    case accessDenied(String)
    case serverRefused(String)
    case groupNotFound(String)
    case noArticles(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCommand(let command):
            "Invalid NNTP command: \(command)"
        case .invalidResponse(let line):
            "Unexpected NNTP response: \(line)"
        case .unexpectedStatus(let code, let message):
            "NNTP server returned \(code): \(message)"
        case .notConnected:
            "Not connected to a Usenet server."
        case .connectionFailed(let reason):
            "Connection failed: \(reason)"
        case .connectionClosed:
            "The server closed the connection."
        case .authenticationRequired:
            "This server requires a username and password."
        case .protocolViolation(let detail):
            "NNTP protocol violation: \(detail)"
        case .accessDenied:
            "This server refused read access. Add your username and password, or pick a server that allows guest reading."
        case .serverRefused(let message):
            "The server refused the request: \(message)"
        case .groupNotFound(let group):
            "The server does not carry \(group)."
        case .noArticles(let detail):
            detail.isEmpty ? "No articles are available right now." : detail
        case .timedOut(let activity):
            "Timed out while \(activity). Check the host, port and TLS setting, then try again."
        }
    }
}

// MARK: - Status line

public struct NNTPStatus: Equatable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3,
              let code = Int(trimmed.prefix(3)),
              (100...599).contains(code) else { return nil }
        self.code = code
        self.message = String(trimmed.dropFirst(3))
            .trimmingCharacters(in: .whitespaces)
    }

    public var isPositive: Bool { (200..<400).contains(code) }
    public var isInformational: Bool { (100..<200).contains(code) }
    public var isMultiline: Bool {
        [100, 101, 215, 220, 221, 222, 224, 225, 230, 231].contains(code)
    }

    /// Maps the status codes newsreaders actually hit onto actionable errors.
    public var error: NNTPError {
        switch code {
        case 400:
            .connectionClosed
        case 480, 481, 482:
            .accessDenied(message)
        case 502:
            .serverRefused(message)
        case 411:
            .groupNotFound(message.replacingOccurrences(of: "No such group ", with: ""))
        case 412, 420, 421, 423:
            .noArticles(message)
        default:
            .unexpectedStatus(code, message)
        }
    }
}

// MARK: - Wire helpers (pure, unit-testable)

public enum NNTPWire {
    /// Rejects CR/LF so a caller cannot inject commands.
    public static func validateCommand(_ command: String) throws {
        guard !command.isEmpty, command.count <= 16_384 else {
            throw NNTPError.invalidCommand(command)
        }
        guard !containsControlCharacters(command) else {
            throw NNTPError.invalidCommand(command)
        }
    }

    public static func validateArgument(_ argument: String) throws -> String {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NNTPError.invalidCommand(argument) }
        guard !containsControlCharacters(trimmed) else {
            throw NNTPError.invalidCommand(argument)
        }
        return trimmed
    }

    /// Checks Unicode scalars rather than Characters: Swift treats CRLF as a
    /// single grapheme cluster, which would defeat a `contains("\r")` check.
    public static func containsControlCharacters(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            scalar == "\r" || scalar == "\n" || scalar == "\0"
        }
    }

    /// Removes the extra leading dot used to escape lines beginning with a dot.
    public static func decodeDotStuffed(_ lines: [String]) -> [String] {
        lines.map { line in
            line.hasPrefix("..") ? String(line.dropFirst()) : line
        }
    }

    public static func decodeDotStuffed(_ body: String) -> String {
        body
            .split(whereSeparator: \.isNewline)
            .map { $0.hasPrefix("..") ? String($0.dropFirst()) : String($0) }
            .joined(separator: "\n")
    }

    public static func parseGroupListLine(_ line: String) -> NNTPGroupInfo? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 4,
              let count = Int(fields[1]),
              let low = Int(fields[2]),
              let high = Int(fields[3]) else { return nil }
        return NNTPGroupInfo(
            name: String(fields[0]),
            articleCount: count,
            lowWater: low,
            highWater: high,
            status: fields.count > 4 ? String(fields[4]) : "y"
        )
    }

    /// OVER/XOVER response line: number, subject, from, date, message-id, references, bytes, lines.
    public static func parseOverviewLine(_ line: String) -> NNTPOverviewEntry? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6,
              let number = Int(fields[0]) else { return nil }

        let date = FeedDateParser.parse(fields[3]) ?? .distantPast
        let references = fields[5]
            .split(whereSeparator: { $0 == " " })
            .map(String.init)

        return NNTPOverviewEntry(
            number: number,
            subject: fields[1],
            author: fields[2],
            date: date,
            messageID: fields[4],
            references: references,
            byteCount: fields.count > 6 ? Int(fields[6]) ?? 0 : 0,
            lineCount: fields.count > 7 ? Int(fields[7]) ?? 0 : 0
        )
    }

    /// Splits HEAD/ARTICLE payload into headers and body.
    public static func parseArticle(_ lines: [String]) -> (headers: [String: String], body: String) {
        var headers: [String: String] = [:]
        var index = 0
        var currentKey: String?

        while index < lines.count {
            let line = lines[index]
            if line.isEmpty {
                index += 1
                break
            }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if let key = currentKey {
                    headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                }
            } else if let colon = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colon])
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                headers[key] = value
                currentKey = key
            }
            index += 1
        }

        let body = lines.dropFirst(index).joined(separator: "\n")
        return (headers, body)
    }

    public static func references(from header: String) -> [String] {
        header
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
            .filter { !$0.isEmpty }
    }

    public static func displayAuthor(from raw: String) -> String {
        // "Name <address>" → "Name"
        if let angle = raw.firstIndex(of: "<") {
            let name = raw[raw.startIndex..<angle]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !name.isEmpty { return name }
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }
}
