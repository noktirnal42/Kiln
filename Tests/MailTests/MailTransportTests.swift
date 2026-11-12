import Foundation
import Network
import Testing
@testable import Kiln

/// A loopback server that answers each received line with scripted bytes. Records everything it was sent.
final class ScriptedMailServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "scripted-mail-server")
    private let lock = NSLock()
    private var _received: [String] = []
    private let greeting: String
    private let respond: @Sendable (String, ScriptedMailServer) -> [Data]
    private var buffer = Data()
    private var conn: NWConnection?
    var received: [String] { lock.lock(); defer { lock.unlock() }; return _received }
    /// Set by a handler to make following lines arrive as raw data until a lone "." line.
    var collectingData = false

    init(greeting: String, respond: @escaping @Sendable (String, ScriptedMailServer) -> [Data]) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.greeting = greeting
        self.respond = respond
    }

    func start() async throws -> Int {
        listener.newConnectionHandler = { [self] c in
            conn = c
            c.start(queue: queue)
            c.send(content: Data((greeting + "\r\n").utf8), completion: .contentProcessed { _ in })
            receive(c)
        }
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<Int, Error>) in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { [listener] state in
                guard !once.done else { return }
                if case .ready = state, let port = listener.port?.rawValue { once.done = true; k.resume(returning: Int(port)) }
                if case .failed(let e) = state { once.done = true; k.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            if let data { buffer.append(data) }
            while let range = buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                buffer = Data(buffer[range.upperBound...])
                lock.lock(); _received.append(line); lock.unlock()
                for out in respond(line, self) { c.send(content: out, completion: .contentProcessed { _ in }) }
            }
            if error == nil, !done { receive(c) }
        }
    }

    func stop() { listener.cancel(); conn?.cancel() }
}

private func crlf(_ s: String) -> Data { Data((s + "\r\n").utf8) }

@Suite("Mail transport", .serialized)
struct MailTransportTests {
    @Test func imapListsFoldersSelectsSearchesAndFetchesLiterals() async throws {
        let raw = "From: ada@example.com\r\nSubject: Hi\r\n\r\nBody\r\n"
        let server = try ScriptedMailServer(greeting: "* OK ready") { line, _ in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return [] }
            let tag = parts[0], cmd = parts[1]
            if cmd.hasPrefix("LOGIN") { return [crlf(cmd.contains("wrong") ? "\(tag) NO [AUTHENTICATIONFAILED] bad" : "\(tag) OK logged in")] }
            if cmd.hasPrefix("LIST") { return [crlf(#"* LIST (\HasNoChildren) "/" "INBOX""#), crlf(#"* LIST (\Sent) "/" "Sent Items""#), crlf("\(tag) OK done")] }
            if cmd.hasPrefix("EXAMINE") { return [crlf("* 2 EXISTS"), crlf("* OK [UIDVALIDITY 777] ok"), crlf("\(tag) OK [READ-ONLY] done")] }
            if cmd.hasPrefix("UID SEARCH") { return [crlf("* SEARCH 4 9"), crlf("\(tag) OK done")] }
            if cmd.hasPrefix("UID FETCH") {
                return [crlf("* 1 FETCH (UID 4 FLAGS (\\Seen) BODY[] {\(raw.utf8.count)}"), Data(raw.utf8), crlf(")"), crlf("\(tag) OK done")]
            }
            if cmd.hasPrefix("LOGOUT") { return [crlf("* BYE"), crlf("\(tag) OK bye")] }
            return [crlf("\(tag) BAD unknown")]
        }
        let port = try await server.start()
        defer { server.stop() }
        let client = try IMAPClient(host: "127.0.0.1", port: port, security: .none, timeout: 5)
        try await client.connect()
        try await client.login(user: "ada", password: "pw")
        let boxes = try await client.listMailboxes()
        #expect(boxes.map(\.name) == ["INBOX", "Sent Items"])
        let selection = try await client.select("INBOX")
        #expect(selection == .init(exists: 2, uidValidity: 777))
        #expect(try await client.searchUIDs() == [4, 9])
        let fetched = try await client.fetch(uids: [4])
        #expect(fetched.count == 1 && fetched[0].uid == 4 && fetched[0].flags == ["\\Seen"])
        let message = MIMEParser.parse(fetched[0].raw)
        #expect(message.subject == "Hi" && message.from.first?.email == "ada@example.com")
        await client.logout()
        #expect(server.received.contains { $0.contains("EXAMINE") })   // read-only: never SELECT
        #expect(!server.received.contains { $0.contains(" SELECT ") })
        #expect(server.received.contains { $0.contains("BODY.PEEK[]") })
    }

    @Test func imapRefusedLoginSurfacesAsAuthenticationFailure() async throws {
        let server = try ScriptedMailServer(greeting: "* OK ready") { line, _ in
            let tag = line.split(separator: " ").first.map(String.init) ?? "?"
            return [crlf("\(tag) NO [AUTHENTICATIONFAILED] Invalid credentials")]
        }
        let port = try await server.start()
        defer { server.stop() }
        let client = try IMAPClient(host: "127.0.0.1", port: port, security: .none, timeout: 5)
        try await client.connect()
        await #expect(throws: MailTransportError.self) { try await client.login(user: "ada", password: "wrong") }
    }

    @Test func smtpAuthenticatesUsesEnvelopeRecipientsAndDotStuffs() async throws {
        let server = try ScriptedMailServer(greeting: "220 hi") { line, s in
            if s.collectingData {
                if line == "." { s.collectingData = false; return [crlf("250 queued")] }
                return []
            }
            if line.hasPrefix("EHLO") { return [crlf("250-hello"), crlf("250 AUTH PLAIN")] }
            if line.hasPrefix("AUTH PLAIN") { return [crlf("235 ok")] }
            if line.hasPrefix("MAIL FROM") || line.hasPrefix("RCPT TO") { return [crlf("250 ok")] }
            if line == "DATA" { s.collectingData = true; return [crlf("354 go")] }
            if line == "QUIT" { return [crlf("221 bye")] }
            return [crlf("500 what")]
        }
        let port = try await server.start()
        defer { server.stop() }
        let client = try SMTPClient(host: "127.0.0.1", port: port, security: .none, timeout: 5)
        try await client.send(Data("Subject: x\r\n\r\n.hidden dot\r\nend\r\n".utf8), from: "me@example.com", to: ["a@example.com", "bcc@example.com"], user: "me", password: "pw")
        let lines = server.received
        #expect(lines.contains("MAIL FROM:<me@example.com>"))
        #expect(lines.contains("RCPT TO:<bcc@example.com>"))
        #expect(lines.contains("..hidden dot"))
        let token = Data([0] + Array("me".utf8) + [0] + Array("pw".utf8)).base64EncodedString()
        #expect(lines.contains("AUTH PLAIN \(token)"))
    }

    @Test func smtpRefusesBadAuthAndInjectedAddresses() async throws {
        let server = try ScriptedMailServer(greeting: "220 hi") { line, _ in
            if line.hasPrefix("EHLO") { return [crlf("250 hello")] }
            if line.hasPrefix("AUTH") { return [crlf("535 nope")] }
            return [crlf("500 what")]
        }
        let port = try await server.start()
        defer { server.stop() }
        let client = try SMTPClient(host: "127.0.0.1", port: port, security: .none, timeout: 5)
        await #expect(throws: MailTransportError.self) {
            try await client.send(Data("x".utf8), from: "me@example.com", to: ["a@example.com"], user: "me", password: "bad")
        }
        await #expect(throws: MailTransportError.self) {
            try await client.send(Data("x".utf8), from: "me@example.com", to: ["a@b.c>\r\nRCPT TO:<evil@x.com"], user: "me", password: "pw")
        }
    }

    @Test func serviceReadsRecentMessagesNewestFirstAndThreadsThem() async throws {
        func raw(_ id: String, _ subject: String, _ extra: String = "") -> String {
            "Message-ID: <\(id)>\r\nSubject: \(subject)\r\n\(extra)Date: Tue, 10 Nov 2026 09:30:00 -0700\r\n\r\nbody\r\n"
        }
        let one = raw("a", "Plan"), two = raw("b", "Re: Plan", "In-Reply-To: <a>\r\n")
        let server = try ScriptedMailServer(greeting: "* OK ready") { line, _ in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return [] }
            let tag = parts[0], cmd = parts[1]
            if cmd.hasPrefix("LOGIN") { return [crlf("\(tag) OK")] }
            if cmd.hasPrefix("EXAMINE") { return [crlf("* 2 EXISTS"), crlf("\(tag) OK")] }
            if cmd.hasPrefix("UID SEARCH") { return [crlf("* SEARCH 1 2"), crlf("\(tag) OK")] }
            if cmd.hasPrefix("UID FETCH") {
                return [crlf("* 1 FETCH (UID 1 FLAGS (\\Seen) BODY[] {\(one.utf8.count)}"), Data(one.utf8), crlf(")"),
                        crlf("* 2 FETCH (UID 2 FLAGS () BODY[] {\(two.utf8.count)}"), Data(two.utf8), crlf(")"), crlf("\(tag) OK")]
            }
            return [crlf("\(tag) OK")]
        }
        let port = try await server.start()
        defer { server.stop() }
        let account = MailAccount(displayName: "Me", address: "me@example.com", imapHost: "127.0.0.1", imapPort: port, imapSecurity: .none, smtpHost: "127.0.0.1", smtpSecurity: .none)
        let service = MailService(account: account, password: "pw")
        let recent = try await service.recent()
        #expect(recent.map(\.uid) == [2, 1])
        #expect(recent[0].isUnread && !recent[1].isUnread)
        let threads = try await service.threads()
        #expect(threads.count == 1 && threads[0].messages.count == 2)
        await #expect(throws: MailServiceError.noPassword) { try await MailService(account: account, password: nil).recent() }
    }

    @Test func sendingNeedsAMatchingApproval() async throws {
        let account = MailAccount(displayName: "Me", address: "me@example.com", imapHost: "127.0.0.1", imapSecurity: .none, smtpHost: "127.0.0.1", smtpSecurity: .none)
        let service = MailService(account: account, password: "pw")
        let draft = MailDraft(from: account.sender, to: [MailAddress(email: "a@example.com")], subject: "Hi", body: "text")
        for wrong in [SendApproval(accountID: UUID(), recipients: ["a@example.com"], subject: "Hi"),
                      SendApproval(accountID: account.id, recipients: ["other@example.com"], subject: "Hi"),
                      SendApproval(accountID: account.id, recipients: ["a@example.com"], subject: "Changed")] {
            await #expect(throws: MailServiceError.notApproved) { try await service.send(draft, approval: wrong) }
        }
    }

    @Test func unencryptedMailIsRefusedForRemoteHosts() {
        #expect(throws: MailTransportError.self) { try IMAPClient(host: "imap.example.com", port: 143, security: .none) }
        #expect(throws: MailTransportError.self) { try SMTPClient(host: "smtp.example.com", port: 25, security: .none) }
    }

    @Test func imapQuotingAndListParsing() {
        #expect(IMAPClient.quote("a\"b\\c\r\nd") == "\"a\\\"b\\\\cd\"")
        #expect(IMAPClient.parseList(#"* LIST (\Noselect \HasChildren) "." "Archive.2026""#) == .init(name: "Archive.2026", attributes: ["\\Noselect", "\\HasChildren"]))
        #expect(IMAPClient.parseList("* STATUS foo") == nil)
        #expect(SMTPClient.dotStuffed(Data(".a\r\nb".utf8)) == Data("..a\r\nb\r\n.\r\n".utf8))
    }
}

@Suite("Mail tools", .serialized)
struct MailToolTests {
    private func context() -> ToolExecutionContext { ToolExecutionContext(workspaceRoot: nil, conversationID: UUID()) }

    @Test func specsGateSendingBehindAdminApprovalAndReadingBehindTheNetworkTier() {
        let store = MailAccountStore(defaults: TestDefaults.suite("kiln.test.mailtools") ?? .standard)
        let specs = Dictionary(uniqueKeysWithValues: MailTool.Kind.allCases.map { ($0, MailTool(kind: $0, store: store).spec) })
        #expect(specs[.send]?.permission == .admin && specs[.send]?.isDestructive == true)
        #expect(specs[.accounts]?.permission == .read)
        #expect(specs[.read]?.permission == .execute && specs[.recent]?.permission == .execute)
        #expect(specs.values.allSatisfy { $0.name.hasPrefix("mail_") })
    }

    @Test func accountsListNeverShowsPasswords() async throws {
        let defaults = try #require(TestDefaults.suite("kiln.test.mailtools2"))
        defaults.removePersistentDomain(forName: "kiln.test.mailtools2")
        let store = MailAccountStore(defaults: defaults)
        let tool = MailTool(kind: .accounts, store: store)
        #expect(try await tool.execute(argumentsJSON: "{}", context: context()).contains("No email accounts"))
        try store.save(MailAccount(displayName: "A", address: "a@example.com", imapHost: "imap.example.com", smtpHost: "smtp.example.com"), password: nil)
        let text = try await tool.execute(argumentsJSON: "{}", context: context())
        #expect(text.contains("a@example.com") && text.contains("imap.example.com:993"))
        try store.remove(store.accounts()[0])
    }

    @Test func accountResolutionAndHelpers() throws {
        let tool = MailTool(kind: .recent, store: MailAccountStore(defaults: TestDefaults.suite("kiln.test.mailtools3") ?? .standard))
        let a = MailAccount(displayName: "", address: "a@x.com", imapHost: "i", smtpHost: "s"), b = MailAccount(displayName: "", address: "b@x.com", imapHost: "i", smtpHost: "s")
        #expect(try tool.resolve(nil, in: [a]) == a)
        #expect(try tool.resolve("B@X.com", in: [a, b]) == b)
        #expect(throws: (any Error).self) { try tool.resolve(nil, in: [a, b]) }
        #expect(throws: (any Error).self) { try tool.resolve("c@x.com", in: [a, b]) }
        #expect(throws: (any Error).self) { try tool.resolve(nil, in: []) }
        #expect(MailTool.oneLine("a\r\nb") == "a b")
    }

    @Test func renderedMessagesAreLabelledUntrustedAndTruncated() {
        var m = MailMessage(); m.from = [MailAddress(email: "x@y.z")]; m.subject = "S"; m.plainText = String(repeating: "a", count: 9000)
        m.attachments = [MailAttachment(filename: "f.pdf", contentType: "application/pdf", data: Data(count: 10))]
        let text = MailTool.render(m)
        #expect(text.hasPrefix(MailTool.untrustedNote) && text.contains("[truncated]") && text.contains("f.pdf (10 bytes)"))
    }
}
