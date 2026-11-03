import Foundation
import KilnRemoteKit

/// The pairing key and Bonjour name, kept owner-only in Application Support. Rotating the key unpairs every device.
public struct RemotePairingStore: Sendable {
    private struct Stored: Codable { var key: Data; var serviceName: String }
    private let url: URL
    /// The folder the pairing (and the push registrations beside it) lives in.
    public var directory: URL { url.deletingLastPathComponent() }

    public init(directory: URL) { url = directory.appendingPathComponent("remote-pairing.json") }

    public func load() -> (key: Data, serviceName: String) {
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.key.count == 32 {
            return (stored.key, stored.serviceName)
        }
        return rotate()
    }

    @discardableResult
    public func rotate() -> (key: Data, serviceName: String) {
        let stored = Stored(key: PairingPayload.makeKey(), serviceName: "Kiln-" + String(UUID().uuidString.prefix(6)))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return (stored.key, stored.serviceName)
    }
}
