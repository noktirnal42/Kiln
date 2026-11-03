import CryptoKit
import Foundation

/// What the Mac shows (as a QR code or a link) to pair a device. The key never travels over the network: it is
/// read off the screen, so only someone looking at the Mac can pair.
public struct PairingPayload: Equatable, Sendable {
    public var hostName: String
    /// Bonjour service name to look up; the device connects to whatever address that resolves to.
    public var serviceName: String
    public var key: Data

    public init(hostName: String, serviceName: String, key: Data) { self.hostName = hostName; self.serviceName = serviceName; self.key = key }

    public static func makeKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "kiln-remote"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: hostName),
            URLQueryItem(name: "service", value: serviceName),
            URLQueryItem(name: "key", value: Self.base64URL(key)),
            URLQueryItem(name: "v", value: String(kilnRemoteProtocolVersion)),
        ]
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == "kiln-remote", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let host = value("host"), let service = value("service"), let keyText = value("key"),
              let key = Self.fromBase64URL(keyText), key.count == 32, value("v") == String(kilnRemoteProtocolVersion) else { return nil }
        self.init(hostName: host, serviceName: service, key: key)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64URL(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)
    }
}
