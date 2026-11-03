# Remote control: iOS and watchOS companions

Kiln on the Mac stays the only place work runs. The phone and the watch are remote controls: they read a conversation,
send messages (typed or spoken), and approve or deny the tool calls the agent asks about. Nothing executes on them.

## Contract

`Packages/KilnRemoteKit` is shared by the Mac app and both companions. It holds the message types (`RemoteCommand`,
`RemoteEvent`), pairing (`PairingPayload`) and the encrypted framing (`SecureChannel`). It has no networking; it is
tested with `swift test` inside the package.

## Pairing

1. On the Mac, Settings → Remote control shows a QR code (and a `kiln-remote://pair?...` link) with a fresh 256-bit key,
   the Mac's name and its Bonjour service name. The key is only ever on that screen; it is not sent over any network.
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

`Core/Remote` will host the listener, the pairing screen, and the bridge from `ChatSession` and the approval queue to
`RemoteEvent`s. The companions only need the package and this document.
