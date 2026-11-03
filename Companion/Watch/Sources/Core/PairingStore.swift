import Foundation
import KilnRemoteKit
import Security

/// Where the pairing key lives on the watch.
protocol PairingStoring: Sendable {
    func load() -> PairingPayload?
    func save(_ payload: PairingPayload)
    func clear()
}

/// The pairing link (which carries the 256-bit key) is kept as one Keychain item, never in UserDefaults.
struct KeychainPairingStore: PairingStoring {
    var service = "com.kiln.remote.watchkitapp.pairing"
    private let account = "mac"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> PairingPayload? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8), let url = URL(string: text) else { return nil }
        return PairingPayload(url: url)
    }

    func save(_ payload: PairingPayload) {
        clear()
        var request = query
        request[kSecValueData as String] = Data(payload.url.absoluteString.utf8)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(request as CFDictionary, nil)
    }

    func clear() { SecItemDelete(query as CFDictionary) }
}

final class InMemoryPairingStore: PairingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var payload: PairingPayload?
    init(_ payload: PairingPayload? = nil) { self.payload = payload }
    func load() -> PairingPayload? { lock.withLock { payload } }
    func save(_ payload: PairingPayload) { lock.withLock { self.payload = payload } }
    func clear() { lock.withLock { payload = nil } }
}
