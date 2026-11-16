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

## Permissions for mail, contacts, messages, Slack, calendar, notes and drives (development builds)

These activities are in the current source and not in the published preview, and none has been tried with real data. Each asks macOS for its own permission, and Kiln does not ask for any of them until you press the matching Allow button.

- **Mail:** account passwords are stored in the macOS Keychain, never in preferences or logs. Kiln connects over TLS only (plain connections are accepted only for localhost). Sending needs an explicit Send in the window, or your approval of an agent's exact recipients and subject.
- **Contacts:** read-only. Kiln never creates, edits or deletes contacts.
- **Calendar and Reminders:** read, and add an event or reminder after approval. Nothing is edited or deleted.
- **Messages:** reading your conversations needs Full Disk Access for Kiln (macOS has no lighter permission for this), and sending needs Automation permission to control the Messages app. Apple documents no supported interface for either, so a macOS update can break them. Nothing is uploaded.
- **Slack:** a token you paste (a Slack bot or user token) is kept in the macOS Keychain, checked with Slack before it is saved, never shown again and never given to a model; Disconnect forgets it. Kiln posts only after you press Send or approve an agent's exact message, and refuses whole-channel mentions. A user token can read everything you can; a bot token only sees channels it was invited to.
- **Cloud Drives:** Kiln reads the folders the provider apps already sync to this Mac and never signs in to a cloud service or handles a token. Copies never overwrite, and saving into a drive needs your approval.
- **Notes:** reads and adds notes by asking the Notes app, which needs Automation permission for Notes. Kiln never edits or deletes notes and cannot read locked ones.
- **GitHub:** read-only, through the `gh` sign-in already on your Mac. Kiln never sees the token.
- **Notifications:** Kiln sends system notifications for approvals, finished runs and scheduled tasks, and the agent can send you one (`notify_user`, labelled "Kiln agent:", plain text, at most 5 in 10 minutes). Each kind can be turned off in Settings → Notifications. Kiln cannot read other apps' notifications. Reading whether a Focus is on is optional, asks macOS first, and is only a hint.
- **Links, Services and Sharing:** `kiln://ask` and `kiln://share` links, the Services entry and the Share extension only add text to the message box, after anything you are typing, and never send it: a link can be opened by any web page or app. The menu-bar field, which you type into yourself, is the only thing that sends at once, and tool approvals still appear in Kiln.
- **Spotlight:** off by default. If you choose Titles only, or Titles and text (secrets redacted, tool output skipped), Kiln adds conversations to the system Spotlight index; choosing Off removes everything it added.
- **Untrusted text:** mail, texts, notes, calendar entries and GitHub text come from other people. Kiln labels them untrusted for agents, and sending or creating anything still needs your approval.

## Privacy do's

- Keep keys in Settings; never in source, screenshots or issues.
- Redact keys, tokens, private prompts and personal paths from bug reports.
- Do not share the MCP token file, the pairing code, or your application-data folder.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for the repository; do not post exploit details publicly. See `SECURITY.md`.

---

**Verified status.** The sandbox decision, approval logging, MCP 401 behavior, audit Verify now and the remote protocol are documented and were exercised as described in `docs/11-CURRENT-STATE.md` and `docs/14-REMOTE-CONTROL.md`; physical iPhone and watch tests produced Allow once and Deny decisions. **Not checked:** an independent security review (none has been done), reconnect reliability of the relay, and an earlier report of unexpected standing approvals that remains under investigation.
