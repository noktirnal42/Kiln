import Foundation
import KilnRemoteKit

/// One authenticated connection: runs the nonce handshake from docs/14-REMOTE-CONTROL.md, seals every command and
/// opens every event with `SecureChannel`. Reuses the package, adds no protocol of its own.
actor RemoteClient {
    private let transport: RemoteTransport
    private let pairingKey: Data
    private let deviceName: String
    private var channel: SecureChannel?
    private var pump: Task<Void, Never>?

    init(transport: RemoteTransport, pairingKey: Data, deviceName: String) {
        self.transport = transport
        self.pairingKey = pairingKey
        self.deviceName = deviceName
    }

    private var clientNonce = Data()

    /// Sends the client nonce and returns the decrypted events. The first event is `welcome`; the stream ends
    /// (or throws) when the Mac drops the connection, which is also what a wrong key looks like.
    func connect() -> AsyncThrowingStream<RemoteEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RemoteEvent.self)
        clientNonce = SecureChannel.makeNonce()
        transport.send(clientNonce)
        let incoming = transport.incoming
        pump = Task { [self] in
            do {
                for try await frame in incoming {
                    if let event = try handle(frame) { continuation.yield(event) }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { [transport] _ in transport.close() }
        return stream
    }

    private func handle(_ frame: Data) throws -> RemoteEvent? {
        guard var channel = channel else {
            guard frame.count == 16 else { throw RemoteError.badHandshake }
            var fresh = SecureChannel(pairingKey: pairingKey, clientNonce: clientNonce, serverNonce: frame, role: .device)
            transport.send(try fresh.seal(RemoteCoding.encode(RemoteCommand.hello(deviceName: deviceName, protocolVersion: kilnRemoteProtocolVersion))))
            self.channel = fresh
            return nil
        }
        let plain = try channel.open(frame)
        self.channel = channel
        return try RemoteCoding.decode(RemoteEvent.self, from: plain)
    }

    func send(_ command: RemoteCommand) throws {
        guard var channel else { throw RemoteError.notReady }
        let frame = try channel.seal(RemoteCoding.encode(command))
        self.channel = channel
        transport.send(frame)
    }

    func close() {
        pump?.cancel()
        transport.close()
    }
}
