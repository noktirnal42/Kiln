import KilnRemoteKit
import XCTest
@testable import KilnWatch

final class UnitTests: XCTestCase {
    func testSpokenTextDropsCodeAndLinks() {
        let text = SpokenText.clean("## Title\nSee [docs](https://x.dev) and https://y.dev\n```\ncode\n```\n- **bold** item")
        XCTAssertFalse(text.contains("#"))
        XCTAssertFalse(text.contains("```"))
        XCTAssertFalse(text.contains("https"))
        XCTAssertTrue(text.contains("docs"))
        XCTAssertTrue(text.hasSuffix("The code is on screen."))
    }

    func testKeychainStoreRoundTrip() {
        let store = KeychainPairingStore(service: "com.kiln.remote.watchkitapp.tests.\(UUID().uuidString)")
        let payload = PairingPayload(hostName: "Studio", serviceName: "Kiln-Studio", key: PairingPayload.makeKey())
        XCTAssertNil(store.load())
        store.save(payload)
        XCTAssertEqual(store.load(), payload)
        store.clear()
        XCTAssertNil(store.load())
    }

    func testPhoneContextParsing() {
        let payload = PairingPayload(hostName: "Studio", serviceName: "Kiln-Studio", key: PairingPayload.makeKey())
        XCTAssertEqual(PhoneLink.payload(from: [PhoneLink.contextKey: payload.url.absoluteString]), .some(payload))
        XCTAssertEqual(PhoneLink.payload(from: [PhoneLink.contextKey: ""]), .some(nil))     // revoked
        XCTAssertEqual(PhoneLink.payload(from: [:]), .some(nil))                            // revoked
        XCTAssertNil(PhoneLink.payload(from: [PhoneLink.contextKey: "kiln-remote://pair?bogus"]))   // malformed: ignored
    }
}

final class ConnectorTests: XCTestCase {
    func testManualAddressValidation() {
        XCTAssertTrue(ManualAddress.isHostPort("192.168.1.20:47900"))
        XCTAssertTrue(ManualAddress.isHostPort("mac.local:1"))
        XCTAssertFalse(ManualAddress.isHostPort("192.168.1.20"))
        XCTAssertFalse(ManualAddress.isHostPort("host:99999"))
        XCTAssertFalse(ManualAddress.isHostPort("http://x:1"))
    }

    /// A dead direct address is skipped, then the next works, and progress names each attempt.
    func testDirectAddressesAreTriedInOrder() async throws {
        let key = PairingPayload.makeKey()
        let server = try FakeMacServer(key: key)
        try await server.start()
        defer { server.stop() }
        let pairing = PairingPayload(hostName: "Fake", serviceName: "Fake", key: key, direct: ["127.0.0.1:1", "127.0.0.1:\(server.port)"])
        let steps = StepLog()
        let transport = try await MacConnector.connect(pairing, manual: nil) { text in steps.add(text) }
        transport.close()
        XCTAssertEqual(steps.all, ["Trying 127.0.0.1:1…", "Trying 127.0.0.1:\(server.port)…"])
    }

    func testAllFailuresAreReportedPerAttempt() async throws {
        let pairing = PairingPayload(hostName: "Fake", serviceName: "NoSuchService-\(UUID().uuidString)", key: PairingPayload.makeKey(), direct: ["127.0.0.1:1"])
        do {
            _ = try await MacConnector.connect(pairing, manual: nil) { _ in }
            XCTFail("expected failure")
        } catch RemoteError.attemptsFailed(let tried) {
            XCTAssertTrue(tried.first?.hasPrefix("127.0.0.1:1:") ?? false)
            XCTAssertTrue(tried.contains { $0.hasPrefix("Bonjour:") })
        }
    }
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    func add(_ text: String) { lock.withLock { steps.append(text) } }
    var all: [String] { lock.withLock { steps } }
}
