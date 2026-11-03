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

## Pairing

The Mac shows a `kiln-remote://pair?...` link (Settings, Remote control). The iPhone app forwards it to the watch with
`updateApplicationContext(["kilnPairing": url])` and the watch keeps it in its Keychain. For testing without the iPhone
hand-off, a Debug build accepts `-pair <link>` as a launch argument (never commit a real link).

```bash
xcrun devicectl device process launch --device <watch udid> com.kiln.remote.watchkitapp -pair "$(cat pair-link.txt)"
```

## Screens

`-demo reply|approval|unpaired|offline` seeds the UI for screenshots without the network. See `docs/screenshots`.

## Verified

- **Fake Mac server, simulator (watchOS 27):** `xcodebuild test` passes (11 tests): real loopback WebSocket, nonce handshake,
  SecureChannel framing, spoken send and cleaned reply, approvals (allow once, resolved at the Mac), wrong key, revoked pairing,
  Keychain, WatchConnectivity message parsing.
- **Simulator screenshots:** reply, approval, unpaired, offline.
- **Real watch (Series 9):** the app builds, signs, installs and launches. The Mac advertises `_kiln-remote._tcp`.

## Not verified

- A connection from the real watch to the real Mac: the watch screen was not observed and no watch connection showed up on the
  Mac's socket. watchOS may not browse the LAN while it reaches the network through the iPhone over Bluetooth; it needs the
  watch's own Wi-Fi on the Mac's network.
- Dictation sheet in a SwiftUI-lifecycle app, speaker output, haptics on device.
- The iPhone to watch pairing hand-off (the iOS app).

## Known gaps

Smart Stack widget for pending approvals; iPhone audio hand-off transcriber (protocol `SpeechTranscribing` is ready).
