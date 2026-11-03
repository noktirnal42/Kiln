import Foundation
import KilnRemoteKit
import Security

/// A Mac this phone is paired with. The key lives in the Keychain; the names are not secret.
struct PairedMac: Equatable, Sendable {
    var hostName: String
    var serviceName: String
    var key: Data
    /// Kiln relay for off-network use (from the pairing link), if the Mac offered one.
    var relay: URL?
    /// "host:port" typed in Settings (a Tailscale or direct address); skips Bonjour when set.
    var address: String?
    /// "host:port" addresses from the pairing link (Wi-Fi, Ethernet, VPN), tried before Bonjour.
    var direct: [String]

    init(hostName: String, serviceName: String, key: Data, relay: URL? = nil, address: String? = nil, direct: [String] = []) {
        self.hostName = hostName; self.serviceName = serviceName; self.key = key; self.relay = relay; self.address = address; self.direct = direct
    }

    /// `address` split into host and port, if it is valid.
    var manualEndpoint: (host: String, port: UInt16)? { address.flatMap(Self.parse) }

    static func parse(_ address: String) -> (host: String, port: UInt16)? {
        let address = address.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return nil }
        if address.hasPrefix("["), let close = address.firstIndex(of: "]"),
           let port = UInt16(address[address.index(after: close)...].dropFirst()) {
            return (String(address[address.index(after: address.startIndex)..<close]), port)
        }
        guard let colon = address.lastIndex(of: ":"), let port = UInt16(address[address.index(after: colon)...]), port > 0 else { return nil }
        let host = String(address[..<colon])
        return host.isEmpty ? nil : (host, port)
    }

    static func == (a: PairedMac, b: PairedMac) -> Bool {
        a.hostName == b.hostName && a.serviceName == b.serviceName && a.key == b.key && a.relay == b.relay && a.address == b.address && a.direct == b.direct
    }
}

protocol PairingStoring: Sendable {
    func load() -> PairedMac?
    func save(_ mac: PairedMac) throws
    func clear()
}

/// Keychain-backed (this-device-only, available after first unlock so a reconnect in the background still works).
struct KeychainPairingStore: PairingStoring {
    var service = "com.kiln.remote.pairing"
    private let account = "paired-mac"

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private struct Stored: Codable { var hostName: String; var serviceName: String; var key: Data; var relay: URL?; var address: String?; var direct: [String]? }

    func load() -> PairedMac? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.key.count == 32 else { return nil }
        return PairedMac(hostName: stored.hostName, serviceName: stored.serviceName, key: stored.key, relay: stored.relay, address: stored.address, direct: stored.direct ?? [])
    }

    func save(_ mac: PairedMac) throws {
        clear()
        let data = try JSONEncoder().encode(Stored(hostName: mac.hostName, serviceName: mac.serviceName, key: mac.key, relay: mac.relay, address: mac.address, direct: mac.direct))
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "The Keychain refused the pairing key (\(status))."]) }
    }

    func clear() { SecItemDelete(base as CFDictionary) }
}

/// In-memory store for tests and previews.
final class MemoryPairingStore: PairingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var mac: PairedMac?
    init(_ mac: PairedMac? = nil) { self.mac = mac }
    func load() -> PairedMac? { lock.withLock { mac } }
    func save(_ mac: PairedMac) throws { lock.withLock { self.mac = mac } }
    func clear() { lock.withLock { mac = nil } }
}
