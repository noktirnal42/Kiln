# Security and Privacy

Kiln can run commands, edit files, call providers, inspect binaries and serve an authenticated local MCP endpoint. This page says what protects you, and where the protection ends.

## What protects you

- **Approvals.** Reads are free; writes, commands and network calls ask. Modes and logging: [[Agent and Approvals]].
- **Policy gates and behavior monitor.** Two policy gates, a behavior monitor and tripwires surround every agent and swarm tool call; a monitor hold is never answered by a mode.
- **Audit chain.** Agent runs, decisions and tool results are stored in a tamper-evident hash chain. **Audit → Verify now** recomputes every hash and compares the head; the chain can be exported. Streamed text content is not written to the audit log.
- **Path containment.** File tools are confined to the project root.
- **Keychain.** Provider keys are stored in the macOS Keychain and sent only to their provider.
- **Loopback MCP.** The MCP server listens on loopback only, with a bearer token; external calls are audited and non-reads wait for approval.
- **Untrusted content.** Page text, tool output, imported binaries and model output are treated as data. Browser tools refuse credential fields.
- **Remote control.** Frames between Mac and companions are encrypted (ChaCha20-Poly1305) with a pairing key; replay, reordering and tampering are rejected. A phone or watch can allow once or deny; it cannot grant standing access or change settings.

## Where protection ends

- **Kiln is not sandboxed.** Since 2026-11-02 the app is not App Sandboxed, so the agent can run real git, package managers and shells in any folder. The hardened runtime and notarization still apply (and mean it cannot be on the Mac App Store). `run_command` is **not** confined to the project: a command can touch anything your user account can. Approvals are the boundary, so read each command before allowing it, and treat Bypass as dangerous.
- **Redaction is heuristic.** A secret split across streamed chunks can be briefly visible before it is replaced.
- **A mode is not containment.** Neither an approval gate, a local model nor a heuristic redaction is a complete privacy or containment guarantee.
- **Browsing exposes what is on the page.** Page text and screenshots can contain sensitive data; sign in yourself and do not paste credentials into prompts.
- **Pairing key is a credential.** The QR code or link contains it, and one key is shared by all paired devices, so unpairing is all-or-nothing.
- **Push alerts.** If you enable approval alerts, the tool name, access level and (unless switched off) the first 80 characters of the command pass through Apple's push service via your relay. The relay stores no device tokens.

## What leaves your Mac

Provider requests send prompts, selected context and tool results to the provider you chose. Local providers (Ollama, MLX, Apple Foundation Models on-device) keep them on the Mac. Kiln itself has no account and no telemetry service described in the repository documents.

## Privacy do's

- Keep keys in Settings; never in source, screenshots or issues.
- Redact keys, tokens, private prompts and personal paths from bug reports.
- Do not share the MCP token file, the pairing code, or your application-data folder.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for the repository; do not post exploit details publicly. See `SECURITY.md`.

---

**Verified status.** The sandbox decision, approval logging, MCP 401 behavior, audit Verify now and the remote protocol are documented and were exercised as described in `docs/11-CURRENT-STATE.md` and `docs/14-REMOTE-CONTROL.md`; physical iPhone and watch tests produced Allow once and Deny decisions. **Not checked:** an independent security review (none has been done), reconnect reliability of the relay, and an earlier report of unexpected standing approvals that remains under investigation.
