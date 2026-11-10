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
    var heard: String? = "run the tests"
    func transcribe(audio: Data, format: String) async -> String? { heard }
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

    @Test("a recording is transcribed on the Mac, reported back, and sent as a message") func audio() async {
        let backend = FakeBackend()
        let bridge = RemoteBridge(backend: backend)
        let events = await bridge.handle(.sendAudio(data: Data([1, 2, 3]), format: "m4a"))
        #expect(events == [.transcript("run the tests")])
        #expect(backend.sent == ["run the tests"])
        backend.heard = nil
        let failed = await bridge.handle(.sendAudio(data: Data([1]), format: "m4a"))
        if case .error(let text)? = failed.first { #expect(text.contains("didn't catch")) } else { Issue.record("expected an error") }
        #expect(backend.sent.count == 1)
        backend.isStreaming = true
        backend.heard = "again"
        #expect(await bridge.handle(.sendAudio(data: Data([1]), format: "m4a")).count == 1)
        #expect(backend.sent.count == 1)
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

    convenience init(port: UInt16, key: Data) { self.init(url: URL(string: "ws://127.0.0.1:\(port)")!, key: key, headers: []) }

    init(url: URL, key: Data, headers: [(String, String)]) {
        self.key = key
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        if !headers.isEmpty { options.setAdditionalHeaders(headers) }
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
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

    /// Empty data when nothing arrives in time, so a broken path fails the test instead of hanging it.
    private func next() async -> Data {
        if !inbox.isEmpty { return inbox.removeFirst() }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if let waiter = self?.waiter { self?.waiter = nil; waiter.resume(returning: Data()) }
        }
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

    @Test("a second server falls back to another port when the fixed one is taken") func portFallback() async throws {
        let first = try makeServer(FakeBackend())
        let second = try makeServer(FakeBackend())
        defer { first.stop(); second.stop() }
        let a = try await waitForPort(first), b = try await waitForPort(second)
        #expect(a != b)
        #expect([a, b].contains(RemoteServer.preferredPort) || a != RemoteServer.preferredPort)
        #expect(second.lastError == nil)
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

/// The same Mac server, reached through a real relay process: this is the path a phone on mobile data takes.
@MainActor
@Suite("Remote control through the relay", .serialized, .timeLimit(.minutes(2)))
struct RemoteRelayTests {
    /// Xcode's test environment does not inherit the shell's PATH, so look where Node usually lives.
    nonisolated static var nodeAvailable: Bool { nodePath() != nil }

    nonisolated private static func nodePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        let nvm = home + "/.nvm/versions/node"
        candidates += ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []).sorted().reversed().map { "\(nvm)/\($0)/bin/node" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func startRelay(port: Int) throws -> Process {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Relay/src/node-server.mjs").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Self.nodePath()))
        process.arguments = [script]
        process.environment = ProcessInfo.processInfo.environment.merging(["PORT": "\(port)", "HOST": "127.0.0.1"]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    @Test("a device reaches the Mac only through the relay, with no direct connection", .enabled(if: RemoteRelayTests.nodeAvailable)) func throughRelay() async throws {
        let relayPort = Int.random(in: 20_000...40_000)
        let relay = try startRelay(port: relayPort)
        defer { if relay.isRunning { relay.terminate() } }
        try await Task.sleep(for: .milliseconds(800))
        try #require(relay.isRunning, "Relay exited during startup; run npm ci --omit=dev --ignore-scripts in Relay and check that the port is available.")
        let backend = FakeBackend()
        _ = await backend.open("c1")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-relay-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "kiln.remote.test.\(UUID().uuidString)")!
        let server = RemoteServer(bridge: RemoteBridge(backend: backend), store: RemotePairingStore(directory: dir), hostName: "Test Mac", defaults: defaults)
        let relayURL = URL(string: "ws://127.0.0.1:\(relayPort)")!
        server.setRelay(relayURL)
        server.start(advertise: false)
        defer { server.stop() }
        for _ in 0..<100 where !server.relayConnected { try await Task.sleep(for: .milliseconds(100)) }
        #expect(server.relayConnected)
        #expect(server.pairing.relay == relayURL)

        let key = server.pairing.key
        let url = try #require(RelayAddress.url(relay: relayURL, pairingKey: key, role: .device))
        let device = LoopbackDevice(url: url, key: key, headers: [("Authorization", RelayAddress.authorizationHeader(pairingKey: key))])
        await device.connect()
        device.send(.hello(deviceName: "Phone on mobile data", protocolVersion: kilnRemoteProtocolVersion))
        #expect(await device.nextEvent() == .welcome(hostName: "Test Mac", protocolVersion: kilnRemoteProtocolVersion))

        // An approval raised at the Mac reaches the remote device, which answers it from afar.
        backend.pendingApprovals = [RemoteApproval(id: "a1", tool: "run_command", permission: "execute", preview: "echo from afar")]
        var sawApproval = false
        for _ in 0..<12 { if case .approvalRequested(let request)? = await device.nextEvent(), request.id == "a1" { sawApproval = true; break } }
        #expect(sawApproval)
        device.send(.decide(approvalID: "a1", decision: .allowOnce))
        for _ in 0..<50 where backend.decisions.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(backend.decisions.first?.0 == "a1")
        #expect(backend.decisions.first?.1 == .allowOnce)
        device.close()
    }
}

@Suite("Network addresses")
struct NetworkAddressTests {
    @Test("Tailscale's 100.64.0.0/10 range is recognised and ordinary private ranges are not") func tailscale() {
        #expect(NetworkAddresses.isTailscale("100.101.102.103"))
        #expect(NetworkAddresses.isTailscale("100.64.0.1") && NetworkAddresses.isTailscale("100.127.255.254"))
        #expect(!NetworkAddresses.isTailscale("100.63.0.1") && !NetworkAddresses.isTailscale("100.128.0.1"))
        #expect(!NetworkAddresses.isTailscale("192.168.1.20") && !NetworkAddresses.isTailscale("10.0.0.5"))
    }
}

/// A relay stand-in: records what the Mac asks it to push and answers with a canned reply.
final class StubRelayProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var reply: (Int, String) = (200, #"{"results":[]}"#)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            request.httpBody = data
        }
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.reply.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
@Suite("Approval push alerts", .serialized)
struct RemotePushTests {
    private let key = Data(repeating: 9, count: 32)
    private let approval = RemoteApproval(id: "A-1", tool: "run_command", permission: "execute", preview: "swift test --filter Login\nand more")
    private let token = String(repeating: "ab", count: 32)

    private func makeNotifier(relay: URL? = URL(string: "wss://relay.example.dev")) -> RemotePushNotifier {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-push-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubRelayProtocol.self]
        StubRelayProtocol.requests = []
        StubRelayProtocol.reply = (200, #"{"results":[]}"#)
        let defaults = UserDefaults(suiteName: "kiln.push.test.\(UUID().uuidString)")!
        let notifier = RemotePushNotifier(store: RemotePushStore(directory: dir), defaults: defaults, session: URLSession(configuration: configuration),
                                          relay: { relay }, pairingKey: { Data(repeating: 9, count: 32) })
        notifier.delay = .milliseconds(30)
        return notifier
    }

    @Test("the relay request carries the room, the password, the phones and a short alert") func request() throws {
        let device = PushDevice(token: token, environment: "sandbox", topic: "com.kiln.remote", addedAt: Date())
        let request = try #require(RemotePushNotifier.request(relay: URL(string: "wss://relay.example.dev/")!, pairingKey: key, devices: [device], approval: approval, includePreview: true))
        #expect(request.url?.absoluteString == "https://relay.example.dev/v1/push/\(RelayAddress.roomID(pairingKey: key))")
        #expect(request.value(forHTTPHeaderField: "Authorization") == RelayAddress.authorizationHeader(pairingKey: key))
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["approvalID"] as? String == "A-1")
        #expect((body["body"] as? String) == "run_command (execute): swift test --filter Login and more")
        let without = try #require(RemotePushNotifier.request(relay: URL(string: "ws://127.0.0.1:8787")!, pairingKey: key, devices: [device], approval: approval, includePreview: false))
        #expect(without.url?.scheme == "http")
        #expect((try JSONSerialization.jsonObject(with: without.httpBody ?? Data()) as? [String: Any])?["body"] as? String == "run_command (execute)")
    }

    @Test("only well-formed phones register, and duplicates replace each other") func register() {
        let notifier = makeNotifier()
        notifier.register(token: "not hex", environment: "sandbox", topic: "com.kiln.remote")
        notifier.register(token: token, environment: "elsewhere", topic: "com.kiln.remote")
        notifier.register(token: token, environment: "sandbox", topic: "")
        #expect(notifier.devices.isEmpty)
        notifier.register(token: token, environment: "sandbox", topic: "com.kiln.remote")
        notifier.register(token: token, environment: "production", topic: "com.kiln.remote")
        #expect(notifier.devices.count == 1 && notifier.devices[0].environment == "production")
    }

    @Test("an approval still waiting is pushed; one answered in time is not") func flow() async throws {
        let notifier = makeNotifier()
        notifier.register(token: token, environment: "sandbox", topic: "com.kiln.remote")
        StubRelayProtocol.reply = (200, #"{"results":[{"token":"\#(token)","ok":true}]}"#)
        notifier.approvalRaised(approval) { true }
        for _ in 0..<60 where StubRelayProtocol.requests.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(StubRelayProtocol.requests.count == 1)
        for _ in 0..<40 where !notifier.status.contains("sent") { try await Task.sleep(for: .milliseconds(25)) }
        #expect(notifier.status == "Alert sent to 1 phone")

        StubRelayProtocol.requests = []
        let quick = RemoteApproval(id: "A-2", tool: "x", permission: "write", preview: "")
        notifier.approvalRaised(quick) { false }          // answered before the delay ended
        let cancelled = RemoteApproval(id: "A-3", tool: "x", permission: "write", preview: "")
        notifier.approvalRaised(cancelled) { true }
        notifier.approvalResolved("A-3")                   // resolved at the Mac
        try await Task.sleep(for: .milliseconds(300))
        #expect(StubRelayProtocol.requests.isEmpty)
    }

    @Test("a token Apple says is dead is forgotten, and a relay without a key is reported") func dead() async throws {
        let notifier = makeNotifier()
        notifier.register(token: token, environment: "sandbox", topic: "com.kiln.remote")
        StubRelayProtocol.reply = (200, #"{"results":[{"token":"\#(token)","ok":false,"reason":"Unregistered"}]}"#)
        notifier.approvalRaised(approval) { true }
        for _ in 0..<80 where !notifier.devices.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(notifier.devices.isEmpty)
        notifier.register(token: token, environment: "sandbox", topic: "com.kiln.remote")
        StubRelayProtocol.reply = (501, #"{"error":"push not configured on this relay"}"#)
        notifier.approvalRaised(RemoteApproval(id: "A-9", tool: "x", permission: "write", preview: "")) { true }
        for _ in 0..<80 where !notifier.status.contains("no Apple push key") { try await Task.sleep(for: .milliseconds(25)) }
        #expect(notifier.status == "The relay has no Apple push key set up")
    }

    @Test("the bridge hands a push registration to the server") func bridge() async {
        let backend = FakeBackend()
        let bridge = RemoteBridge(backend: backend)
        var got: [String] = []
        bridge.onRegisterPush = { token, environment, topic in got = [token, environment, topic] }
        _ = await bridge.handle(.registerPush(token: token, environment: "sandbox", topic: "com.kiln.remote"))
        #expect(got == [token, "sandbox", "com.kiln.remote"])
    }
}
