import CryptoKit
import Foundation

public enum SecureChannelError: Error, Equatable {
    case badFrame, outOfOrder, authenticationFailed
}

/// Encrypts and authenticates every frame with a key only the paired devices know, whatever carries the bytes
/// (a WebSocket on the local network, Bluetooth, a relay). Each direction has its own key and a strictly increasing
/// counter, so a captured frame cannot be replayed, reordered or reflected back.
public struct SecureChannel: Sendable {
    public enum Role: Sendable { case mac, device }

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    /// `clientNonce` and `serverNonce` are random values each side contributes at connection time, so two
    /// connections made with the same pairing key never share session keys.
    public init(pairingKey: Data, clientNonce: Data, serverNonce: Data, role: Role) {
        let master = SymmetricKey(data: pairingKey)
        let salt = clientNonce + serverNonce
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: Data(label.utf8), outputByteCount: 32)
        }
        let deviceToMac = derive("kiln-remote device->mac")
        let macToDevice = derive("kiln-remote mac->device")
        switch role {
        case .mac: sendKey = macToDevice; receiveKey = deviceToMac
        case .device: sendKey = deviceToMac; receiveKey = macToDevice
        }
    }

    public static func makeNonce() -> Data { SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) } }

    /// counter (8 bytes) ‖ ciphertext ‖ tag
    public mutating func seal(_ plaintext: Data) throws -> Data {
        let counter = sendCounter
        sendCounter += 1
        let header = Self.header(counter)
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(counter), authenticating: header)
        return header + box.ciphertext + box.tag
    }

    public mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= 8 + 16 else { throw SecureChannelError.badFrame }
        let header = frame.prefix(8)
        let counter = header.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard counter == receiveCounter else { throw SecureChannelError.outOfOrder }
        let body = frame.dropFirst(8)
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(nonce: Self.nonce(counter), ciphertext: body.dropLast(16), tag: body.suffix(16))
            let plaintext = try ChaChaPoly.open(box, using: receiveKey, authenticating: Data(header))
            receiveCounter += 1
            return plaintext
        } catch { throw SecureChannelError.authenticationFailed }
    }

    private static func header(_ counter: UInt64) -> Data {
        var value = counter.littleEndian
        return Data(bytes: &value, count: 8)
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: Data(count: 4) + header(counter))
    }
}
