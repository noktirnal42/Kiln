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
    /// The relay that lets devices reach this Mac over the internet (nil: local network only).
    public private(set) var relayURL: URL?
    public private(set) var relayConnected = false
    public private(set) var relayError: String?

    @ObservationIgnored private let bridge: RemoteBridge
    @ObservationIgnored private let store: RemotePairingStore
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: RemoteConnection] = [:]
    @ObservationIgnored private let hostName: String
    @ObservationIgnored private var relayClient: RemoteRelayClient?
    /// Keeps the Mac awake while remote control is on, so a phone away from home can still reach it.
    @ObservationIgnored private var awakeActivity: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults
    static let relayDefaultsKey = "remote.relayURL"
    /// Tried first on every launch.
    public static let preferredPort: UInt16 = 47900

    /// Addresses a device can type in to connect directly (same network, or over a VPN such as Tailscale).
    public var directAddresses: [String] {
        guard let port else { return [] }
        return NetworkAddresses.current().map { "\($0.address):\(port)" + ($0.isTailscale ? " (Tailscale)" : "") }
    }

    public init(bridge: RemoteBridge, store: RemotePairingStore, hostName: String, defaults: UserDefaults = .standard) {
        self.bridge = bridge
        self.store = store
        self.hostName = hostName
        self.defaults = defaults
        let saved = store.load()
        let relay = defaults.string(forKey: Self.relayDefaultsKey).flatMap(URL.init(string:))
        relayURL = relay
        pairing = PairingPayload(hostName: hostName, serviceName: saved.serviceName, key: saved.key, relay: relay)
        bridge.emit = { [weak self] event in self?.broadcast(event) }
    }

    @ObservationIgnored private var advertising = true
    @ObservationIgnored private var triedPreferredPort = false

    /// `advertise: false` skips Bonjour (tests connect by port).
    public func start(advertise: Bool = true) {
        guard listener == nil else { return }
        advertising = advertise
        launchListener(preferFixedPort: true)
        guard listener != nil else { return }
        bridge.start()
        awakeActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Kiln remote control")
        startRelayClient()
    }

    private func launchListener(preferFixedPort: Bool) {
        let advertise = advertising
        triedPreferredPort = preferFixedPort
        do {
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
            // A fixed port makes "address:port" usable from a phone over a VPN (Bonjour does not cross one); fall back to
            // any free port if something else has it.
            let listener: NWListener
            if preferFixedPort, let preferred = NWEndpoint.Port(rawValue: Self.preferredPort), let fixed = try? NWListener(using: parameters, on: preferred) {
                listener = fixed
            } else {
                listener = try NWListener(using: parameters)
            }
            if advertise { listener.service = NWListener.Service(name: pairing.serviceName, type: kilnRemoteServiceType) }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.stateChanged(state) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            lastError = "Could not start remote control: \(error.localizedDescription)"
        }
    }

    public func stop() {
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.close() }
        connections = [:]
        bridge.stop()
        relayClient?.stop(); relayClient = nil; relayConnected = false
        if let awakeActivity { ProcessInfo.processInfo.endActivity(awakeActivity) }
        awakeActivity = nil
        isRunning = false; port = nil; deviceCount = 0
    }

    /// Puts the Mac's current addresses in the pairing code so devices can connect without Bonjour.
    public func refreshDirectAddresses() {
        guard let port else { return }
        pairing.direct = NetworkAddresses.current().map { "\($0.address):\(port)" }
    }

    /// Sets (or clears) the relay address shown in the pairing code. Devices paired earlier without it must scan again.
    public func setRelay(_ url: URL?) {
        let accepted = url.flatMap { $0.scheme == "wss" || $0.scheme == "ws" ? $0 : nil }
        relayURL = accepted
        defaults.set(accepted?.absoluteString, forKey: Self.relayDefaultsKey)
        pairing.relay = accepted
        relayClient?.stop(); relayClient = nil; relayConnected = false
        if isRunning { startRelayClient() }
    }

    private func startRelayClient() {
        guard let relayURL else { return }
        let client = RemoteRelayClient(relay: relayURL, pairingKey: pairing.key, bridge: bridge)
        client.onChange = { [weak self, weak client] in
            guard let self, let client else { return }
            self.relayConnected = client.isConnected
            self.relayError = client.lastError
            self.deviceCount = self.connections.values.filter(\.isAuthenticated).count
        }
        client.onDevice = { [weak self] connection in self?.register(connection) }
        relayClient = client
        client.start()
    }

    /// A new key and name: every paired device has to scan the code again.
    public func unpairAll() {
        let wasRunning = isRunning
        stop()
        let fresh = store.rotate()
        pairing = PairingPayload(hostName: hostName, serviceName: fresh.serviceName, key: fresh.key, relay: relayURL, direct: pairing.direct)
        if wasRunning { start() }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            isRunning = true
            lastError = nil
            refreshDirectAddresses()
        case .failed(let error):
            // The fixed port can be taken (another Kiln, a lingering socket): carry on with any free port.
            if triedPreferredPort {
                listener?.cancel(); listener = nil
                launchListener(preferFixedPort: false)
                return
            }
            lastError = "Remote control failed: \(error.localizedDescription)"
            stop()
        default: break
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        guard connections.count < 8 else { nwConnection.cancel(); return }
        let transport = NetworkTransport(connection: nwConnection)
        let connection = RemoteConnection(transport: transport, pairingKey: pairing.key, bridge: bridge)
        transport.owner = connection
        register(connection)
        transport.start(queue: DispatchQueue(label: "kiln.remote.socket"))
    }

    fileprivate func register(_ connection: RemoteConnection) {
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

/// A device on the local network: one WebSocket.
final class NetworkTransport: FrameTransport, @unchecked Sendable {
    private let connection: NWConnection
    weak var owner: RemoteConnection?

    init(connection: NWConnection) { self.connection = connection }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.connection.cancel() }
            if case .cancelled = state { self?.owner?.transportClosed() }
        }
        connection.start(queue: queue)
        receive()
    }

    func send(_ data: Data) {
        let context = NWConnection.ContentContext(identifier: "kiln-frame", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close() { connection.cancel() }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, error == nil else { self.connection.cancel(); return }
            self.owner?.receive(data)
            self.receive()
        }
    }
}
