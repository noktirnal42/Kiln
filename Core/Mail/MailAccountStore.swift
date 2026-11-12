import Foundation

/// A mail account's settings. The password is never part of this struct: it lives in the Keychain under the account's id.
public struct MailAccount: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var address: String
    public var username: String
    public var imapHost: String
    public var imapPort: Int
    public var imapSecurity: MailSecurity
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpSecurity: MailSecurity

    public init(id: UUID = UUID(), displayName: String, address: String, username: String? = nil,
                imapHost: String, imapPort: Int = 993, imapSecurity: MailSecurity = .tls,
                smtpHost: String, smtpPort: Int = 465, smtpSecurity: MailSecurity = .tls) {
        self.id = id; self.displayName = displayName; self.address = address; self.username = username ?? address
        self.imapHost = imapHost; self.imapPort = imapPort; self.imapSecurity = imapSecurity
        self.smtpHost = smtpHost; self.smtpPort = smtpPort; self.smtpSecurity = smtpSecurity
    }

    public var sender: MailAddress { MailAddress(name: displayName.isEmpty ? nil : displayName, email: address) }

    /// Settings for providers whose servers are well known; the user still types the password (an app password where the provider requires one).
    public static func preset(for address: String, displayName: String = "") -> MailAccount? {
        guard let domain = address.split(separator: "@").last?.lowercased(), address.contains("@") else { return nil }
        let table: [String: (String, String)] = [
            "gmail.com": ("imap.gmail.com", "smtp.gmail.com"), "googlemail.com": ("imap.gmail.com", "smtp.gmail.com"),
            "icloud.com": ("imap.mail.me.com", "smtp.mail.me.com"), "me.com": ("imap.mail.me.com", "smtp.mail.me.com"),
            "outlook.com": ("outlook.office365.com", "smtp.office365.com"), "hotmail.com": ("outlook.office365.com", "smtp.office365.com"),
            "yahoo.com": ("imap.mail.yahoo.com", "smtp.mail.yahoo.com"), "fastmail.com": ("imap.fastmail.com", "smtp.fastmail.com"),
        ]
        guard let hosts = table[domain] else { return nil }
        return MailAccount(displayName: displayName, address: address, imapHost: hosts.0, smtpHost: hosts.1)
    }

    public var validationProblem: String? {
        if !address.contains("@") || address.hasPrefix("@") || address.hasSuffix("@") { return "Enter a full email address." }
        if imapHost.isEmpty || smtpHost.isEmpty { return "Enter the incoming and outgoing server names." }
        if imapSecurity == .none && !["localhost", "127.0.0.1", "::1"].contains(imapHost) { return "Incoming mail must use TLS." }
        if smtpSecurity == .none && !["localhost", "127.0.0.1", "::1"].contains(smtpHost) { return "Outgoing mail must use TLS." }
        return nil
    }
}

/// Accounts are listed in preferences (no secrets); passwords are in the Keychain. Removing an account removes its password.
public struct MailAccountStore {
    public static let defaultsKey = "mail.accounts"
    static let keychainModule = "mail"
    private let defaults: UserDefaults
    private let keychain: KeychainService

    public init(defaults: UserDefaults = .standard, keychain: KeychainService = KeychainService()) {
        self.defaults = defaults; self.keychain = keychain
    }

    public func accounts() -> [MailAccount] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([MailAccount].self, from: data)) ?? []
    }

    public func save(_ account: MailAccount, password: String?) throws {
        if let problem = account.validationProblem { throw MailTransportError.serverRejected(problem) }
        var all = accounts().filter { $0.id != account.id }
        all.append(account)
        defaults.set(try JSONEncoder().encode(all), forKey: Self.defaultsKey)
        if let password, !password.isEmpty { try keychain.set(password, module: Self.keychainModule, key: account.id.uuidString) }
    }

    public func password(for account: MailAccount) -> String? { keychain.get(module: Self.keychainModule, key: account.id.uuidString) }

    public func remove(_ account: MailAccount) throws {
        defaults.set(try JSONEncoder().encode(accounts().filter { $0.id != account.id }), forKey: Self.defaultsKey)
        try? keychain.delete(module: Self.keychainModule, key: account.id.uuidString)
    }
}
