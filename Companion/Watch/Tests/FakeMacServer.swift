import Foundation
import KilnRemoteKit
import Network

/// A small in-process stand-in for Kiln's Core/Remote server: a real WebSocket listener on loopback speaking the
/// documented handshake and SecureChannel framing, so the watch's client is exercised over an actual socket.
final class FakeMacServer: @unchecked Sendable {
    private let key: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake.mac")
    private let lock = NSLock()
    private var connections: [FakeConnection] = []
    private var _received: [RemoteCommand] = []
    private var _closedCount = 0

    var reply: @Sendable (String) -> String = { "Done: \($0)" }

    var received: [RemoteCommand] { lock.withLock { _received } }
    var closedCount: Int { lock.withLock { _closedCount } }
    private(set) var port: UInt16 = 0

    init(key: Data) throws {
        self.key = key
        let websocket = NWProtocolWebSocket.Options()
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws {
        let (states, continuation) = AsyncStream.makeStream(of: NWListener.State.self)
        listener.stateUpdateHandler = { continuation.yield($0) }
        listener.newConnectionHandler = { [self] connection in
            let fake = FakeConnection(connection: connection, key: key, server: self)
            lock.withLock { connections.append(fake) }
            fake.start(queue: queue)
        }
        listener.start(queue: queue)
        for await state in states {
            if case .ready = state { port = listener.port?.rawValue ?? 0; return }
            if case .failed(let error) = state { throw error }
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() } }
    }

    var url: URL { URL(string: "ws://127.0.0.1:\(port)")! }

    func push(_ event: RemoteEvent) { lock.withLock { connections }.forEach { $0.send(event) } }

    fileprivate func record(_ command: RemoteCommand) { lock.withLock { _received.append(command) } }
    fileprivate func noteClosed() { lock.withLock { _closedCount += 1 } }
}

final class FakeConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let key: Data
    private unowned let server: FakeMacServer
    private var channel: SecureChannel?
    private var authenticated = false
    private let sendQueue = DispatchQueue(label: "fake.mac.send")

    init(connection: NWConnection, key: Data, server: FakeMacServer) {
        self.connection = connection
        self.key = key
        self.server = server
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.server.noteClosed() }
            if case .failed = state { self?.server.noteClosed() }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() { connection.cancel() }

    private func transmit(_ data: Data) {
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func send(_ event: RemoteEvent) {
        sendQueue.sync {
            guard authenticated, var current = channel, let plain = try? RemoteCoding.encode(event), let frame = try? current.seal(plain) else { return }
            channel = current
            transmit(frame)
        }
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, error == nil else { self.connection.cancel(); return }
            self.process(data)
            self.receive()
        }
    }

    private func process(_ data: Data) {
        guard var current = channel else {
            guard data.count == 16 else { connection.cancel(); return }
            let serverNonce = SecureChannel.makeNonce()
            channel = SecureChannel(pairingKey: key, clientNonce: data, serverNonce: serverNonce, role: .mac)
            transmit(serverNonce)
            return
        }
        guard let plain = try? current.open(data), let command = try? RemoteCoding.decode(RemoteCommand.self, from: plain) else {
            connection.cancel()   // wrong key, tampering, replay
            return
        }
        channel = current
        server.record(command)
        let now = Date()
        let conversation = RemoteConversation(id: "c1", title: "Kiln", updatedAt: now)
        switch command {
        case .hello:
            authenticated = true
            send(.welcome(hostName: "Fake Mac", protocolVersion: kilnRemoteProtocolVersion))
        case .listConversations:
            send(.conversations([conversation]))
        case .openConversation, .newConversation:
            send(.opened(conversation: conversation, messages: [], isStreaming: false))
        case .send(let text, _):
            send(.message(RemoteMessage(id: "u", role: .user, text: text, createdAt: now)))
            send(.streaming(true))
            send(.delta(text: "Working"))
            send(.message(RemoteMessage(id: "a", role: .assistant, text: server.reply(text), createdAt: now)))
            send(.streaming(false))
        case .decide(let id, _):
            send(.approvalResolved(approvalID: id))
        case .stop, .ping:
            send(.pong)
        }
    }
}
