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
