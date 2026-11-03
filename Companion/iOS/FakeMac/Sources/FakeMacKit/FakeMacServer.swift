import Foundation
import KilnRemoteKit
import Network

/// A scripted Kiln-on-the-Mac: same handshake, framing and message flow as `Core/Remote/RemoteServer`, with canned
/// conversations. Typing "approve" (or anything containing it) makes it ask for an approval before answering.
public final class FakeMacServer: @unchecked Sendable {
    public let hostName: String
    public let serviceName: String
    public let key: Data
    public private(set) var port: UInt16 = 0
    /// Commands received from authenticated devices, in order (for assertions).
    public var receivedCommands: [RemoteCommand] { lock.withLock { received } }
    public var connectionCount: Int { lock.withLock { connections.count } }

    private let lock = NSLock()
    private var received: [RemoteCommand] = []
    private var connections: [ObjectIdentifier: Session] = [:]
    private var listener: NWListener?
    private let advertise: Bool
    fileprivate let respondToPing: Bool
    private let queue = DispatchQueue(label: "fakemac.listener")

    public init(hostName: String = "Fake Mac", serviceName: String = "Kiln on Fake Mac", key: Data = PairingPayload.makeKey(), advertise: Bool = false, respondToPing: Bool = true) {
        self.hostName = hostName; self.serviceName = serviceName; self.key = key; self.advertise = advertise; self.respondToPing = respondToPing
    }

    public var pairing: PairingPayload { PairingPayload(hostName: hostName, serviceName: serviceName, key: key) }

    public func start() async throws {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        let listener = try NWListener(using: parameters)
        if advertise { listener.service = NWListener.Service(name: serviceName, type: kilnRemoteServiceType) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { continuation.resume() }
                case .failed(let error): if once.take() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    // MARK: relay (the Mac side of Relay/: one outbound socket carrying many devices)

    private var relayTask: URLSessionWebSocketTask?
    private var relayDevices: [UInt32: Session] = [:]
    private var relayOutbound: AsyncStream<Data>.Continuation?
    private let relaySession = URLSession(configuration: .ephemeral)

    /// Connects out to a Kiln relay as the Mac, like `Core/Remote/RemoteRelayClient`.
    public func connectToRelay(_ relay: URL) async throws {
        guard let url = RelayAddress.url(relay: relay, pairingKey: key, role: .mac) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(RelayAddress.authorizationHeader(pairingKey: key), forHTTPHeaderField: "Authorization")
        let task = relaySession.webSocketTask(with: request)
        relayTask = task
        task.resume()
        // One ordered writer: sealed frames carry a counter, so they must reach the relay in order.
        let (frames, continuation) = AsyncStream.makeStream(of: Data.self)
        relayOutbound = continuation
        Task { for await frame in frames { try? await task.send(.data(frame)) } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
        }
        Task { [weak self] in
            while let self, let task = self.relayTask {
                guard let message = try? await task.receive(), case .data(let frame) = message else { break }
                self.handleRelay(frame)
            }
        }
    }

    private func handleRelay(_ frame: Data) {
        guard let (kind, id, payload) = RelayFrame.decode(frame), let outbound = relayOutbound else { return }
        switch kind {
        case .deviceJoined:
            let session = Session(server: self, send: { data in
                outbound.yield(RelayFrame.encode(.data, device: id, payload: data))
            }, close: {
                outbound.yield(RelayFrame.encode(.closeDevice, device: id))
            })
            lock.withLock { relayDevices[id] = session; connections[ObjectIdentifier(session)] = session }
        case .deviceLeft:
            lock.withLock { relayDevices.removeValue(forKey: id) }
        case .data:
            lock.withLock { relayDevices[id] }?.deliver(payload)
        case .closeDevice: break
        }
    }

    public func stop() {
        relayTask?.cancel(with: .goingAway, reason: nil); relayTask = nil
        listener?.cancel(); listener = nil
        let all = lock.withLock { Array(connections.values) }
        for session in all { session.close() }
    }

    /// Drops every connection without stopping the listener (tests use it to exercise reconnecting).
    public func dropConnections() {
        let all = lock.withLock { Array(connections.values) }
        for session in all { session.close() }
    }

    /// Pushes an event to every authenticated device.
    public func push(_ event: RemoteEvent) {
        let all = lock.withLock { Array(connections.values) }
        for session in all { session.send(event) }
    }

    private func accept(_ connection: NWConnection) {
        let session = Session(connection: connection, server: self)
        let id = ObjectIdentifier(session)
        lock.withLock { connections[id] = session }
        session.onClose = { [weak self] in self?.lock.withLock { _ = self?.connections.removeValue(forKey: id) } }
        session.start()
    }

    fileprivate func record(_ command: RemoteCommand) { lock.withLock { received.append(command) } }

    // MARK: canned content

    fileprivate static let conversations: [RemoteConversation] = [
        RemoteConversation(id: "c1", title: "Fix the flaky login test", updatedAt: Date(timeIntervalSinceNow: -300)),
        RemoteConversation(id: "c2", title: "Refactor the settings store", updatedAt: Date(timeIntervalSinceNow: -7200)),
        RemoteConversation(id: "c3", title: "Explain the build script", updatedAt: Date(timeIntervalSinceNow: -86400)),
    ]

    fileprivate func messages(for id: String) -> [RemoteMessage] {
        [RemoteMessage(id: "\(id)-1", role: .user, text: "Why is the login test flaky?", createdAt: Date(timeIntervalSinceNow: -320)),
         RemoteMessage(id: "\(id)-2", role: .assistant, text: "It races the keychain write. I'd wait for the **save** to finish before asserting; see `LoginTests.swift`.\n\n- add an await\n- drop the sleep", createdAt: Date(timeIntervalSinceNow: -310))]
    }

    final class Session: @unchecked Sendable {
        private let connection: NWConnection?
        private unowned let server: FakeMacServer
        private let queue = DispatchQueue(label: "fakemac.session")
        /// Set for sessions carried by a relay socket instead of an NWConnection.
        private var relaySend: (@Sendable (Data) -> Void)?
        private var relayClose: (@Sendable () -> Void)?
        private var channel: SecureChannel?
        private var authenticated = false
        private var openID = "c1"
        private var counter = 0
        var onClose: () -> Void = {}

        init(connection: NWConnection, server: FakeMacServer) { self.connection = connection; self.server = server }

        /// A device that reached this Mac through the relay.
        init(server: FakeMacServer, send: @escaping @Sendable (Data) -> Void, close: @escaping @Sendable () -> Void) {
            connection = nil; self.server = server; relaySend = send; relayClose = close
        }

        /// Called by the relay client for each frame from this device.
        func deliver(_ data: Data) { queue.async { [self] in process(data) } }

        func start() {
            guard let connection else { return }
            connection.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.onClose() }
                if case .failed = state { self?.close() }
            }
            connection.start(queue: queue)
            receive()
        }

        func close() { if let connection { connection.cancel() } else { relayClose?(); onClose() } }

        func send(_ event: RemoteEvent) {
            queue.async { [self] in
                guard authenticated, var channel, let plain = try? RemoteCoding.encode(event), let frame = try? channel.seal(plain) else { return }
                self.channel = channel
                transmit(frame)
            }
        }

        private func transmit(_ data: Data) {
            if let relaySend { relaySend(data); return }
            guard let connection else { return }
            let context = NWConnection.ContentContext(identifier: "frame", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }

        private func receive() {
            guard let connection else { return }
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                guard let data, error == nil else { self.close(); return }
                self.process(data)
                self.receive()
            }
        }

        private func process(_ data: Data) {
            guard var channel = self.channel else {
                guard data.count == 16 else { close(); return }
                let serverNonce = SecureChannel.makeNonce()
                self.channel = SecureChannel(pairingKey: server.key, clientNonce: data, serverNonce: serverNonce, role: .mac)
                transmit(serverNonce)
                return
            }
            guard let plain = try? channel.open(data), let command = try? RemoteCoding.decode(RemoteCommand.self, from: plain) else { close(); return }
            self.channel = channel
            if !authenticated {
                guard case .hello(_, let version) = command else { close(); return }
                authenticated = true
                server.record(command)
                guard version == kilnRemoteProtocolVersion else { send(.error("protocol mismatch")); return }
                send(.welcome(hostName: server.hostName, protocolVersion: kilnRemoteProtocolVersion))
                send(.conversations(FakeMacServer.conversations))
                send(openedEvent())
                return
            }
            server.record(command)
            handle(command)
        }

        private func openedEvent() -> RemoteEvent {
            let conversation = FakeMacServer.conversations.first { $0.id == openID } ?? FakeMacServer.conversations[0]
            return .opened(conversation: conversation, messages: server.messages(for: openID), isStreaming: false)
        }

        private func handle(_ command: RemoteCommand) {
            switch command {
            case .listConversations: send(.conversations(FakeMacServer.conversations))
            case .openConversation(let id): openID = id; send(openedEvent())
            case .newConversation:
                openID = "c1"
                send(.opened(conversation: RemoteConversation(id: "new", title: "New conversation", updatedAt: Date()), messages: [], isStreaming: false))
            case .send(let text, _):
                counter += 1
                let n = counter
                send(.message(RemoteMessage(id: "u\(n)", role: .user, text: text, createdAt: Date())))
                send(.streaming(true))
                if text.lowercased().contains("approve") {
                    send(.approvalRequested(RemoteApproval(id: "a\(n)", tool: "shell", permission: "execute", preview: "swift test --filter LoginTests")))
                } else {
                    reply(to: text, n: n)
                }
            case .registerPush: break
            case .sendAudio:
                counter += 1
                let n = counter
                send(.transcript("run the tests"))
                send(.message(RemoteMessage(id: "u\(n)", role: .user, text: "run the tests", createdAt: Date())))
                send(.streaming(true))
                reply(to: "run the tests", n: n)
            case .decide(let id, let decision):
                send(.approvalResolved(approvalID: id))
                send(.activity(tool: "shell", status: decision == .allowOnce ? "running" : "denied"))
                reply(to: decision == .allowOnce ? "approved" : "denied", n: counter)
            case .stop: send(.streaming(false))
            case .ping: if server.respondToPing { send(.pong) }
            case .hello: break
            }
        }

        private func reply(to text: String, n: Int) {
            let pieces = ["You said ", "\"\(text)\". ", "Here is **a short answer** ", "with `code` in it."]
            for (index, piece) in pieces.enumerated() {
                queue.asyncAfter(deadline: .now() + .milliseconds(30 * (index + 1))) { [self] in send(.delta(text: piece)) }
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(30 * (pieces.count + 2))) { [self] in
                send(.message(RemoteMessage(id: "r\(n)", role: .assistant, text: pieces.joined(), createdAt: Date())))
                send(.streaming(false))
            }
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var taken = false
    func take() -> Bool { lock.withLock { if taken { return false }; taken = true; return true } }
}
