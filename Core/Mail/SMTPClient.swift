import Foundation

/// Submits one composed message over SMTP with AUTH PLAIN. Recipients come from the envelope, not from the headers (so Bcc works).
public actor SMTPClient {
    private let connection: MailConnection
    private let heloName: String

    public init(host: String, port: Int, security: MailSecurity, timeout: TimeInterval = 30, heloName: String = "kiln.local") throws {
        connection = try MailConnection(host: host, port: port, security: security, timeout: timeout)
        self.heloName = heloName
    }

    public func send(_ message: Data, from sender: String, to recipients: [String], user: String, password: String) async throws {
        guard !recipients.isEmpty else { throw MailTransportError.serverRejected("No recipients.") }
        for address in [sender] + recipients where address.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "<" || $0 == ">" }) {
            throw MailTransportError.serverRejected("Invalid address.")
        }
        try await connection.connect()
        let greeting = try await reply()
        try expect(greeting, codes: 220)
        try await send("EHLO \(heloName)", expect: 250)
        let token = Data(([0] + Array(user.utf8) + [0] + Array(password.utf8))).base64EncodedString()
        let auth = try await sendRaw("AUTH PLAIN \(token)")
        guard auth.code == 235 else { throw MailTransportError.authenticationFailed(auth.text) }
        try await send("MAIL FROM:<\(sender)>", expect: 250)
        for r in recipients { try await send("RCPT TO:<\(r)>", expect: 250, 251) }
        try await send("DATA", expect: 354)
        try await connection.send(Self.dotStuffed(message))
        let done = try await reply()
        guard done.code == 250 else { throw MailTransportError.serverRejected(done.text) }
        _ = try? await sendRaw("QUIT")
        await connection.close()
    }

    /// Lines starting with "." get a second ".", and the data ends with CRLF.CRLF.
    static func dotStuffed(_ message: Data) -> Data {
        var text = String(decoding: message, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasSuffix("\n") { text.removeLast() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasPrefix(".") ? "." + $0 : String($0) }
        return Data((lines.joined(separator: "\r\n") + "\r\n.\r\n").utf8)
    }

    // MARK: Protocol

    struct Reply { var code: Int; var text: String }

    private func reply() async throws -> Reply {
        var text: [String] = []
        while true {
            let line = try await connection.readLine()
            guard line.count >= 3, let code = Int(line.prefix(3)) else { throw MailTransportError.protocolError(line) }
            text.append(String(line.dropFirst(4)))
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " { return Reply(code: code, text: text.joined(separator: " ")) }
        }
    }

    private func expect(_ reply: Reply, codes: Int...) throws {
        guard codes.contains(reply.code) else { throw MailTransportError.serverRejected("\(reply.code) \(reply.text)") }
    }

    private func sendRaw(_ command: String) async throws -> Reply {
        try await connection.send(command + "\r\n")
        return try await reply()
    }

    private func send(_ command: String, expect codes: Int...) async throws {
        let r = try await sendRaw(command)
        guard codes.contains(r.code) else { throw MailTransportError.serverRejected("\(r.code) \(r.text)") }
    }
}
