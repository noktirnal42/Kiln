import KilnRemoteKit
import XCTest
@testable import KilnWatch

/// Stands in for the iPhone: speaks the bridge contract to the watch and forwards to a Mac over a real
/// connection (the fake Mac server), as the iOS app does.
final class FakePhone: BridgeMessenger, @unchecked Sendable {
    private let lock = NSLock()
    private var _reachable = true
    private var client: RemoteClient?
    private var pump: Task<Void, Never>?
    private let macURL: URL
    private let key: Data
    var bridge: PhoneBridge?
    private(set) var queued: [[String: String]] = []

    init(macURL: URL, key: Data) { self.macURL = macURL; self.key = key }

    var isReachable: Bool { lock.withLock { _reachable } }
    func setReachable(_ value: Bool) { lock.withLock { _reachable = value } }

    func send(_ message: [String: String], reply: (@Sendable ([String: String]) -> Void)?, failure: @escaping @Sendable (Error) -> Void) {
        if message[PhoneBridge.controlKey] == "open" {
            Task {
                do {
                    let transport = NWTransport(url: macURL)
                    try await transport.start(timeout: 1)
                    let client = RemoteClient(transport: transport, pairingKey: key, deviceName: "Phone")
                    let events = await client.connect()
                    self.lock.withLock { self.client = client }
                    reply?([PhoneBridge.controlKey: "ready", "host": "Fake Mac"])
                    self.pump = Task { [weak self] in
                        do {
                            for try await event in events {
                                guard let json = try? RemoteCoding.encode(event) else { continue }
                                self?.bridge?.deliver(String(decoding: json, as: UTF8.self))
                            }
                        } catch { }
                    }
                } catch { reply?([PhoneBridge.controlKey: "error", "reason": "Mac not connected"]) }
            }
        } else if let json = message[PhoneBridge.commandKey], let command = try? RemoteCoding.decode(RemoteCommand.self, from: Data(json.utf8)) {
            let client = lock.withLock { self.client }
            Task { try? await client?.send(command) }
        }
    }

    func queue(_ userInfo: [String: String]) { lock.withLock { queued.append(userInfo) } }

    func stop() { pump?.cancel() }
}

@MainActor
final class BridgeTests: XCTestCase {
    private var server: FakeMacServer!
    private var key: Data!

    override func setUp() async throws {
        key = PairingPayload.makeKey()
        server = try FakeMacServer(key: key)
        try await server.start()
    }
    override func tearDown() async throws { server.stop() }

    private func session(phone: FakePhone, direct: [String] = []) -> RemoteSession {
        let bridge = PhoneBridge(messenger: phone)
        phone.bridge = bridge
        let store = InMemoryPairingStore(PairingPayload(hostName: "Fake Mac", serviceName: "NoSuch-\(UUID().uuidString)", key: key, direct: direct))
        return RemoteSession(store: store, connector: { pairing, progress in try await MacConnector.channel(pairing, bridge: bridge, manual: nil, progress: progress) },
                             transcriber: StubTranscriber(text: "hello from the wrist"), speaker: SpySpeaker(), haptics: SpyHaptics())
    }

    func testSpokenMessageAndReplyTravelThroughThePhone() async throws {
        let phone = FakePhone(macURL: server.url, key: key)
        defer { phone.stop() }
        let session = session(phone: phone)
        session.connect()
        let connected = await waitUntil { session.link == .connected(host: "Fake Mac") }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.route, "via iPhone")
        await session.talkTapped()
        let sent = await waitUntil { self.server.received.contains(.send(text: "hello from the wrist", spoken: true)) }
        XCTAssertTrue(sent)
        let replied = await waitUntil { session.latestReply == "Done: hello from the wrist" }
        XCTAssertTrue(replied)
    }

    func testApprovalArrivesAndDecisionGoesBackThroughThePhone() async throws {
        let phone = FakePhone(macURL: server.url, key: key)
        defer { phone.stop() }
        let session = session(phone: phone)
        session.connect()
        _ = await waitUntil { session.isConnected }
        _ = await waitUntil { self.server.received.contains(.openConversation(id: "c1")) }
        let approval = RemoteApproval(id: "b1", tool: "run_command", permission: "execute", preview: "echo watch-test")
        server.push(.approvalRequested(approval))
        let shown = await waitUntil { session.reviewing == approval }
        XCTAssertTrue(shown)
        session.decide(approval, .deny)
        let denied = await waitUntil { self.server.received.contains(.decide(approvalID: "b1", decision: .deny)) }
        XCTAssertTrue(denied)
    }

    func testUnreachablePhoneFallsBackToDirectAddress() async throws {
        let phone = FakePhone(macURL: server.url, key: key)
        phone.setReachable(false)
        let session = session(phone: phone, direct: ["127.0.0.1:\(server.port)"])
        session.connect()
        let connected = await waitUntil { session.isConnected }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.route, "on Wi-Fi")
    }

    func testUnreachablePhoneAndNoMacSaysSoPerAttempt() async throws {
        let phone = FakePhone(macURL: server.url, key: key)
        phone.setReachable(false)
        let session = session(phone: phone, direct: ["127.0.0.1:1"])
        session.connect()
        let offline = await waitUntil(timeout: 15) { if case .offline = session.link { true } else { false } }
        XCTAssertTrue(offline)
        guard case .offline(let reason) = session.link else { return }
        XCTAssertTrue(reason.contains("iPhone not reachable"), reason)
        XCTAssertTrue(reason.contains("127.0.0.1:1"), reason)
    }

    func testPhoneThatCannotReachMacIsReportedAsSuch() async throws {
        let dead = FakePhone(macURL: URL(string: "ws://127.0.0.1:1")!, key: key)
        let bridge = PhoneBridge(messenger: dead)
        do { _ = try await bridge.open(timeout: 3); XCTFail("expected failure") } catch RemoteError.bridge(let reason) { XCTAssertEqual(reason, "Mac not connected") }
    }
}
