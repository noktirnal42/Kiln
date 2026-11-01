import Foundation

/// A provider whose API key the user can enter in Settings.
public struct ProviderKeyEntry: Identifiable, Equatable, Sendable {
    public let id: String            // keychain account, and the provider's own id
    public let name: String
    public let keysPage: URL?        // where to create a key; nil when there is no fixed site
    public let keyPrefixHint: String?
    public let note: String
    public let needsBaseURL: Bool

    public static let all: [ProviderKeyEntry] = [
        ProviderKeyEntry(id: "openrouter", name: "OpenRouter",
                         keysPage: URL(string: "https://openrouter.ai/settings/keys"), keyPrefixHint: "sk-or-",
                         note: "Many hosted models behind one key, including free ones.", needsBaseURL: false),
        ProviderKeyEntry(id: "nvidia-nim", name: "NVIDIA NIM",
                         keysPage: URL(string: "https://build.nvidia.com/settings/api-keys"), keyPrefixHint: "nvapi-",
                         note: "Hosted NVIDIA-catalog models.", needsBaseURL: false),
        ProviderKeyEntry(id: "ollama-cloud", name: "Ollama Cloud",
                         keysPage: URL(string: "https://ollama.com/settings/keys"), keyPrefixHint: nil,
                         note: "Ollama's hosted models. Local Ollama needs no key.", needsBaseURL: false),
        ProviderKeyEntry(id: "custom", name: "Custom endpoint",
                         keysPage: nil, keyPrefixHint: nil,
                         note: "Any OpenAI-compatible server. Set its base URL; the key is optional.", needsBaseURL: true),
    ]
}

public enum ProviderKeyError: Error, Equatable, CustomStringConvertible {
    case empty, containsWhitespace, tooLong
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case .empty: "Paste a key first."
        case .containsWhitespace: "That does not look like a key: it contains spaces or line breaks."
        case .tooLong: "That is too long to be an API key."
        case .keychain(let status): "The Keychain refused the change (error \(status))."
        }
    }
}

/// Reads and writes provider keys in the Keychain. A key is never returned in full: the UI can ask
/// whether one exists and for its last four characters, nothing more.
public struct ProviderKeyStore: Sendable {
    let keychain: KeychainService
    let module: String

    public init(keychain: KeychainService = KeychainService(), module: String = providersKeychainModule) {
        self.keychain = keychain
        self.module = module
    }

    public static func clean(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ProviderKeyError.empty }
        guard key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw ProviderKeyError.containsWhitespace }
        guard key.count <= 512 else { throw ProviderKeyError.tooLong }
        return key
    }

    public func hasKey(_ id: String) -> Bool { keychain.get(module: module, key: id) != nil }

    public func lastFour(_ id: String) -> String? {
        keychain.get(module: module, key: id).map { String($0.suffix(4)) }
    }

    public func save(_ raw: String, for id: String) throws {
        let key = try Self.clean(raw)
        do { try keychain.set(key, module: module, key: id) }
        catch KeychainService.KeychainError.unexpectedStatus(let status) { throw ProviderKeyError.keychain(status) }
    }

    public func remove(_ id: String) throws {
        do { try keychain.delete(module: module, key: id) }
        catch KeychainService.KeychainError.unexpectedStatus(let status) { throw ProviderKeyError.keychain(status) }
    }
}
