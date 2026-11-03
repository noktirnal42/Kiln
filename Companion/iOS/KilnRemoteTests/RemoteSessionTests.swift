import FakeMacKit
import Foundation
import KilnRemoteKit
import Testing
@testable import KilnRemote

@MainActor
struct RemoteSessionTests {
    private let quick: [Duration] = [.milliseconds(100), .milliseconds(200)]

    private func makeSession(_ server: FakeMacServer, key: Data? = nil) -> RemoteSession {
        let mac = PairedMac(hostName: server.hostName, serviceName: server.serviceName, key: key ?? server.key)
        return RemoteSession(store: MemoryPairingStore(mac), endpointOverride: .hostPort("127.0.0.1", server.port), deviceName: "Test Phone", backoff: quick)
    }

    private func wait(_ timeout: Duration = .seconds(5), until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func connectsAndLoadsConversations() async throws {
        let server = FakeMacServer()
        try await server.start()
        defer { server.stop() }
        let session = makeSession(server)
        session.start()
        defer { session.stop() }

        #expect(await wait { session.isConnected })
        #expect(session.hostName == "Fake Mac")
        #expect(await wait { session.conversations.count == 3 && session.messages.count == 2 })
        #expect(session.openConversation?.id == "c1")
        #expect(server.receivedCommands.first == .hello(deviceName: "Test Phone", protocolVersion: kilnRemoteProtocolVersion))
    }

    @Test func streamsAReplyAndKeepsTheFinishedMessage() async throws {
        let server = FakeMacServer()
        try await server.start()
        defer { server.stop() }
        let session = makeSession(server)
        session.start()
        defer { session.stop() }
        #expect(await wait { session.isConnected && !session.messages.isEmpty })

        var spoken: [String] = []
        session.onAssistantMessage = { spoken.append($0.text) }
        session.send("hello there", spoken: true)

        #expect(await wait { session.messages.contains { $0.role == .assistant && $0.text.contains("hello there") } })
        #expect(await wait { !session.isStreaming })
        #expect(session.streamingText.isEmpty)
        #expect(spoken.count == 1)
        #expect(server.receivedCommands.contains(.send(text: "hello there", spoken: true)))
        // The user's own message came back from the Mac exactly once.
        #expect(session.messages.filter { $0.role == .user && $0.text == "hello there" }.count == 1)
    }

    @Test func approvalIsShownAndDecided() async throws {
        let server = FakeMacServer()
        try await server.start()
        defer { server.stop() }
        let session = makeSession(server)
        session.start()
        defer { session.stop() }
        #expect(await wait { session.isConnected && !session.messages.isEmpty })

        var notified: [RemoteApproval] = []
        session.onApprovalRequested = { notified.append($0) }
        session.send("please approve this")
        #expect(await wait { session.approvals.count == 1 })
        let approval = try #require(session.approvals.first)
        #expect(approval.permission == "execute")
        #expect(approval.preview.contains("swift test"))
        #expect(notified.count == 1)

        session.decide(approval, .allowOnce)
        #expect(session.approvals.isEmpty)
        #expect(await wait { server.receivedCommands.contains(.decide(approvalID: approval.id, decision: .allowOnce)) })
        #expect(await wait { session.messages.contains { $0.role == .assistant && $0.text.contains("approved") } })
    }

    @Test func reconnectsAfterTheConnectionDrops() async throws {
        let server = FakeMacServer()
        try await server.start()
        defer { server.stop() }
        let session = makeSession(server)
        session.start()
        defer { session.stop() }
        #expect(await wait { session.isConnected })

        server.dropConnections()
        #expect(await wait { !session.isConnected })
        #expect(await wait { session.isConnected && !session.conversations.isEmpty })
        #expect(server.receivedCommands.filter { if case .hello = $0 { true } else { false } }.count == 2)
    }

    @Test func wrongKeyEndsInNeedsRepairing() async throws {
        let server = FakeMacServer()
        try await server.start()
        defer { server.stop() }
        let session = makeSession(server, key: PairingPayload.makeKey())
        session.start()
        defer { session.stop() }

        #expect(await wait { session.status == .needsRepairing })
        #expect(server.receivedCommands.isEmpty)
    }

    @Test func pairingPersistsAndUnpairClears() throws {
        let store = MemoryPairingStore()
        let session = RemoteSession(store: store, endpointOverride: .hostPort("127.0.0.1", 1), deviceName: "x")
        #expect(session.status == .unpaired)
        session.pair(with: PairingPayload(hostName: "Studio", serviceName: "Kiln on Studio", key: PairingPayload.makeKey()))
        #expect(store.load()?.hostName == "Studio")
        session.unpair()
        #expect(store.load() == nil)
        #expect(session.status == .unpaired)
    }

    @Test func eventHandlingMergesMessagesAndResolvesApprovals() {
        let session = RemoteSession(store: MemoryPairingStore(), deviceName: "x")
        let approval = RemoteApproval(id: "a", tool: "shell", permission: "execute", preview: "ls")
        session.handle(.approvalRequested(approval))
        session.handle(.approvalRequested(approval))
        #expect(session.approvals.count == 1)
        session.handle(.approvalResolved(approvalID: "a"))
        #expect(session.approvals.isEmpty)

        session.handle(.delta(text: "Hel"))
        session.handle(.delta(text: "lo"))
        #expect(session.streamingText == "Hello")
        let message = RemoteMessage(id: "m", role: .assistant, text: "Hello", createdAt: Date())
        session.handle(.message(message))
        session.handle(.message(message))
        #expect(session.messages.count == 1)
        #expect(session.streamingText.isEmpty)
    }
}

struct KeychainStoreTests {
    @Test func roundTripsThroughTheKeychain() throws {
        let store = KeychainPairingStore(service: "com.kiln.remote.tests.\(UUID().uuidString)")
        defer { store.clear() }
        #expect(store.load() == nil)
        let mac = PairedMac(hostName: "Studio", serviceName: "Kiln on Studio", key: PairingPayload.makeKey())
        try store.save(mac)
        #expect(store.load() == mac)
        store.clear()
        #expect(store.load() == nil)
    }
}

struct SpokenTextTests {
    @Test func dropsCodeAndMarkdownPunctuation() {
        let spoken = SpokenText.clean("## Done\n\nRun `swift test`:\n\n```sh\nswift test\n```\n\nSee [the docs](https://example.com) and https://x.dev")
        #expect(!spoken.contains("`") && !spoken.contains("#") && !spoken.contains("https"))
        #expect(spoken.contains("the docs"))
        #expect(spoken.hasSuffix("The code is on screen."))
    }

    @Test func splitsLongTextAtSentences() {
        let sentence = "This is a fairly ordinary sentence. "
        let chunks = SpokenText.chunks(String(repeating: sentence, count: 30), limit: 200)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 240 })
    }
}

@MainActor
struct ManualAddressTests {
    @Test func parsesHostAndPort() {
        func mac(_ address: String?) -> PairedMac { PairedMac(hostName: "x", serviceName: "y", key: Data(count: 32), address: address) }
        #expect(mac("100.64.1.2:47900").manualEndpoint?.host == "100.64.1.2")
        #expect(mac("100.64.1.2:47900").manualEndpoint?.port == 47900)
        #expect(mac("[fd7a::1]:47900").manualEndpoint?.host == "fd7a::1")
        #expect(mac("mac.tailnet.ts.net:1").manualEndpoint?.port == 1)
        #expect(mac("nonsense").manualEndpoint == nil)
        #expect(mac("host:99999").manualEndpoint == nil)
        #expect(mac(nil).manualEndpoint == nil)
    }

    @Test func connectsThroughATypedAddressWithoutBonjour() async throws {
        let server = FakeMacServer()
        try await server.start()
        defer { server.stop() }
        let mac = PairedMac(hostName: server.hostName, serviceName: "unused", key: server.key, address: "127.0.0.1:\(server.port)")
        let session = RemoteSession(store: MemoryPairingStore(mac), deviceName: "Test Phone", backoff: [.milliseconds(100)])
        session.start()
        defer { session.stop() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !session.isConnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(session.isConnected)
    }

    @Test func relayURLAndHeaderComeFromThePairingKey() throws {
        let key = PairingPayload.makeKey()
        let url = try #require(RelayAddress.url(relay: URL(string: "wss://relay.example")!, pairingKey: key, role: .device))
        #expect(url.absoluteString.hasPrefix("wss://relay.example/v1/room/"))
        #expect(url.absoluteString.hasSuffix("role=device"))
        #expect(!url.absoluteString.contains(key.base64EncodedString()))
        #expect(RelayAddress.authorizationHeader(pairingKey: key).hasPrefix("Bearer "))
    }

    @Test func keychainKeepsRelayAndAddress() throws {
        let store = KeychainPairingStore(service: "com.kiln.remote.tests.\(UUID().uuidString)")
        defer { store.clear() }
        let mac = PairedMac(hostName: "Studio", serviceName: "s", key: PairingPayload.makeKey(), relay: URL(string: "wss://relay.example"), address: "1.2.3.4:5")
        try store.save(mac)
        #expect(store.load() == mac)
    }

    @Test func triesDirectAddressesInOrderUntilOneAnswers() async throws {
        let server = FakeMacServer()
        try await server.start()
        defer { server.stop() }
        // First address refuses, second is the Mac; no Bonjour or relay needed.
        let mac = PairedMac(hostName: server.hostName, serviceName: "unused", key: server.key, direct: ["127.0.0.1:1", "127.0.0.1:\(server.port)"])
        let session = RemoteSession(store: MemoryPairingStore(mac), deviceName: "Test Phone", backoff: [.milliseconds(100)])
        session.start()
        defer { session.stop() }
        let deadline = ContinuousClock.now + .seconds(8)
        while !session.isConnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(session.isConnected)
    }

    @Test func pairingKeepsDirectAndRelayFromTheLink() throws {
        let key = PairingPayload.makeKey()
        let payload = PairingPayload(hostName: "Studio", serviceName: "s", key: key, relay: URL(string: "wss://relay.example"), direct: ["192.168.1.5:47900"])
        let parsed = try #require(PairingPayload(url: payload.url))
        let session = RemoteSession(store: MemoryPairingStore(), endpointOverride: .hostPort("127.0.0.1", 1), deviceName: "x")
        session.pair(with: parsed)
        #expect(session.mac?.direct == ["192.168.1.5:47900"])
        #expect(session.mac?.relay?.host == "relay.example")
        session.unpair()
    }
}

@MainActor
struct WatchBridgeTests {
    private func connected() async throws -> (FakeMacServer, RemoteSession) {
        let server = FakeMacServer()
        try await server.start()
        let mac = PairedMac(hostName: server.hostName, serviceName: "unused", key: server.key, address: "127.0.0.1:\(server.port)")
        let session = RemoteSession(store: MemoryPairingStore(mac), deviceName: "Test Phone", backoff: [.milliseconds(100)])
        session.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while !(session.isConnected && !session.messages.isEmpty), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return (server, session)
    }

    @Test func helloGetsASnapshotAndCommandsReachTheMac() async throws {
        let (server, session) = try await connected()
        defer { server.stop(); session.stop() }
        let bridge = WatchBridge()
        var events: [RemoteEvent] = []
        bridge.sink = { events.append($0) }
        bridge.attach(session)

        bridge.receive(try RemoteCoding.encode(RemoteCommand.hello(deviceName: "Watch", protocolVersion: kilnRemoteProtocolVersion)))
        #expect(events.contains { if case .welcome = $0 { true } else { false } })
        #expect(events.contains { if case .conversations(let list) = $0 { list.count == 3 } else { false } })
        #expect(events.contains { if case .opened = $0 { true } else { false } })

        bridge.receive(try RemoteCoding.encode(RemoteCommand.send(text: "from the watch", spoken: true)))
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.receivedCommands.contains(.send(text: "from the watch", spoken: true)), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.receivedCommands.contains(.send(text: "from the watch", spoken: true)))
        // The Mac's streamed reply is forwarded back to the watch.
        let replyDeadline = ContinuousClock.now + .seconds(5)
        while !events.contains(where: { if case .message(let m) = $0 { m.role == .assistant && m.text.contains("from the watch") } else { false } }), ContinuousClock.now < replyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(events.contains { if case .delta = $0 { true } else { false } })
        #expect(events.contains { if case .message(let m) = $0 { m.role == .assistant && m.text.contains("from the watch") } else { false } })
    }

    @Test func approvalIsForwardedAndTheWatchDecisionReachesTheMac() async throws {
        let (server, session) = try await connected()
        defer { server.stop(); session.stop() }
        let bridge = WatchBridge()
        var events: [RemoteEvent] = []
        bridge.sink = { events.append($0) }
        bridge.attach(session)

        session.send("approve this")
        var approvalID: String?
        let deadline = ContinuousClock.now + .seconds(5)
        while approvalID == nil, ContinuousClock.now < deadline {
            for case .approvalRequested(let a) in events { approvalID = a.id }
            try await Task.sleep(for: .milliseconds(20))
        }
        let id = try #require(approvalID)
        bridge.receive(try RemoteCoding.encode(RemoteCommand.decide(approvalID: id, decision: .deny)))
        let decideDeadline = ContinuousClock.now + .seconds(5)
        while !server.receivedCommands.contains(.decide(approvalID: id, decision: .deny)), ContinuousClock.now < decideDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.receivedCommands.contains(.decide(approvalID: id, decision: .deny)))
        #expect(session.approvals.isEmpty)
    }

    @Test func commandsWhileDisconnectedAreNotReplayedOnReconnect() async throws {
        let server = FakeMacServer()
        try await server.start()
        defer { server.stop() }
        let mac = PairedMac(hostName: server.hostName, serviceName: "unused", key: server.key, address: "127.0.0.1:\(server.port)")
        let session = RemoteSession(store: MemoryPairingStore(mac), deviceName: "Test Phone", backoff: [.milliseconds(100)])
        defer { session.stop() }
        let bridge = WatchBridge()
        var events: [RemoteEvent] = []
        bridge.sink = { events.append($0) }
        bridge.attach(session)

        // A disconnected phone asks the watch to retry; it must not replay an old command.
        bridge.receive(try RemoteCoding.encode(RemoteCommand.send(text: "held until online", spoken: false)))
        #expect(events.contains { if case .error = $0 { true } else { false } })
        #expect(!server.receivedCommands.contains(.send(text: "held until online", spoken: false)))
        session.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while !session.isConnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(session.isConnected)
        #expect(!server.receivedCommands.contains(.send(text: "held until online", spoken: false)))
    }
}
