import Foundation

/// An address as it appears in a header: "Ada Lovelace <ada@example.com>".
public struct MailAddress: Equatable, Hashable, Sendable, Codable {
    public var name: String?
    public var email: String
    public init(name: String? = nil, email: String) { self.name = name; self.email = email }
    public var display: String { name.map { "\($0) <\(email)>" } ?? email }
}

public struct MailAttachment: Equatable, Sendable {
    public var filename: String
    public var contentType: String
    public var data: Data
    public init(filename: String, contentType: String, data: Data) { self.filename = filename; self.contentType = contentType; self.data = data }
}

/// A parsed message. Raw bytes stay on the provider; Kiln keeps what it needs to show, search and thread.
public struct MailMessage: Equatable, Sendable {
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String] = []
    public var from: [MailAddress] = []
    public var to: [MailAddress] = []
    public var cc: [MailAddress] = []
    public var subject: String = ""
    public var date: Date?
    public var plainText: String?
    public var html: String?
    public var attachments: [MailAttachment] = []
    public var headers: [String: String] = [:]   // lower-cased name -> unfolded value (first occurrence)
    public init() {}
}
