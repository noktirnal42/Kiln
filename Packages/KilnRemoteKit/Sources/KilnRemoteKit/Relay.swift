import CryptoKit
import Foundation

/// How a Mac and its devices find each other through a relay on the internet, with no account and nothing the relay
/// can read. Both sides derive the same room name and password from the pairing key; the relay only ever sees the room
/// name, a password it checks, and ciphertext (every frame is already sealed by `SecureChannel`).
public enum RelayAddress {
    public enum Role: String, Sendable { case mac, device }

    /// Non-secret room name: it cannot be turned back into the key.
    public static func roomID(pairingKey: Data) -> String {
        base64URL(Data(HMAC<SHA256>.authenticationCode(for: Data("kiln-relay room v1".utf8), using: SymmetricKey(data: pairingKey)).prefix(16)))
    }

    /// What the relay compares to decide who may join the room. The first Mac to claim a room sets it.
    public static func authToken(pairingKey: Data) -> String {
        base64URL(Data(HMAC<SHA256>.authenticationCode(for: Data("kiln-relay auth v1".utf8), using: SymmetricKey(data: pairingKey))))
    }

    /// `wss://relay.example/v1/room/<room>?role=mac|device` (the token goes in the `Authorization` header, never the URL).
    public static func url(relay: URL, pairingKey: Data, role: Role) -> URL? {
        var components = URLComponents(url: relay, resolvingAgainstBaseURL: false)
        var path = components?.path ?? ""
        if path.hasSuffix("/") { path.removeLast() }
        components?.path = path + "/v1/room/" + roomID(pairingKey: pairingKey)
        components?.queryItems = [URLQueryItem(name: "role", value: role.rawValue)]
        return components?.url
    }

    public static func authorizationHeader(pairingKey: Data) -> String { "Bearer " + authToken(pairingKey: pairingKey) }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Frames between the relay and the Mac, which serves many devices over one socket: type byte, 4-byte device id (big
/// endian), then the payload. Devices themselves speak the plain protocol with no prefix.
public enum RelayFrame {
    public enum Kind: UInt8, Sendable {
        case data = 1          // payload for / from one device
        case deviceJoined = 2  // relay → Mac
        case deviceLeft = 3    // relay → Mac
        case closeDevice = 4   // Mac → relay
    }

    public static func encode(_ kind: Kind, device: UInt32, payload: Data = Data()) -> Data {
        var data = Data([kind.rawValue])
        withUnsafeBytes(of: device.bigEndian) { data.append(contentsOf: $0) }
        return data + payload
    }

    public static func decode(_ frame: Data) -> (kind: Kind, device: UInt32, payload: Data)? {
        guard frame.count >= 5, let kind = Kind(rawValue: frame[frame.startIndex]) else { return nil }
        let id = frame.dropFirst().prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (kind, id, Data(frame.dropFirst(5)))
    }
}
