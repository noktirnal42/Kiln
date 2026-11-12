import Foundation

/// What a user (or an agent on their behalf) has agreed to send. The service refuses to send without one, so an agent can draft freely
/// but cannot send until the person has seen the destination and the text.
public struct SendApproval: Equatable, Sendable {
    public var accountID: UUID
    public var recipients: [String]
    public var subject: String
    public init(accountID: UUID, recipients: [String], subject: String) { self.accountID = accountID; self.recipients = recipients; self.subject = subject }
}

public enum MailServiceError: Error, Equatable, LocalizedError {
    case noPassword, notApproved
    public var errorDescription: String? {
        switch self {
        case .noPassword: "No password is saved for this account. Edit the account and enter it again."
        case .notApproved: "The send was not approved for these recipients and this subject."
        }
    }
}

/// Reads mail for one account and sends drafts that were approved. Stateless: nothing is cached on disk yet.
public struct MailService: Sendable {
    public let account: MailAccount
    private let password: @Sendable () -> String?

    public init(account: MailAccount, store: MailAccountStore = MailAccountStore()) {
        self.account = account
        self.password = { store.password(for: account) }
    }

    /// For tests and previews: supply the password directly.
    public init(account: MailAccount, password: String?) {
        self.account = account
        self.password = { password }
    }

    public struct Summary: Equatable, Sendable {
        public var uid: UInt32
        public var flags: [String]
        public var message: MailMessage
        public var isUnread: Bool { !flags.contains("\\Seen") }
    }

    public func folders() async throws -> [IMAPClient.Mailbox] {
        try await withClient { try await $0.listMailboxes() }
    }

    /// The newest `limit` messages of `mailbox`, newest first, fetched without changing their read state.
    public func recent(in mailbox: String = "INBOX", limit: Int = 25) async throws -> [Summary] {
        try await withClient { client in
            _ = try await client.select(mailbox)
            let uids = try await client.searchUIDs().sorted(by: >).prefix(max(1, limit))
            return try await client.fetch(uids: Array(uids)).map { Summary(uid: $0.uid, flags: $0.flags, message: MIMEParser.parse($0.raw)) }
                .sorted { $0.uid > $1.uid }
        }
    }

    /// One message by UID, without changing its read state.
    public func message(uid: UInt32, in mailbox: String = "INBOX") async throws -> Summary? {
        try await withClient { client in
            _ = try await client.select(mailbox)
            return try await client.fetch(uids: [uid]).first.map { Summary(uid: $0.uid, flags: $0.flags, message: MIMEParser.parse($0.raw)) }
        }
    }

    public func threads(in mailbox: String = "INBOX", limit: Int = 25) async throws -> [MailThreading.Thread] {
        MailThreading.threads(try await recent(in: mailbox, limit: limit).map(\.message))
    }

    /// Sends a draft. `approval` must match the draft's account, recipients (To, Cc and Bcc) and subject exactly.
    public func send(_ draft: MailDraft, approval: SendApproval) async throws {
        let recipients = (draft.to + draft.cc + draft.bcc).map(\.email)
        guard approval.accountID == account.id, Set(approval.recipients.map { $0.lowercased() }) == Set(recipients.map { $0.lowercased() }),
              approval.subject == draft.subject else { throw MailServiceError.notApproved }
        guard let password = password() else { throw MailServiceError.noPassword }
        let raw = try MIMEComposer.compose(draft)
        let client = try SMTPClient(host: account.smtpHost, port: account.smtpPort, security: account.smtpSecurity)
        try await client.send(raw, from: account.address, to: recipients, user: account.username, password: password)
    }

    private func withClient<T: Sendable>(_ body: (IMAPClient) async throws -> T) async throws -> T {
        guard let password = password() else { throw MailServiceError.noPassword }
        let client = try IMAPClient(host: account.imapHost, port: account.imapPort, security: account.imapSecurity)
        try await client.connect()
        do {
            try await client.login(user: account.username, password: password)
            let result = try await body(client)
            await client.logout()
            return result
        } catch {
            await client.logout()
            throw error
        }
    }
}
