import Foundation
import KilnRemoteKit

/// Carries sealed frames for one device: a local-network WebSocket, or a slice of the relay's single socket.
protocol FrameTransport: AnyObject, Sendable {
    func send(_ data: Data)
    func close()
}

/// One device. The handshake, key check and command handling are the same whatever carries the bytes. Commands are
/// handled in order on the main actor; state lives on a private queue.
final class RemoteConnection: @unchecked Sendable {
    private enum State { case awaitingNonce, secure(SecureChannel, authenticated: Bool) }

    private let transport: any FrameTransport
    private let pairingKey: Data
    private let bridge: RemoteBridge
    private let queue = DispatchQueue(label: "kiln.remote.connection")
    private var state = State.awaitingNonce
    private var commands: AsyncStream<RemoteCommand>.Continuation?
    private var finished = false
    var onClose: () -> Void = {}
    var onAuthenticated: () -> Void = {}

    var isAuthenticated: Bool { queue.sync { if case .secure(_, true) = state { true } else { false } } }

    init(transport: any FrameTransport, pairingKey: Data, bridge: RemoteBridge) {
        self.transport = transport
        self.pairingKey = pairingKey
        self.bridge = bridge
    }

    func start() {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteCommand.self)
        commands = continuation
        Task { [bridge, weak self] in
            for await command in stream {
                let events = await bridge.handle(command)
                for event in events { self?.send(event) }
            }
        }
        // A device that does not finish the handshake in time is dropped.
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            if case .secure(_, true) = self.state { return }
            self.close()
        }
    }

    /// The transport hands over every frame it receives.
    func receive(_ data: Data) { queue.async { self.process(data) } }

    /// The transport is gone.
    func transportClosed() {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            self.commands?.finish()
            self.onClose()
        }
    }

    func close() {
        commands?.finish()
        transport.close()
    }

    func send(_ event: RemoteEvent) {
        queue.async { [self] in
            guard case .secure(var channel, let ok) = state, ok, let plain = try? RemoteCoding.encode(event),
                  let frame = try? channel.seal(plain) else { return }
            state = .secure(channel, authenticated: ok)
            transport.send(frame)
        }
    }

    private func process(_ data: Data) {
        switch state {
        case .awaitingNonce:
            guard data.count == 16 else { close(); return }
            let serverNonce = SecureChannel.makeNonce()
            state = .secure(SecureChannel(pairingKey: pairingKey, clientNonce: data, serverNonce: serverNonce, role: .mac), authenticated: false)
            transport.send(serverNonce)
        case .secure(var channel, let authenticated):
            guard let plain = try? channel.open(data), let command = try? RemoteCoding.decode(RemoteCommand.self, from: plain) else {
                close()   // wrong key, tampering, replay or garbage
                return
            }
            if !authenticated {
                guard case .hello = command else { close(); return }
                state = .secure(channel, authenticated: true)
                onAuthenticated()
            } else {
                state = .secure(channel, authenticated: true)
            }
            commands?.yield(command)
        }
    }
}
