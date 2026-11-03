import Foundation
import KilnRemoteKit
import Network
import Testing
@testable import Kiln

@MainActor
final class FakeBackend: RemoteBackend {
    var hostName = "Test Mac"
    var list = [RemoteConversation(id: "c1", title: "First", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))]
    var current: RemoteConversation?
    var messages: [RemoteMessage] = []
    var isStreaming = false
    var streamingText = ""
    var pendingApprovals: [RemoteApproval] = []
    var sent: [String] = []
    var decisions: [(String, RemoteApprovalDecision)] = []
    var stopped = 0

    func conversations() async -> [RemoteConversation] { list }
    func open(_ id: String?) async -> RemoteConversation? {
        current = id.flatMap { id in list.first { $0.id == id } } ?? RemoteConversation(id: "new", title: "New Conversation", updatedAt: Date())
        messages = []
        return current
    }
    func send(_ text: String) { sent.append(text) }
    func stop() { stopped += 1 }
    func decide(_ approvalID: String, _ decision: RemoteApprovalDecision) {
        decisions.append((approvalID, decision))
        pendingApprovals.removeAll { $0.id == approvalID }
    }
}

@MainActor
@Suite("Remote bridge")
struct RemoteBridgeTests {
    @Test("hello answers with the host, conversations and the open conversation") func hello() async {
        let backend = FakeBackend()
        _ = await backend.open("c1")
        let events = await RemoteBridge(backend: backend).handle(.hello(deviceName: "Phone", protocolVersion: kilnRemoteProtocolVersion))
        #expect(events.first == .welcome(hostName: "Test Mac", protocolVersion: kilnRemoteProtocolVersion))
        #expect(events.contains(.conversations(backend.list)))
        #expect(events.contains { if case .opened = $0 { true } else { false } })
    }

    @Test("a client speaking another protocol version is told so") func version() async {
        let events = await RemoteBridge(backend: FakeBackend()).handle(.hello(deviceName: "Old", protocolVersion: 99))
        #expect(events.count == 1)
        if case .error(let text) = events[0] { #expect(text.contains("update")) } else { Issue.record("expected an error") }
    }

    @Test("sending text reaches the chat, but not while a reply is streaming") func send() async {
        let backend = FakeBackend()
        let bridge = RemoteBridge(backend: backend)
        _ = await bridge.handle(.send(text: "  run the tests  ", spoken: true))
        #expect(backend.sent == ["run the tests"])
        backend.isStreaming = true
        let events = await bridge.handle(.send(text: "again", spoken: false))
        #expect(backend.sent == ["run the tests"])
        #expect(events.count == 1)
    }

    @Test("streamed text is pushed as deltas, then the saved message") func streaming() async {
        let backend = FakeBackend()
        _ = await backend.open("c1")
        let bridge = RemoteBridge(backend: backend)
        _ = await bridge.handle(.openConversation(id: "c1"))
        backend.isStreaming = true
        backend.streamingText = "Hel"
        #expect(bridge.poll() == [.streaming(true), .delta(text: "Hel")])
        backend.streamingText = "Hello there"
        #expect(bridge.poll() == [.delta(text: "lo there")])
        backend.isStreaming = false
        backend.messages = [RemoteMessage(id: "m1", role: .assistant, text: "Hello there", createdAt: Date(timeIntervalSince1970: 1))]
        let done = bridge.poll()
        #expect(done.contains(.streaming(false)))
        #expect(done.contains(.message(backend.messages[0])))
        #expect(bridge.poll().isEmpty)
    }

    @Test("approvals are announced once, resolved on decision, and only allow-once or deny exist") func approvals() async {
        let backend = FakeBackend()
        let bridge = RemoteBridge(backend: backend)
        _ = await bridge.handle(.openConversation(id: "c1"))
        let request = RemoteApproval(id: "a1", tool: "run_command", permission: "execute", preview: "swift test")
        backend.pendingApprovals = [request]
        #expect(bridge.poll() == [.approvalRequested(request)])
        #expect(bridge.poll().isEmpty)
        let events = await bridge.handle(.decide(approvalID: "a1", decision: .allowOnce))
        #expect(events == [.approvalResolved(approvalID: "a1")])
        #expect(backend.decisions.first?.1 == .allowOnce)
        // Resolved at the Mac instead: the remote is told to drop it.
        backend.pendingApprovals = [RemoteApproval(id: "a2", tool: "x", permission: "write", preview: "")]
        _ = bridge.poll()
        backend.pendingApprovals = []
        #expect(bridge.poll() == [.approvalResolved(approvalID: "a2")])
    }
}

/// A device on the other end of a real local socket, speaking the documented handshake.
@MainActor
final class LoopbackDevice {
    private let connection: NWConnection
    private var channel: SecureChannel?
    private let key: Data
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, Never>?
    private let clientNonce = SecureChannel.makeNonce()

    init(port: UInt16, key: Data) {
        self.key = key
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        connection = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)")!), using: parameters)
    }

    func connect() async {
        connection.start(queue: .global())
        pump()
        send(raw: clientNonce)
        let serverNonce = await next()
        channel = SecureChannel(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce, role: .device)
    }

    func send(_ command: RemoteCommand) {
        guard var channel, let frame = try? channel.seal(RemoteCoding.encode(command)) else { return }
        self.channel = channel
        send(raw: frame)
    }

    func nextEvent() async -> RemoteEvent? {
        let frame = await next()
        guard var channel, let plain = try? channel.open(frame) else { return nil }
        self.channel = channel
        return try? RemoteCoding.decode(RemoteEvent.self, from: plain)
    }

    func close() { connection.cancel() }

    private func send(raw: Data) {
        let context = NWConnection.ContentContext(identifier: "t", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        connection.send(content: raw, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func pump() {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.deliver(data) }
                if error == nil, data != nil { self.pump() }
            }
        }
    }

    private func deliver(_ data: Data) {
        if let waiter { self.waiter = nil; waiter.resume(returning: data) } else { inbox.append(data) }
    }

    private func next() async -> Data {
        if !inbox.isEmpty { return inbox.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor
@Suite("Remote server over a real socket", .serialized, .timeLimit(.minutes(1)))
struct RemoteServerTests {
    private func makeServer(_ backend: FakeBackend) throws -> RemoteServer {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-remote-\(UUID().uuidString)")
        let server = RemoteServer(bridge: RemoteBridge(backend: backend), store: RemotePairingStore(directory: dir), hostName: "Test Mac")
        server.start(advertise: false)
        return server
    }

    private func waitForPort(_ server: RemoteServer) async throws -> UInt16 {
        for _ in 0..<100 { if let port = server.port { return port }; try await Task.sleep(for: .milliseconds(50)) }
        throw CancellationError()
    }

    @Test("a paired device completes the handshake and receives the welcome and conversations") func pairedDevice() async throws {
        let backend = FakeBackend()
        _ = await backend.open("c1")
        let server = try makeServer(backend)
        defer { server.stop() }
        let device = LoopbackDevice(port: try await waitForPort(server), key: server.pairing.key)
        await device.connect()
        device.send(.hello(deviceName: "Phone", protocolVersion: kilnRemoteProtocolVersion))
        #expect(await device.nextEvent() == .welcome(hostName: "Test Mac", protocolVersion: kilnRemoteProtocolVersion))
        #expect(await device.nextEvent() == .conversations(backend.list))
        device.send(.send(text: "hello from the watch", spoken: true))
        device.send(.ping)
        // The ping answer arrives after the opened event; wait for it to know the send was processed.
        var sawPong = false
        for _ in 0..<5 { if await device.nextEvent() == .pong { sawPong = true; break } }
        #expect(sawPong)
        #expect(backend.sent == ["hello from the watch"])
        device.close()
    }

    @Test("a device with the wrong key is dropped and never reaches the chat") func wrongKey() async throws {
        let backend = FakeBackend()
        let server = try makeServer(backend)
        defer { server.stop() }
        let device = LoopbackDevice(port: try await waitForPort(server), key: PairingPayload.makeKey())
        await device.connect()
        device.send(.send(text: "let me in", spoken: false))
        try await Task.sleep(for: .milliseconds(500))
        #expect(backend.sent.isEmpty)
        #expect(server.deviceCount == 0)
        device.close()
    }
}
