import Foundation
import KilnRemoteKit
import Network

/// Where to reach a Mac: a known address (tests, a cached address) or a Bonjour service name to look up.
enum RemoteEndpoint: Equatable, Sendable {
    case hostPort(String, UInt16)
    case bonjour(serviceName: String)
}

enum LinkEvent: Sendable {
    /// The handshake finished and `hello` was sent; the Mac answers with `welcome`.
    case connected
    case event(RemoteEvent)
    /// The connection ended. `authenticated` is false when it closed before any frame from the Mac opened,
    /// which on a paired Mac means the key no longer matches.
    case closed(reason: String, sawFrames: Bool)
}

enum LinkError: Error, LocalizedError {
    case notFound, timeout, badURL
    var errorDescription: String? {
        switch self {
        case .notFound: "Could not find your Mac on this network."
        case .timeout: "The Mac did not answer in time."
        case .badURL: "The Mac's address was not valid."
        }
    }
}

/// One WebSocket connection to Kiln on a Mac: the nonce exchange, `SecureChannel` framing and `hello`.
/// All state lives on a private serial queue, so frames are opened strictly in order (the channel needs that).
final class RemoteLink: @unchecked Sendable {
    let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let queue = DispatchQueue(label: "kiln.remote.link")
    private let pairingKey: Data
    private let deviceName: String
    private let handshakeTimeout: TimeInterval
    private var connection: NWConnection?
    private var channel: SecureChannel?
    private var clientNonce = Data()
    private var finished = false
    private var sawFrames = false

    init(pairingKey: Data, deviceName: String, handshakeTimeout: TimeInterval = 10) {
        self.pairingKey = pairingKey
        self.deviceName = deviceName
        self.handshakeTimeout = handshakeTimeout
        (events, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
    }

    func connect(host: String, port: UInt16) throws {
        var hostText = host
        if hostText.contains(":"), !hostText.hasPrefix("[") { hostText = "[\(hostText.replacingOccurrences(of: "%", with: "%25"))]" }
        guard let url = URL(string: "ws://\(hostText):\(port)") else { throw LinkError.badURL }
        try connect(url: url, headers: [])
    }

    /// Any ws:// or wss:// URL; `headers` is for the relay's `Authorization`.
    func connect(url: URL, headers: [(String, String)]) throws {
        guard let scheme = url.scheme, scheme == "ws" || scheme == "wss" else { throw LinkError.badURL }
        let parameters = scheme == "wss" ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()) : NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        if !headers.isEmpty { websocket.setAdditionalHeaders(headers) }
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        queue.async { [self] in
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
            connection.start(queue: queue)
            // Handshake, then the first frame, has to finish promptly or the Mac drops us anyway.
            queue.asyncAfter(deadline: .now() + handshakeTimeout) { [weak self] in
                guard let self, !finished, !(channel != nil && sawFrames) else { return }
                finish("The Mac did not answer in time.")
            }
        }
    }

    func send(_ command: RemoteCommand) {
        queue.async { [self] in
            guard !finished, var channel, let plain = try? RemoteCoding.encode(command), let frame = try? channel.seal(plain) else { return }
            self.channel = channel
            transmit(frame)
        }
    }

    func close() { queue.async { [self] in finish("Disconnected.") } }

    // MARK: private (queue-confined)

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            clientNonce = SecureChannel.makeNonce()
            transmit(clientNonce)
            receive()
        case .failed(let error): finish(error.localizedDescription)
        case .waiting(let error): finish(error.localizedDescription)
        case .cancelled: finish("Disconnected.")
        default: break
        }
    }

    private func transmit(_ data: Data) {
        let context = NWConnection.ContentContext(identifier: "kiln-frame", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        connection?.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            queue.async {
                guard !self.finished else { return }
                guard let data, error == nil else { self.finish(error?.localizedDescription ?? "The Mac closed the connection."); return }
                self.process(data)
                if !self.finished { self.receive() }
            }
        }
    }

    private func process(_ data: Data) {
        guard var channel = self.channel else {
            guard data.count == 16 else { finish("Unexpected handshake from the Mac."); return }
            var fresh = SecureChannel(pairingKey: pairingKey, clientNonce: clientNonce, serverNonce: data, role: .device)
            guard let plain = try? RemoteCoding.encode(RemoteCommand.hello(deviceName: deviceName, protocolVersion: kilnRemoteProtocolVersion)),
                  let frame = try? fresh.seal(plain) else { finish("Could not start the session."); return }
            self.channel = fresh
            transmit(frame)
            continuation.yield(.connected)
            return
        }
        guard let plain = try? channel.open(data), let event = try? RemoteCoding.decode(RemoteEvent.self, from: plain) else {
            finish("A message from the Mac could not be verified.")
            return
        }
        self.channel = channel
        sawFrames = true
        continuation.yield(.event(event))
    }

    private func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        connection?.cancel()
        connection = nil
        continuation.yield(.closed(reason: reason, sawFrames: sawFrames))
        continuation.finish()
    }
}

/// Finds the Mac's address from its Bonjour service name.
enum BonjourResolver {
    static func resolve(serviceName: String, timeout: Duration = .seconds(10)) async throws -> (String, UInt16) {
        let browser = NWBrowser(for: .bonjour(type: kilnRemoteServiceType, domain: nil), using: .tcp)
        let found = AsyncStream<NWEndpoint> { continuation in
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint, name == serviceName { continuation.yield(result.endpoint) }
                }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: .global(qos: .userInitiated))
        }
        return try await withThrowingTaskGroup(of: (String, UInt16).self) { group in
            group.addTask {
                for await endpoint in found {
                    if let address = try? await address(of: endpoint) { return address }
                }
                throw LinkError.notFound
            }
            group.addTask { try await Task.sleep(for: timeout); throw LinkError.notFound }
            defer { group.cancelAll(); browser.cancel() }
            return try await group.next()!
        }
    }

    /// Opens a plain TCP connection to the service just to read which address it resolved to (IPv4 preferred;
    /// the WebSocket client needs a URL, so a Bonjour endpoint cannot be used directly).
    private static func address(of endpoint: NWEndpoint) async throws -> (String, UInt16) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint, once.take() {
                        var text = "\(host)"
                        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                        connection.cancel()
                        continuation.resume(returning: (text, port.rawValue))
                    } else if once.take() { connection.cancel(); continuation.resume(throwing: LinkError.notFound) }
                case .failed, .waiting:
                    if once.take() { connection.cancel(); continuation.resume(throwing: LinkError.notFound) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock(); private var taken = false
    func take() -> Bool { lock.withLock { if taken { return false }; taken = true; return true } }
}
