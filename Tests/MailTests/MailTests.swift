import Foundation
import Testing
@testable import Kiln

@Suite("Mail MIME")
struct MIMEParserTests {
    private func parse(_ s: String) -> MailMessage { MIMEParser.parse(Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8)) }

    @Test func headersAddressesAndPlainBody() {
        let m = parse("""
        From: "Ada Lovelace" <ada@example.com>
        To: bob@example.com, Carol <carol@example.com>
        Subject: Hello
         there
        Date: Tue, 10 Nov 2026 09:30:00 -0700
        Message-ID: <abc@example.com>
        Content-Type: text/plain; charset=utf-8

        Hi Bob.
        """)
        #expect(m.from == [MailAddress(name: "Ada Lovelace", email: "ada@example.com")])
        #expect(m.to.map(\.email) == ["bob@example.com", "carol@example.com"])
        #expect(m.subject == "Hello there")
        #expect(m.messageID == "abc@example.com")
        #expect(m.date != nil)
        #expect(m.plainText?.trimmingCharacters(in: .whitespacesAndNewlines) == "Hi Bob.")
    }

    @Test func encodedWordsAndQuotedPrintable() {
        #expect(MIMEParser.decodeWords("=?UTF-8?B?w4lj?=ole") == "École")
        #expect(MIMEParser.decodeWords("=?iso-8859-1?Q?Caf=E9_au_lait?=") == "Café au lait")
        let m = parse("""
        Subject: =?utf-8?Q?R=C3=A9sum=C3=A9?=
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Caf=C3=A9 =
        continues
        """)
        #expect(m.subject == "Résumé")
        #expect(m.plainText?.hasPrefix("Café continues") == true)
    }

    @Test func multipartAlternativeAndAttachment() {
        let m = parse("""
        Subject: Report
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary="inner"

        --inner
        Content-Type: text/plain

        plain body
        --inner
        Content-Type: text/html

        <p>html body</p>
        --inner--
        --outer
        Content-Type: application/pdf; name="r.pdf"
        Content-Disposition: attachment; filename="r.pdf"
        Content-Transfer-Encoding: base64

        SGVsbG8=
        --outer--
        """)
        #expect(m.plainText == "plain body")
        #expect(m.html == "<p>html body</p>")
        #expect(m.attachments.count == 1)
        #expect(m.attachments[0].filename == "r.pdf")
        #expect(String(decoding: m.attachments[0].data, as: UTF8.self) == "Hello")
    }

    @Test func garbageDoesNotCrash() {
        let m = MIMEParser.parse(Data([0xff, 0xfe, 0x00, 0x3a]))
        #expect(m.attachments.isEmpty)
        #expect(MIMEParser.addresses("not an address, <>, x@y.z").map(\.email) == ["x@y.z"])
    }
}

@Suite("Mail threading and composing")
struct MailThreadingAndComposeTests {
    private func msg(_ id: String, subject: String, reply: String? = nil, refs: [String] = [], at t: TimeInterval) -> MailMessage {
        var m = MailMessage(); m.messageID = id; m.subject = subject; m.inReplyTo = reply; m.references = refs; m.date = Date(timeIntervalSince1970: t); return m
    }

    @Test func referencesJoinThreadsAndSubjectsFallBack() {
        let a = msg("a", subject: "Plan", at: 1)
        let b = msg("b", subject: "Re: Plan", reply: "a", refs: ["a"], at: 2)
        let c = msg("c", subject: "RE: Re: Plan", reply: "b", refs: ["a", "b"], at: 3)
        let other = msg("x", subject: "Lunch", at: 4)
        let noHeaders = msg("y", subject: "Fwd: Lunch", at: 5)
        let threads = MailThreading.threads([c, a, other, b, noHeaders])
        #expect(threads.count == 2)
        #expect(threads[0].messages.map(\.messageID) == ["x", "y"])
        #expect(threads[1].messages.map(\.messageID) == ["a", "b", "c"])
        #expect(threads[1].subject == "Plan")
        #expect(MailThreading.normalizedSubject("Re: RE: [2] x") == "[2] x".lowercased() || MailThreading.normalizedSubject("Re: RE: [2] x") == "x")
    }

    @Test func composedMessageRoundTripsThroughTheParser() throws {
        var d = MailDraft(from: MailAddress(name: "Ada", email: "ada@example.com"), to: [MailAddress(name: "Zoë", email: "zoe@example.com")], subject: "Café plans", body: "Héllo\nworld")
        d.attachments = [MailAttachment(filename: "n.txt", contentType: "text/plain", data: Data("note".utf8))]
        let raw = try MIMEComposer.compose(d, messageID: "id1@kiln.local")
        let m = MIMEParser.parse(raw)
        #expect(m.subject == "Café plans")
        #expect(m.to == [MailAddress(name: "Zoë", email: "zoe@example.com")])
        #expect(m.messageID == "id1@kiln.local")
        #expect(m.plainText == "Héllo\nworld")
        #expect(m.attachments.first?.filename == "n.txt")
        #expect(String(decoding: m.attachments[0].data, as: UTF8.self) == "note")
    }

    @Test func repliesKeepThreadingAndDropDuplicates() {
        var original = MailMessage()
        original.messageID = "m1"; original.references = ["m0"]; original.subject = "Plan"
        original.from = [MailAddress(email: "ada@example.com")]
        original.to = [MailAddress(email: "me@example.com"), MailAddress(email: "bob@example.com")]
        original.cc = [MailAddress(email: "ADA@example.com")]
        let me = MailAddress(email: "me@example.com")
        let one = MailDraft.reply(to: original, from: me)
        #expect(one.subject == "Re: Plan" && one.to.map(\.email) == ["ada@example.com"])
        #expect(one.inReplyTo == "m1" && one.references == ["m0", "m1"])
        let all = MailDraft.reply(to: original, from: me, all: true)
        #expect(all.to.map(\.email) == ["ada@example.com", "bob@example.com"])
        #expect(MailDraft.reply(to: MailMessage(), from: me).subject == "Re: ")
    }

    @Test func composeRefusesNoRecipientsAndHeaderInjection() {
        let me = MailAddress(email: "me@example.com")
        #expect(throws: MIMEComposer.ComposeError.noRecipients) { try MIMEComposer.compose(MailDraft(from: me, to: [], subject: "s", body: "b")) }
        #expect(throws: MIMEComposer.ComposeError.headerInjection) {
            try MIMEComposer.compose(MailDraft(from: me, to: [MailAddress(email: "a@b.c")], subject: "hi\r\nBcc: evil@x.com", body: "b"))
        }
    }
}

@Suite("Mail accounts")
struct MailAccountTests {
    @Test func presetsFillKnownProvidersAndKeepTheAddressAsUsername() throws {
        let a = try #require(MailAccount.preset(for: "ada@gmail.com", displayName: "Ada"))
        #expect(a.imapHost == "imap.gmail.com" && a.smtpPort == 465 && a.username == "ada@gmail.com")
        #expect(a.sender == MailAddress(name: "Ada", email: "ada@gmail.com"))
        #expect(MailAccount.preset(for: "ada@unknown.example") == nil)
        #expect(MailAccount.preset(for: "not-an-address") == nil)
    }

    @Test func validationRequiresTLSForRemoteServers() {
        var a = MailAccount(displayName: "", address: "a@b.c", imapHost: "imap.b.c", smtpHost: "smtp.b.c")
        #expect(a.validationProblem == nil)
        a.imapSecurity = .none
        #expect(a.validationProblem == "Incoming mail must use TLS.")
        a.imapHost = "localhost"
        #expect(a.validationProblem == nil)
        a.address = "nope"
        #expect(a.validationProblem == "Enter a full email address.")
    }

    @Test func storeKeepsSettingsInPreferencesAndPasswordsOutOfThem() throws {
        let defaults = try #require(TestDefaults.suite("kiln.test.mailaccounts"))
        defaults.removePersistentDomain(forName: "kiln.test.mailaccounts")
        let store = MailAccountStore(defaults: defaults)
        let account = MailAccount(displayName: "Ada", address: "ada@example.com", imapHost: "imap.example.com", smtpHost: "smtp.example.com")
        try store.save(account, password: "s3cret-test-value")
        #expect(store.accounts() == [account])
        #expect(store.password(for: account) == "s3cret-test-value")
        let stored = String(decoding: defaults.data(forKey: MailAccountStore.defaultsKey) ?? Data(), as: UTF8.self)
        #expect(!stored.contains("s3cret-test-value"))
        try store.remove(account)
        #expect(store.accounts().isEmpty && store.password(for: account) == nil)
        var bad = account; bad.address = "x"
        #expect(throws: MailTransportError.self) { try store.save(bad, password: nil) }
    }
}
