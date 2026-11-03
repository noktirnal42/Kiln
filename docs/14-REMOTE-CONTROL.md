# Remote control: iOS and watchOS companions

Kiln on the Mac stays the only place work runs. The phone and the watch are remote controls: they read a conversation,
send messages (typed or spoken), and approve or deny the tool calls the agent asks about. Nothing executes on them.

## Contract

`Packages/KilnRemoteKit` is shared by the Mac app and both companions. It holds the message types (`RemoteCommand`,
`RemoteEvent`), pairing (`PairingPayload`) and the encrypted framing (`SecureChannel`). It has no networking; it is
tested with `swift test` inside the package.

## Pairing

1. On the Mac, Develop → MCP → Remote control shows a QR code (and a `kiln-remote://pair?...` link) with a fresh 256-bit key,
   the Mac's name and its Bonjour service name. The QR code contains a secret pairing key; scanning transfers it to the companion, and the iPhone can hand it to the watch through WatchConnectivity. Treat the code and link as credentials.
2. The device scans it and stores the key in its Keychain. A paired device can be revoked at the Mac, which deletes the key.
3. The watch pairs through its iPhone (the key is handed over WatchConnectivity); it may also reach the Mac directly.

## Connection

- Transport: WebSocket over TCP on the local network. The Mac advertises `_kiln-remote._tcp`. Off unless switched on.
- Client note: Network.framework only runs the WebSocket client protocol when the connection is made to a URL endpoint (`NWConnection(to: .url(ws://host:port), using: parameters)` with `NWProtocolWebSocket.Options` inserted first in `defaultProtocolStack.applicationProtocols`). With a Bonjour result, resolve it to host and port first.
- Handshake: the device sends 16 random bytes (client nonce); the Mac answers with 16 (server nonce). Both derive the session
  keys with `SecureChannel` (HKDF over the pairing key and both nonces, one key per direction).
- Every later frame is `SecureChannel.seal`ed (ChaCha20-Poly1305, strictly increasing counter). The first frame from the device
  is `hello`; if the Mac cannot open it, the key is wrong and the connection is dropped.
- Anyone on the network can connect to the socket and learn nothing without the key.

## What the remote can and cannot do

Can: list and open conversations, start a new one, send text, stop a reply, allow once or deny a pending approval.
Cannot: "always allow" (standing grants are made at the Mac), change settings, read files, run anything directly.

## Voice

The phone transcribes speech on the device (Speech framework) and sends text with `spoken: true`; replies are read aloud
with the system voice. The watch app is voice-first: raise the wrist, speak, hear the reply, tap to approve. watchOS has no
Speech framework, so the watch dictates through the system dictation sheet or hands the audio to the paired iPhone to transcribe.

## Mac side (in this repo, not in the package)

`Core/Remote` hosts the listener, the pairing screen, and the bridge from `ChatSession` and the approval queue to
`RemoteEvent`s. The companions only need the package and this document.

## Off the home network

A device tries, in this order: (1) the pairing code's `direct` addresses (`host:port`, the Mac's Wi-Fi, Ethernet and VPN
addresses; the Mac listens on port 47900 when it can), (2) Bonjour, (3) the relay named in the code's `relay` parameter.
Bonjour is unreliable on watchOS and does not cross a VPN, so direct addresses come first. Tailscale (or any VPN) works with
no relay: use the Mac's `100.x.y.z:47900`.

### Relay

`Relay/` is a small WebSocket relay (Cloudflare Worker with a Durable Object per room, or the same code on Node:
`npm run dev`). It needs no account for users and cannot read anything:

- Both sides derive a room name and a password from the pairing key (`RelayAddress`); the relay only learns the room name,
  checks the password (the first Mac to claim a room sets it) and forwards sealed frames.
- The Mac keeps one outbound connection to `wss://relay/v1/room/<room>?role=mac` (no port forwarding). Devices connect to
  `?role=device` with `Authorization: Bearer <password>` and speak the same protocol as on the LAN: 16-byte nonce, then
  `SecureChannel` frames. The Mac side wraps each device in a 5-byte frame header (`RelayFrame`).
- Limits: 256 KB per frame, 8 devices per room. If the Mac is offline a device is closed with 4503 and retries.
- Hosting: `cd Relay && npm install && npx wrangler login && npx wrangler deploy`, then set the relay URL in Kiln's Remote
  control card. The relay is not deployed by default.

### Away from the Mac

Approvals are designed to work while a device is connected. Real-device and real-Mac relay approval flows still require end-to-end validation. Unexpected standing approval decisions were observed during testing and remain under investigation. A phone or watch app that is closed or in the background cannot be woken
without Apple push notifications, which need an Apple push key; until then open the app to see and answer a pending approval.
The Mac is kept awake while remote control is on.

## Verification status (2026-11-03)

The iOS simulator connected directly to a real Mac. An integration candidate completed a physical watch voice round trip via an iPhone and Mac. A physical iPhone and Apple Watch each sent Deny and Allow once decisions, recorded by the Mac as remote answers. A Cloudflare relay deployed for the developer completed an encrypted handshake with the real Mac using the companion's Network.framework client on a computer. The physical phone subsequently timed out trying to reconnect through that relay, so phone cellular relay behavior remains unverified. Earlier unexpected standing approval decisions remain under investigation. See [the physical QA record](qa/2026-11-03-companion-voice.md).
