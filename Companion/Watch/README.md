# Kiln for Apple Watch

Voice-first remote for Kiln on the Mac. Talk, hear the reply, approve tool calls. Nothing runs on the watch.
Wire contract: `Packages/KilnRemoteKit` and `docs/14-REMOTE-CONTROL.md` (reused, not reimplemented).

```bash
cd Companion/Watch && xcodegen generate
xcodebuild -project KilnWatch.xcodeproj -scheme KilnWatch -destination 'id=<watch simulator udid>' test
```

## Layout

- `Sources/Core/RemoteClient.swift` nonce handshake + `SecureChannel` framing (actor).
- `Sources/Core/Transport.swift` `RemoteTransport` protocol, `NWTransport` (WebSocket via Network.framework URL endpoint), `BonjourResolver` (`_kiln-remote._tcp` → `ws://host:port`).
- `Sources/Core/RemoteSession.swift` observable state for the UI: link, talk state, latest reply, pending approvals.
- `Sources/Core/Devices.swift` `SpeechTranscribing` (system dictation now; an iPhone hand-off source conforms to the same protocol), `Speaking` (AVSpeechSynthesizer, text cleaned by `SpokenText`), `Haptics`.
- `Sources/Core/PairingStore.swift` Keychain storage of the pairing link. `PhoneLink.swift` WatchConnectivity receiver.
- `Tests/FakeMacServer.swift` in-process WebSocket server speaking the documented protocol.

## Contract for the iPhone app (WatchConnectivity)

Send the pairing with `WCSession.default.updateApplicationContext(["kilnPairing": payload.url.absoluteString])`.
An empty string or a missing key revokes the pairing on the watch.

## Screens

`-demo reply|approval|unpaired|offline` launch argument seeds the UI for screenshots (no network). See `docs/screenshots`.

## Not done

Smart Stack widget for pending approvals (stretch goal); iPhone audio hand-off transcriber (protocol is ready).
