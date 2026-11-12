import Foundation

/// The Slack token lives in the macOS Keychain and nowhere else: not in preferences, logs or tool output.
public struct SlackTokenStore: Sendable {
    static let keychainModule = "slack"
    static let key = "token"
    private let read: @Sendable () -> String?
    private let write: @Sendable (String) throws -> Void
    private let erase: @Sendable () throws -> Void

    /// The Keychain by default; tests pass in-memory storage.
    public init(keychain: KeychainService = KeychainService()) {
        read = { keychain.get(module: Self.keychainModule, key: Self.key) }
        write = { try keychain.set($0, module: Self.keychainModule, key: Self.key) }
        erase = { try keychain.delete(module: Self.keychainModule, key: Self.key) }
    }

    init(read: @escaping @Sendable () -> String?, write: @escaping @Sendable (String) throws -> Void, erase: @escaping @Sendable () throws -> Void) {
        self.read = read; self.write = write; self.erase = erase
    }

    public func token() -> String? { read() }
    public func save(_ token: String) throws { try write(token) }
    public func remove() throws { try erase() }

    /// Bot (`xoxb-`) and user (`xoxp-`) tokens only. An app-level token (`xapp-`), a signing secret or any other string is refused up front.
    public static func shapeProblem(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { return "Paste a Slack token." }
        if token.contains(where: { $0.isWhitespace }) { return "A Slack token has no spaces." }
        if token.hasPrefix("xapp-") { return "That is an app-level token. Use the Bot User OAuth Token (starts with xoxb-) or a user token (xoxp-)." }
        guard token.hasPrefix("xoxb-") || token.hasPrefix("xoxp-") else { return "A Slack bot token starts with xoxb- and a user token with xoxp-." }
        if token.count < 20 { return "That token looks too short." }
        return nil
    }
}
