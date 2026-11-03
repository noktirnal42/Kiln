# Kiln Remote (iOS)

Companion for Kiln on the Mac. It reads a conversation, sends messages (typed or spoken), shows streamed replies and
lets you **Allow once / Deny** a tool call the agent asks about. Nothing runs on the phone. Wire contract:
`Packages/KilnRemoteKit`, protocol notes in `docs/14-REMOTE-CONTROL.md`. iOS 18+, Swift 6, bundle id `com.kiln.remote`.

## Build, test, run

```bash
cd Companion/iOS
xcodegen generate            # the .xcodeproj is not committed
xcodebuild test -project KilnRemote.xcodeproj -scheme KilnRemote -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Run on a phone with Xcode (team LH8KLB9N4F, automatic signing) or `xcodebuild ... -destination 'id=<udid>' -allowProvisioningUpdates`.

## Pairing

On the Mac: Kiln, Develop, MCP tab, Remote control, Start. Scan the QR with the app, or open / paste the
`kiln-remote://pair?...` link (`xcrun simctl openurl <udid> '<link>'` in the Simulator). The key is stored in the Keychain
(this-device-only). The link contains the key: do not commit or share it. Settings, Unpair removes it.
The pairing is also handed to the Apple Watch app over WatchConnectivity (Settings, Apple Watch row, "Send pairing to watch").

## Trying it without a Mac build

`cd FakeMac && swift run fakemac` starts a scripted stand-in Mac (also used by the unit tests): it prints a pairing link,
advertises over Bonjour and answers the real protocol. `FAKEMAC_RELAY=ws://127.0.0.1:8787 FAKEMAC_NO_BONJOUR=1` makes it
connect out to a Kiln relay as the Mac and hide from Bonjour, to exercise the relay path. Typing "approve" in a message triggers an approval request.

## What was verified

| Where | What |
| --- | --- |
| Unit tests with the fake Mac (10 tests, simulator) | handshake and framing, connect, streamed reply, approval allow, reconnect after a drop, wrong key goes to "pair again", Keychain round trip, spoken-text cleaning, event merging |
| Simulator against the real, notarized Kiln on this Mac | pairing by link, Bonjour discovery by service name, conversation list, open conversation with history and markdown, send a message and get the reply, approval card with the exact command, Allow once (command ran), Deny (recorded as `deny` in the Mac's approvals log) |
| Simulator over the Node relay (`Relay/`, local) with the fake Mac as the relay's Mac-side client | pairing link with `relay=` and no direct address or Bonjour: the app falls back to the relay, lists, sends a message, receives an approval card, Allow once, reply comes back. The real Mac's relay client was not exercised (the installed Kiln reads `remote.relayURL` only at launch) |
| Physical iPhone 16 Pro Max | installs and signs; paired to the real Mac, connects (after a first cold Bonjour miss, a retry succeeds), lists real conversations and shows history. Driven through iPhone Mirroring, which cannot type |
| Not verified | QR scanning with the camera; dictation, spoken replies, hands-free conversation and voice approvals (need a real microphone); local notification for an approval while backgrounded; typing and Allow/Deny tapped on the physical phone; the watch hand-off end to end; token-by-token streaming against the real Mac (replies arrived as whole messages) |

## Known gaps

- Off the home network: Settings has a "Mac address" field (host:port, e.g. a Tailscale address) that skips Bonjour, and a
  pairing link carrying `relay=` makes the app fall back to the Kiln relay when the Mac is not found on the network
  (`RelayAddress` in KilnRemoteKit). The typed-address path is unit tested against the fake Mac; the relay path is only
  tested for URL/header construction, not against a running relay. Needs the KilnRemoteKit relay changes from main.
- No push yet: approvals only reach the phone while the app is open or briefly backgrounded (iOS suspends the app and the
  local notification needs the socket alive). Push needs an Apple push key and a server.
- Bonjour is looked up per connect (10 s); the first lookup after a cold launch can miss and the app retries by itself.
- Hands-free declares the `audio` background mode so a conversation can continue with the screen off.
