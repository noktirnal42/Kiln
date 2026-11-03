import KilnRemoteKit
import XCTest
@testable import KilnWatch

@MainActor
final class SessionTests: XCTestCase {
    private var server: FakeMacServer!
    private var key: Data!
    private var speaker: SpySpeaker!
    private var haptics: SpyHaptics!

    override func setUp() async throws {
        key = PairingPayload.makeKey()
        server = try FakeMacServer(key: key)
        try await server.start()
        speaker = SpySpeaker()
        haptics = SpyHaptics()
    }

    override func tearDown() async throws { server.stop() }

    private func makeSession(pairingKey: Data? = nil, dictated: String? = "run the tests") -> (RemoteSession, InMemoryPairingStore) {
        let store = InMemoryPairingStore(PairingPayload(hostName: "Fake Mac", serviceName: "Fake", key: pairingKey ?? key))
        let url = server.url
        let session = RemoteSession(
            store: store,
            connector: { pairing, _ in
                let transport = NWTransport(url: url)
                try await transport.start()
                return RemoteClient(transport: transport, pairingKey: pairing.key, deviceName: "Test Watch")
            },
            transcriber: StubTranscriber(text: dictated), speaker: speaker, haptics: haptics
        )
        return (session, store)
    }

    func testPhoneReachableRestartsAnInFlightNetworkSearch() async throws {
        let attempts = AttemptCounter()
        let store = InMemoryPairingStore(PairingPayload(hostName: "Fake Mac", serviceName: "Fake", key: key))
        let url = server.url
        let session = RemoteSession(store: store, connector: { pairing, _ in
            if await attempts.next() == 1 { try await Task.sleep(for: .seconds(30)) }
            let transport = NWTransport(url: url)
            try await transport.start()
            return RemoteClient(transport: transport, pairingKey: pairing.key, deviceName: "Test Watch")
        }, transcriber: StubTranscriber(text: nil), speaker: speaker, haptics: haptics)
        session.connect()
        try await Task.sleep(for: .milliseconds(100))
        session.phoneBecameReachable()
        let connected = await waitUntil { session.isConnected }
        XCTAssertTrue(connected)
    }

    /// Regression: the microphone string was lost once when project.yml regenerated Info.plist, and the app crashed on Talk.
    func testBuiltAppDeclaresWhyItUsesTheMicrophone() {
        let text = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        XCTAssertFalse((text ?? "").isEmpty)
    }

    func testTalkRecordsStraightAwayAndTheMacTranscribesIt() async throws {
        let store = InMemoryPairingStore(PairingPayload(hostName: "Fake Mac", serviceName: "Fake", key: key))
        let url = server.url
        let recorder = StubRecorder(VoiceRecording(data: Data([1, 2, 3]), format: "m4a"))
        let dictation = SpyDictation()
        let session = RemoteSession(store: store, connector: { pairing, _ in
            let transport = NWTransport(url: url)
            try await transport.start()
            return RemoteClient(transport: transport, pairingKey: pairing.key, deviceName: "Test Watch")
        }, transcriber: dictation, recorder: recorder, speaker: speaker, haptics: haptics)
        session.connect()
        let connected = await waitUntil { session.isConnected }
        XCTAssertTrue(connected)
        await session.talkTapped()
        XCTAssertEqual(recorder.started, 1)
        XCTAssertEqual(dictation.calls, 0, "the system dictation sheet must not open")
        let heard = await waitUntil { session.lastHeard == "run the tests" }
        XCTAssertTrue(heard)
        let sent = await waitUntil { self.server.received.contains(.sendAudio(data: Data([1, 2, 3]), format: "m4a")) }
        XCTAssertTrue(sent)
    }

    func testNothingHeardTellsThePersonAndGoesIdle() async throws {
        let store = InMemoryPairingStore(PairingPayload(hostName: "Fake Mac", serviceName: "Fake", key: key))
        let url = server.url
        let session = RemoteSession(store: store, connector: { pairing, _ in
            let transport = NWTransport(url: url)
            try await transport.start()
            return RemoteClient(transport: transport, pairingKey: pairing.key, deviceName: "Test Watch")
        }, transcriber: StubTranscriber(text: nil), recorder: StubRecorder(nil), speaker: speaker, haptics: haptics)
        session.connect()
        let connected = await waitUntil { session.isConnected }
        XCTAssertTrue(connected)
        await session.talkTapped()
        XCTAssertEqual(session.talk, .idle)
        XCTAssertTrue(session.latestReply.contains("didn't hear"))
    }

    func testSecondTapWhileListeningEndsTheRecording() async throws {
        let recorder = StubRecorder(nil)
        let store = InMemoryPairingStore(PairingPayload(hostName: "Fake Mac", serviceName: "Fake", key: key))
        let url = server.url
        let session = RemoteSession(store: store, connector: { pairing, _ in
            let transport = NWTransport(url: url)
            try await transport.start()
            return RemoteClient(transport: transport, pairingKey: pairing.key, deviceName: "Test Watch")
        }, transcriber: StubTranscriber(text: nil), recorder: recorder, speaker: speaker, haptics: haptics)
        session.seedDemo(link: .connected(host: "Fake Mac"), reply: "", heard: "", approval: nil)
        session.forceTalk(.listening)
        await session.talkTapped()
        XCTAssertEqual(recorder.finished, 1)
    }

    func testConnectsOpensConversationAndReportsHost() async throws {
        let (session, _) = makeSession()
        session.connect()
        let connected = await waitUntil { session.link == .connected(host: "Fake Mac") }
        XCTAssertTrue(connected)
        let opened = await waitUntil { self.server.received.contains(.openConversation(id: "c1")) }
        XCTAssertTrue(opened)
        guard case .hello(_, let version)? = server.received.first else { return XCTFail("hello must be the first command") }
        XCTAssertEqual(version, kilnRemoteProtocolVersion)
    }

    func testSpokenMessageIsSentSpokenAndReplyIsSpokenCleaned() async throws {
        server.reply = { _ in "# Result\nAll **42** tests pass.\n```swift\nlet x = 1\n```" }
        let (session, _) = makeSession()
        session.connect()
        _ = await waitUntil { session.isConnected }
        await session.talkTapped()
        let sent = await waitUntil { self.server.received.contains(.send(text: "run the tests", spoken: true)) }
        XCTAssertTrue(sent)
        let spoke = await waitUntil { !self.speaker.spoken.isEmpty }
        XCTAssertTrue(spoke)
        XCTAssertEqual(session.lastHeard, "run the tests")
        XCTAssertTrue(session.latestReply.contains("42"))
        let spokenText = SpokenText.clean(session.latestReply)
        XCTAssertFalse(spokenText.contains("```"))
        XCTAssertEqual(speaker.spoken.first, session.latestReply)   // speaker cleans internally; session hands over the raw reply
        let idle = await waitUntil { session.talk == .idle }
        XCTAssertTrue(idle)
    }

    func testCancelledDictationSendsNothing() async throws {
        let (session, _) = makeSession(dictated: nil)
        session.connect()
        _ = await waitUntil { session.isConnected }
        await session.talkTapped()
        XCTAssertEqual(session.talk, .idle)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(server.received.contains { if case .send = $0 { true } else { false } })
    }

    func testApprovalRequestBuzzesShowsAndAllowOnceIsSent() async throws {
        let (session, _) = makeSession()
        session.connect()
        _ = await waitUntil { session.isConnected }
        let approval = RemoteApproval(id: "a1", tool: "run_command", permission: "execute", preview: "rm -rf build")
        server.push(.approvalRequested(approval))
        let shown = await waitUntil { session.reviewing == approval }
        XCTAssertTrue(shown)
        XCTAssertEqual(haptics.played.first, .approval)
        session.decide(approval, .allowOnce)
        let sent = await waitUntil { self.server.received.contains(.decide(approvalID: "a1", decision: .allowOnce)) }
        XCTAssertTrue(sent)
        let cleared = await waitUntil { session.pendingApprovals.isEmpty }
        XCTAssertTrue(cleared)
        XCTAssertNil(session.reviewing)
    }

    func testApprovalResolvedAtTheMacClearsIt() async throws {
        let (session, _) = makeSession()
        session.connect()
        _ = await waitUntil { session.isConnected }
        server.push(.approvalRequested(RemoteApproval(id: "a2", tool: "write_file", permission: "write", preview: "x")))
        _ = await waitUntil { !session.pendingApprovals.isEmpty }
        server.push(.approvalResolved(approvalID: "a2"))
        let cleared = await waitUntil { session.pendingApprovals.isEmpty }
        XCTAssertTrue(cleared)
    }

    func testWrongKeyEndsOfflineAndServerDropsIt() async throws {
        let (session, _) = makeSession(pairingKey: PairingPayload.makeKey())
        session.connect()
        let offline = await waitUntil { if case .offline = session.link { true } else { false } }
        XCTAssertTrue(offline)
        XCTAssertFalse(session.isConnected)
    }

    func testRevokedPairingClearsKeyAndDisconnects() async throws {
        let (session, store) = makeSession()
        session.connect()
        _ = await waitUntil { session.isConnected }
        session.pairingChanged(nil)
        XCTAssertNil(store.load())
        XCTAssertEqual(session.link, .unpaired)
    }

    func testTapWhileSpeakingSilencesVoice() async throws {
        let (session, _) = makeSession()
        speaker.finishImmediately = false
        session.connect()
        _ = await waitUntil { session.isConnected }
        await session.talkTapped()
        _ = await waitUntil { session.talk == .speaking }
        await session.talkTapped()
        XCTAssertEqual(session.talk, .idle)
        XCTAssertEqual(speaker.stopped, 1)
    }
}

private actor AttemptCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}
