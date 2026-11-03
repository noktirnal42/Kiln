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

    @Test("audio commands and transcripts survive a round trip") func audio() throws {
        let command = RemoteCommand.sendAudio(data: Data([1, 2, 3, 255]), format: "m4a")
        #expect(try RemoteCoding.decode(RemoteCommand.self, from: RemoteCoding.encode(command)) == command)
        let event = RemoteEvent.transcript("run the tests")
        #expect(try RemoteCoding.decode(RemoteEvent.self, from: RemoteCoding.encode(event)) == event)
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

@Suite("Relay addressing")
struct RelayTests {
    @Test("room and password are stable for a key, differ between keys and from each other") func derivation() {
        let key = Data(repeating: 7, count: 32), other = Data(repeating: 8, count: 32)
        #expect(RelayAddress.roomID(pairingKey: key) == RelayAddress.roomID(pairingKey: key))
        #expect(RelayAddress.roomID(pairingKey: key) != RelayAddress.roomID(pairingKey: other))
        #expect(RelayAddress.roomID(pairingKey: key) != RelayAddress.authToken(pairingKey: key))
        #expect(RelayAddress.roomID(pairingKey: key).count == 22)
        // Fixed vectors: every platform must derive the same names, or devices and Mac never meet.
        #expect(RelayAddress.roomID(pairingKey: key) == "56FXSQJdVgihvTxVnz72qA")
        #expect(RelayAddress.authToken(pairingKey: key) == "kYG1U503LPYRFtSrmuAwkX2jkjN5DTmDBuoI7g9lNbE")
    }

    @Test("the relay URL carries the room and role, not the key or the password") func url() throws {
        let key = PairingPayload.makeKey()
        let url = try #require(RelayAddress.url(relay: URL(string: "wss://relay.example.dev/")!, pairingKey: key, role: .device))
        #expect(url.absoluteString == "wss://relay.example.dev/v1/room/\(RelayAddress.roomID(pairingKey: key))?role=device")
        #expect(!url.absoluteString.contains(RelayAddress.authToken(pairingKey: key)))
    }

    @Test("the pairing link can carry a relay, and refuses a non-websocket one") func link() throws {
        var payload = PairingPayload(hostName: "Mac", serviceName: "Kiln-1", key: PairingPayload.makeKey(), relay: URL(string: "wss://relay.example.dev"))
        #expect(PairingPayload(url: payload.url) == payload)
        payload.relay = nil
        #expect(PairingPayload(url: payload.url)?.relay == nil)
        let bad = payload.url.absoluteString + "&relay=https://evil.example"
        #expect(PairingPayload(url: URL(string: bad)!)?.relay == nil)
    }

    @Test("relay frames round trip and reject garbage") func frames() {
        let frame = RelayFrame.encode(.data, device: 0x01020304, payload: Data("hi".utf8))
        let decoded = RelayFrame.decode(frame)
        #expect(decoded?.kind == .data && decoded?.device == 0x01020304 && decoded?.payload == Data("hi".utf8))
        #expect(RelayFrame.decode(Data([9, 0, 0, 0, 1])) == nil)
        #expect(RelayFrame.decode(Data([1, 0])) == nil)
    }
}

@Suite("Direct addresses")
struct DirectAddressTests {
    @Test("direct addresses travel in the pairing link; anything that is not host:port is dropped") func direct() throws {
        let payload = PairingPayload(hostName: "Mac", serviceName: "Kiln-1", key: PairingPayload.makeKey(), direct: ["192.168.1.20:47900", "100.101.1.2:47900"])
        #expect(PairingPayload(url: payload.url)?.direct == ["192.168.1.20:47900", "100.101.1.2:47900"])
        let link = payload.url.absoluteString.replacingOccurrences(of: "direct=", with: "direct=evil.example/x:1,http://a:2,ok.local:99999,fine.local:1234,")
        #expect(PairingPayload(url: URL(string: link)!)?.direct.contains("fine.local:1234") == true)
        #expect(PairingPayload(url: URL(string: link)!)?.direct.contains { $0.contains("/") || $0.contains("http") || $0.hasSuffix(":99999") } == false)
    }
}
