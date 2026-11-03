import CryptoKit
import Foundation

/// What the Mac shows (as a QR code or a link) to pair a device. The key never travels over the network: it is
/// read off the screen, so only someone looking at the Mac can pair.
public struct PairingPayload: Equatable, Sendable {
    public var hostName: String
    /// Bonjour service name to look up; the device connects to whatever address that resolves to.
    public var serviceName: String
    public var key: Data
    /// Where devices reach this Mac over the internet (wss URL of a Kiln relay); nil means local network only.
    public var relay: URL?
    /// "host:port" addresses the Mac listens on right now (Wi-Fi, Ethernet, VPN). Devices try these first, because
    /// Bonjour discovery is unreliable on watchOS and does not cross a VPN.
    public var direct: [String]

    public init(hostName: String, serviceName: String, key: Data, relay: URL? = nil, direct: [String] = []) {
        self.hostName = hostName; self.serviceName = serviceName; self.key = key; self.relay = relay; self.direct = direct
    }

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
        if let relay { components.queryItems?.append(URLQueryItem(name: "relay", value: relay.absoluteString)) }
        if !direct.isEmpty { components.queryItems?.append(URLQueryItem(name: "direct", value: direct.joined(separator: ","))) }
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == "kiln-remote", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let host = value("host"), let service = value("service"), let keyText = value("key"),
              let key = Self.fromBase64URL(keyText), key.count == 32, value("v") == String(kilnRemoteProtocolVersion) else { return nil }
        let relay = value("relay").flatMap(URL.init(string:)).flatMap { $0.scheme == "wss" || $0.scheme == "ws" ? $0 : nil }
        let direct = (value("direct") ?? "").split(separator: ",").map(String.init).filter(Self.isHostPort)
        self.init(hostName: host, serviceName: service, key: key, relay: relay, direct: direct)
    }

    /// "1.2.3.4:5678" or "name.local:5678": something a socket can be opened to, nothing that smuggles in a path or scheme.
    static func isHostPort(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port), !parts[0].isEmpty else { return false }
        return parts[0].allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
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
