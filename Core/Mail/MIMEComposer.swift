import Foundation

/// A draft the user has reviewed. Nothing here sends anything; the SMTP transport takes `MIMEComposer.compose` output.
public struct MailDraft: Equatable, Sendable {
    public var from: MailAddress
    public var to: [MailAddress]
    public var cc: [MailAddress] = []
    public var bcc: [MailAddress] = []
    public var subject: String
    public var body: String
    public var html: String?
    public var attachments: [MailAttachment] = []
    public var inReplyTo: String?
    public var references: [String] = []
    public init(from: MailAddress, to: [MailAddress], subject: String, body: String) { self.from = from; self.to = to; self.subject = subject; self.body = body }

    /// A reply to `message`: "Re:" subject once, threading headers set, the reply goes to the sender (and everyone else for `all`).
    public static func reply(to message: MailMessage, from me: MailAddress, all: Bool = false, body: String = "") -> MailDraft {
        var recipients = message.from
        if all { recipients += (message.to + message.cc).filter { $0.email.lowercased() != me.email.lowercased() } }
        var seen = Set<String>()
        recipients = recipients.filter { seen.insert($0.email.lowercased()).inserted }
        let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: " + message.subject
        var draft = MailDraft(from: me, to: recipients, subject: subject, body: body)
        draft.inReplyTo = message.messageID
        draft.references = message.references + (message.messageID.map { [$0] } ?? [])
        return draft
    }
}

public enum MIMEComposer {
    public enum ComposeError: Error, Equatable { case noRecipients, headerInjection }

    /// Builds the RFC 5322 text of a draft. Recipients are required; header values must not contain line breaks.
    public static func compose(_ draft: MailDraft, messageID: String = "\(UUID().uuidString)@kiln.local", date: Date = Date()) throws -> Data {
        guard !(draft.to + draft.cc + draft.bcc).isEmpty else { throw ComposeError.noRecipients }
        let fields = [draft.subject, draft.from.display] + (draft.to + draft.cc).map(\.display) + draft.references + [draft.inReplyTo ?? ""]
        // Scalars, not Characters: Swift treats CRLF as one Character that is neither "\r" nor "\n".
        guard !fields.contains(where: { $0.unicodeScalars.contains { $0 == "\r" || $0 == "\n" } }) else { throw ComposeError.headerInjection }
        var h: [String] = []
        h.append("From: \(address(draft.from))")
        h.append("To: \(draft.to.map(address).joined(separator: ", "))")
        if !draft.cc.isEmpty { h.append("Cc: \(draft.cc.map(address).joined(separator: ", "))") }
        h.append("Subject: \(encodeWord(draft.subject))")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        h.append("Date: \(f.string(from: date))")
        h.append("Message-ID: <\(messageID)>")
        if let r = draft.inReplyTo { h.append("In-Reply-To: <\(r)>") }
        if !draft.references.isEmpty { h.append("References: \(draft.references.map { "<\($0)>" }.joined(separator: " "))") }
        h.append("MIME-Version: 1.0")
        let text = textBody(draft)
        var out: String
        if draft.attachments.isEmpty {
            out = h.joined(separator: "\r\n") + "\r\n" + text.headers + "\r\n\r\n" + text.body
        } else {
            let boundary = "kiln-" + UUID().uuidString
            var parts = ["--\(boundary)\r\n" + text.headers + "\r\n\r\n" + text.body]
            for a in draft.attachments {
                let safe = a.filename.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                parts.append("--\(boundary)\r\nContent-Type: \(a.contentType); name=\"\(safe)\"\r\nContent-Disposition: attachment; filename=\"\(safe)\"\r\nContent-Transfer-Encoding: base64\r\n\r\n" + wrap(a.data.base64EncodedString()))
            }
            out = h.joined(separator: "\r\n") + "\r\nContent-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n" + parts.joined(separator: "\r\n") + "\r\n--\(boundary)--"
        }
        return Data((out + "\r\n").utf8)
    }

    private static func textBody(_ draft: MailDraft) -> (headers: String, body: String) {
        let plain = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64"
        guard let html = draft.html else { return (plain, wrap(Data(draft.body.utf8).base64EncodedString())) }
        let boundary = "kiln-alt-" + UUID().uuidString
        let body = "--\(boundary)\r\n\(plain)\r\n\r\n\(wrap(Data(draft.body.utf8).base64EncodedString()))\r\n--\(boundary)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(wrap(Data(html.utf8).base64EncodedString()))\r\n--\(boundary)--"
        return ("Content-Type: multipart/alternative; boundary=\"\(boundary)\"", body)
    }

    static func address(_ a: MailAddress) -> String {
        guard let name = a.name, !name.isEmpty else { return a.email }
        return "\(encodeWord(name)) <\(a.email)>"
    }

    /// RFC 2047 B-encoding for anything that is not plain ASCII.
    static func encodeWord(_ value: String) -> String {
        value.allSatisfy { $0.isASCII } ? value : "=?utf-8?B?\(Data(value.utf8).base64EncodedString())?="
    }

    private static func wrap(_ base64: String) -> String {
        stride(from: 0, to: base64.count, by: 76).map { i in
            let start = base64.index(base64.startIndex, offsetBy: i)
            return String(base64[start..<base64.index(start, offsetBy: min(76, base64.count - i))])
        }.joined(separator: "\r\n")
    }
}
