# Physical companion voice test — 2026-11-03

A candidate build from the `codex/companion-integration` branch was installed on a physical iPhone 16 Pro Max and Apple Watch Series 9. With Kiln Remote open on the iPhone and remote control enabled in the Mac debug build, the watch connected through the iPhone. The user dictated a request for a sentence about the moon; the Mac conversation showed the request and a matching model reply, and the user confirmed that the answer appeared on both the iPhone and Mac and was spoken by the watch.

This is one foreground voice round trip using the integration candidate. It does not establish reliable reconnects, background operation, or real-device approval behavior. Connection indicators appeared connected while a Mac-side socket was not visible during setup. Unexpected standing approval decisions from earlier tests remain under investigation. No internet relay was used. See the [draft integration PR](https://github.com/noktirnal42/Kiln/pull/27) for its current status.

## Internet relay check

A Cloudflare Worker was deployed for the development account. A separate protocol client completed an authenticated, encrypted handshake with the running Mac through that Worker. The user then reported sending a Saturn question from the physical iPhone with Wi-Fi off and receiving the reply; the matching question and reply were observed in the Mac conversation. The Mac's remote card reported its internet relay connected. This was one foreground message round trip; broader reconnect and background behavior remain under test. The Worker is an operator-managed deployment, not a default hosted service for all Kiln users.
