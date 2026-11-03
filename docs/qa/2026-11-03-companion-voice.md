# Physical companion voice test — 2026-11-03

A candidate build from the `codex/companion-integration` branch was installed on a physical iPhone 16 Pro Max and Apple Watch Series 9. With Kiln Remote open on the iPhone and remote control enabled in the Mac debug build, the watch connected through the iPhone. The user dictated a request for a sentence about the moon; the Mac conversation showed the request and a matching model reply, and the user confirmed that the answer appeared on both the iPhone and Mac and was spoken by the watch.

This is one foreground voice round trip using the integration candidate. It does not establish reliable reconnects, background operation, or real-device approval behavior. Connection indicators appeared connected while a Mac-side socket was not visible during setup. Unexpected standing approval decisions from earlier tests remain under investigation. No internet relay was used. See the [draft integration PR](https://github.com/noktirnal42/Kiln/pull/27) for its current status.

## Internet relay check

A Cloudflare Worker was deployed for the development account. A separate protocol client completed an authenticated, encrypted handshake with the running Mac through that Worker. The user reported a Saturn question and reply on the physical iPhone after switching Wi-Fi off; the matching exchange appeared in the Mac conversation. Its actual network route was not independently confirmed. After the Mac restarted, the phone logged a relay connection attempt that timed out before its handshake. The Mac remote card reported its relay connected. Phone-to-Mac relay operation, reconnect and background behavior remain under test. The Worker is an operator-managed deployment, not a default hosted service for all Kiln users.

## Physical iPhone approvals

On the instrumented Mac build, the iPhone denied `echo kiln-deny-1103-a`. The same request was submitted again and allowed once; the Mac log recorded both decisions as remote, and the second run produced the echo output. Neither created a standing grant. Earlier unexpected standing grants from different tests predate decision-source logging; their origin remains unresolved. A physical watch also sent a Deny for `echo kiln watch deny` and an Allow once for `echo Kimm watch allow` through the phone. The Mac recorded both as remote decisions and showed that the allowed command ran; neither produced a standing grant. The watch dictation transcribed “Kiln” as “Kimm” in the second command.
