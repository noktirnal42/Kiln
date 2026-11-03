import Foundation
import KilnRemoteKit
import Network
import Observation

/// Lets paired phones and watches on the local network talk to this Kiln. Off until switched on; every frame is
/// encrypted with the pairing key (see `SecureChannel`), so a device that does not hold the key gets nothing.
@MainActor
@Observable
public final class RemoteServer {
    public private(set) var isRunning = false
    public private(set) var port: UInt16?
    public private(set) var lastError: String?
    public private(set) var deviceCount = 0
    public private(set) var pairing: PairingPayload

    @ObservationIgnored private let bridge: RemoteBridge
    @ObservationIgnored private let store: RemotePairingStore
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: RemoteConnection] = [:]
    @ObservationIgnored private let hostName: String

    public init(bridge: RemoteBridge, store: RemotePairingStore, hostName: String) {
        self.bridge = bridge
        self.store = store
        self.hostName = hostName
        let saved = store.load()
        pairing = PairingPayload(hostName: hostName, serviceName: saved.serviceName, key: saved.key)
        bridge.emit = { [weak self] event in self?.broadcast(event) }
    }

    /// `advertise: false` skips Bonjour (tests connect by port).
    public func start(advertise: Bool = true) {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
            let listener = try NWListener(using: parameters)
            if advertise { listener.service = NWListener.Service(name: pairing.serviceName, type: kilnRemoteServiceType) }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.stateChanged(state) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            bridge.start()
        } catch {
            lastError = "Could not start remote control: \(error.localizedDescription)"
        }
    }

    public func stop() {
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.close() }
        connections = [:]
        bridge.stop()
        isRunning = false; port = nil; deviceCount = 0
    }

    /// A new key and name: every paired device has to scan the code again.
    public func unpairAll() {
        let wasRunning = isRunning
        stop()
        let fresh = store.rotate()
        pairing = PairingPayload(hostName: hostName, serviceName: fresh.serviceName, key: fresh.key)
        if wasRunning { start() }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            isRunning = true
            lastError = nil
        case .failed(let error):
            lastError = "Remote control failed: \(error.localizedDescription)"
            stop()
        default: break
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        guard connections.count < 8 else { nwConnection.cancel(); return }
        let connection = RemoteConnection(connection: nwConnection, pairingKey: pairing.key, bridge: bridge)
        let id = ObjectIdentifier(connection)
        connection.onClose = { [weak self] in Task { @MainActor in self?.dropped(id) } }
        connection.onAuthenticated = { [weak self] in Task { @MainActor in self?.deviceCount = self?.connections.values.filter(\.isAuthenticated).count ?? 0 } }
        connections[id] = connection
        connection.start()
    }

    private func dropped(_ id: ObjectIdentifier) {
        connections[id] = nil
        deviceCount = connections.values.filter(\.isAuthenticated).count
    }

    private func broadcast(_ event: RemoteEvent) {
        for connection in connections.values where connection.isAuthenticated { connection.send(event) }
    }
}

/// One device. Reads on a private queue; commands are handled in order on the main actor.
final class RemoteConnection: @unchecked Sendable {
    private enum State { case awaitingNonce, secure(SecureChannel, authenticated: Bool) }

    private let connection: NWConnection
    private let pairingKey: Data
    private let bridge: RemoteBridge
    private let queue = DispatchQueue(label: "kiln.remote.connection")
    private var state = State.awaitingNonce
    private var commands: AsyncStream<RemoteCommand>.Continuation?
    var onClose: () -> Void = {}
    var onAuthenticated: () -> Void = {}

    var isAuthenticated: Bool { queue.sync { if case .secure(_, let ok) = state { ok } else { false } } }

    init(connection: NWConnection, pairingKey: Data, bridge: RemoteBridge) {
        self.connection = connection
        self.pairingKey = pairingKey
        self.bridge = bridge
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.onClose() }
        }
        connection.start(queue: queue)
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
        receive()
    }

    func close() {
        commands?.finish()
        connection.cancel()
    }

    func send(_ event: RemoteEvent) {
        queue.async { [self] in
            guard case .secure(var channel, let ok) = state, ok, let plain = try? RemoteCoding.encode(event),
                  let frame = try? channel.seal(plain) else { return }
            state = .secure(channel, authenticated: ok)
            transmit(frame)
        }
    }

    private func transmit(_ data: Data) {
        let context = NWConnection.ContentContext(identifier: "kiln-frame", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, error == nil else { self.close(); return }
            self.process(data)
            self.receive()
        }
    }

    private func process(_ data: Data) {
        switch state {
        case .awaitingNonce:
            guard data.count == 16 else { close(); return }
            let serverNonce = SecureChannel.makeNonce()
            state = .secure(SecureChannel(pairingKey: pairingKey, clientNonce: data, serverNonce: serverNonce, role: .mac), authenticated: false)
            transmit(serverNonce)
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
