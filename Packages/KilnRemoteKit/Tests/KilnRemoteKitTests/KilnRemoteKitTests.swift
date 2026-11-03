import Foundation
import Testing
@testable import KilnRemoteKit

@Suite("Remote protocol")
struct RemoteProtocolTests {
    @Test("commands and events survive a round trip") func roundTrip() throws {
        let command = RemoteCommand.send(text: "run the tests", spoken: true)
        #expect(try RemoteCoding.decode(RemoteCommand.self, from: RemoteCoding.encode(command)) == command)
        let request = RemoteApproval(id: "a1", tool: "run_command", permission: "execute", preview: "swift test")
        let event = RemoteEvent.approvalRequested(request)
        #expect(try RemoteCoding.decode(RemoteEvent.self, from: RemoteCoding.encode(event)) == event)
        let opened = RemoteEvent.opened(conversation: RemoteConversation(id: "c", title: "T", updatedAt: Date(timeIntervalSince1970: 1_700_000_000)),
                                        messages: [RemoteMessage(id: "m", role: .assistant, text: "Hi", createdAt: Date(timeIntervalSince1970: 1_700_000_001))],
                                        isStreaming: false)
        #expect(try RemoteCoding.decode(RemoteEvent.self, from: RemoteCoding.encode(opened)) == opened)
    }

    @Test("remote approval cannot grant standing access") func noAlwaysAllow() {
        #expect(RemoteApprovalDecision(rawValue: "alwaysAllow") == nil)
    }
}

@Suite("Pairing")
struct PairingTests {
    @Test("the pairing link carries the key and parses back") func link() throws {
        let payload = PairingPayload(hostName: "Jeremy's Mac", serviceName: "Kiln-1234", key: PairingPayload.makeKey())
        let parsed = try #require(PairingPayload(url: payload.url))
        #expect(parsed == payload)
    }

    @Test("links with a short key or another scheme are refused") func refuses() {
        #expect(PairingPayload(url: URL(string: "kiln-remote://pair?host=a&service=b&key=AAAA&v=1")!) == nil)
        #expect(PairingPayload(url: URL(string: "https://pair?host=a&service=b")!) == nil)
    }
}

@Suite("Secure channel")
struct SecureChannelTests {
    private func pair() -> (SecureChannel, SecureChannel) {
        let key = PairingPayload.makeKey(), a = SecureChannel.makeNonce(), b = SecureChannel.makeNonce()
        return (SecureChannel(pairingKey: key, clientNonce: a, serverNonce: b, role: .mac),
                SecureChannel(pairingKey: key, clientNonce: a, serverNonce: b, role: .device))
    }

    @Test("frames decrypt on the other side, in both directions") func roundTrip() throws {
        var (mac, device) = pair()
        let down = try mac.seal(Data("hello phone".utf8))
        #expect(try device.open(down) == Data("hello phone".utf8))
        let up = try device.seal(Data("hello mac".utf8))
        #expect(try mac.open(up) == Data("hello mac".utf8))
    }

    @Test("replayed, reordered and tampered frames are rejected") func attacks() throws {
        var (mac, device) = pair()
        let first = try mac.seal(Data("one".utf8)), second = try mac.seal(Data("two".utf8))
        #expect(throws: SecureChannelError.outOfOrder) { try device.open(second) }
        _ = try device.open(first)
        #expect(throws: SecureChannelError.outOfOrder) { try device.open(first) }
        var tampered = second
        tampered[tampered.count - 1] ^= 0x01
        #expect(throws: SecureChannelError.authenticationFailed) { try device.open(tampered) }
        #expect(try device.open(second) == Data("two".utf8))
    }

    @Test("a frame cannot be reflected back to its sender, and a wrong key fails") func reflectionAndKey() throws {
        var (mac, device) = pair()
        let frame = try mac.seal(Data("x".utf8))
        #expect(throws: SecureChannelError.authenticationFailed) { try mac.open(frame) }
        var stranger = SecureChannel(pairingKey: PairingPayload.makeKey(), clientNonce: Data(count: 16), serverNonce: Data(count: 16), role: .device)
        #expect(throws: SecureChannelError.authenticationFailed) { try stranger.open(frame) }
        _ = device
    }
}
