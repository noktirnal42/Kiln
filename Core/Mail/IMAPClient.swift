import Foundation

/// A small IMAP4rev1 client: sign in, list folders, open one, list UIDs, fetch whole messages and flags. Read-only by design in this slice.
public actor IMAPClient {
    private let connection: MailConnection
    private var counter = 0

    public struct Mailbox: Equatable, Sendable { public var name: String; public var attributes: [String] }
    public struct Selection: Equatable, Sendable { public var exists: Int; public var uidValidity: UInt32? }
    public struct Fetched: Equatable, Sendable { public var uid: UInt32; public var flags: [String]; public var raw: Data }

    public init(host: String, port: Int, security: MailSecurity, timeout: TimeInterval = 20) throws {
        connection = try MailConnection(host: host, port: port, security: security, timeout: timeout)
    }

    public func connect() async throws {
        try await connection.connect()
        let greeting = try await connection.readLine()
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else { throw MailTransportError.protocolError(greeting) }
    }

    public func login(user: String, password: String) async throws {
        let result = try await command("LOGIN \(Self.quote(user)) \(Self.quote(password))")
        guard result.ok else { throw MailTransportError.authenticationFailed(result.status) }
    }

    public func listMailboxes() async throws -> [Mailbox] {
        let result = try await command(#"LIST "" "*""#)
        guard result.ok else { throw MailTransportError.serverRejected(result.status) }
        return result.untagged.compactMap { Self.parseList($0.line) }
    }

    public func select(_ mailbox: String) async throws -> Selection {
        let result = try await command("EXAMINE \(Self.quote(mailbox))")   // EXAMINE: read-only, never changes flags
        guard result.ok else { throw MailTransportError.serverRejected(result.status) }
        var selection = Selection(exists: 0, uidValidity: nil)
        for item in result.untagged {
            let parts = item.line.split(separator: " ")
            if parts.count >= 3, parts[2] == "EXISTS", let n = Int(parts[1]) { selection.exists = n }
            if let r = item.line.range(of: "[UIDVALIDITY ") { selection.uidValidity = UInt32(item.line[r.upperBound...].prefix { $0.isNumber }) }
        }
        return selection
    }

    /// UIDs of all messages in the open mailbox, or of those matching `criteria` (e.g. `SINCE 1-Nov-2026`, `FROM "ada"`).
    public func searchUIDs(_ criteria: String = "ALL") async throws -> [UInt32] {
        let result = try await command("UID SEARCH \(criteria)")
        guard result.ok else { throw MailTransportError.serverRejected(result.status) }
        return result.untagged.flatMap { item -> [UInt32] in
            guard item.line.hasPrefix("* SEARCH") else { return [] }
            return item.line.dropFirst("* SEARCH".count).split(separator: " ").compactMap { UInt32($0) }
        }
    }

    /// Whole messages. BODY.PEEK leaves the unread flag alone.
    public func fetch(uids: [UInt32]) async throws -> [Fetched] {
        guard !uids.isEmpty else { return [] }
        let set = uids.map(String.init).joined(separator: ",")
        let result = try await command("UID FETCH \(set) (UID FLAGS BODY.PEEK[])")
        guard result.ok else { throw MailTransportError.serverRejected(result.status) }
        return result.untagged.compactMap { item in
            guard item.line.contains("FETCH"), let literal = item.literal,
                  let uidRange = item.line.range(of: "UID ") else { return nil }
            let uid = UInt32(item.line[uidRange.upperBound...].prefix { $0.isNumber })
            var flags: [String] = []
            if let open = item.line.range(of: "FLAGS ("), let close = item.line[open.upperBound...].firstIndex(of: ")") {
                flags = item.line[open.upperBound..<close].split(separator: " ").map(String.init)
            }
            return uid.map { Fetched(uid: $0, flags: flags, raw: literal) }
        }
    }

    public func logout() async {
        _ = try? await command("LOGOUT")
        await connection.close()
    }

    // MARK: Protocol

    struct Untagged { var line: String; var literal: Data? }
    struct Result { var ok: Bool; var status: String; var untagged: [Untagged] }

    /// Sends one tagged command and collects every untagged line (with its literal, if any) up to the tagged answer.
    func command(_ text: String) async throws -> Result {
        counter += 1
        let tag = "K\(counter)"
        try await connection.send("\(tag) \(text)\r\n")
        var untagged: [Untagged] = []
        while true {
            var line = try await connection.readLine()
            if line.hasPrefix("\(tag) ") {
                let status = String(line.dropFirst(tag.count + 1))
                return Result(ok: status.hasPrefix("OK"), status: status, untagged: untagged)
            }
            guard line.hasPrefix("*") else { continue }
            var literal: Data?
            // "* 1 FETCH (UID 4 BODY[] {123}" is followed by 123 bytes, then the rest of the line.
            while line.hasSuffix("}"), let open = line.lastIndex(of: "{"), let size = Int(line[line.index(after: open)..<line.index(before: line.endIndex)]) {
                guard size <= 64 * 1024 * 1024 else { throw MailTransportError.protocolError("message too large") }
                let bytes = try await connection.read(count: size)
                literal = (literal ?? Data()) + bytes
                line = String(line[..<open]) + "<literal>" + (try await connection.readLine())
            }
            untagged.append(Untagged(line: line, literal: literal))
        }
    }

    /// IMAP quoted string; CR and LF cannot be quoted, so they are refused (they would end the command early).
    static func quote(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: value.unicodeScalars.filter { $0 != "\r" && $0 != "\n" })   // Scalars: CRLF is one Character in Swift
        return "\"" + String(scalars).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func parseList(_ line: String) -> Mailbox? {
        guard line.hasPrefix("* LIST "), let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")") else { return nil }
        let attributes = line[line.index(after: open)..<close].split(separator: " ").map(String.init)
        var rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        // hierarchy delimiter: "/" or NIL
        if let space = rest.firstIndex(of: " ") { rest = rest[rest.index(after: space)...].trimmingCharacters(in: .whitespaces) } else { return nil }
        if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 { rest = String(rest.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"") }
        return rest.isEmpty ? nil : Mailbox(name: rest, attributes: attributes)
    }
}
