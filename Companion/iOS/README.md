# Kiln Remote (iOS)

Companion for Kiln on the Mac; see `docs/14-REMOTE-CONTROL.md`. Reuses `Packages/KilnRemoteKit` unchanged.

- `xcodegen generate`, then build/test scheme `KilnRemote` (iOS 18+).
- `FakeMac/`: a stand-in Mac speaking the protocol. `cd FakeMac && swift run fakemac` prints a pairing link and advertises over Bonjour; open it on the phone/simulator (`xcrun simctl openurl <udid> '<link>'`). Typing "approve" in a message triggers an approval request.
