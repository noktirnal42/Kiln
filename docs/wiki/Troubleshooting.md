# Troubleshooting

Before reporting, record the commit or build, macOS and Xcode versions, hardware, and the exact workflow. Remove keys, tokens, private prompts and personal file paths first. See also `SUPPORT.md` and `docs/KNOWN-ISSUES.md`.

## Models and chat

**The app cannot find a model.** Check Settings, the provider's account and credits, and that a local server is running. A catalog entry does not guarantee your account can use it.

**A small model prints JSON or never finishes an agent task.** Plain chat and tool use differ. Try a stronger tool-capable model, keep the task small, and inspect the tool records, not only the prose.

**"No response after 90 s…".** Some hosted models queue for a long time before sending headers. Retry or pick another model.

**The model picker is slow.** The local store scan stats every weight file; on an external drive it takes minutes. It is cached for 120 seconds.

**MLX is available but a run fails.** Availability means the runtime is linked. The model, download, memory and Metal runtime must also work. Report the exact operation and error.

## Agent and approvals

**"To save context, N of M tools are loaded".** The model's context window is too small for all 200-plus tool definitions, so a run starts with the basics and the agent loads the others by asking. If a model never asks, it will not use the module tools (mail, calendar, maps and so on); pick a model with a larger window. The context meter reads lower during a run than when idle because idle also counts the system prompt and loaded tools.

**A message does not send in Messages.** The red text under the thread is the error. A permission refusal means Kiln needs Automation permission for Messages (System Settings, Privacy & Security, Automation); an "unknown" script error is usually a macOS change, so please report it with the text. Reading needs Full Disk Access.

**A run stopped with "Paused after N steps".** The limit is 200 steps; say "continue".

**The agent panel disappeared.** It hides below 1240 pt window width.

**Approvals never reach the phone.** Approval alerts need a relay you host and an Apple push key; with the app closed, an iPhone cannot hold a connection. See `docs/14-REMOTE-CONTROL.md`.

**Computer use does nothing.** It must be enabled in Settings and Kiln needs macOS Accessibility. macOS can keep a stale "Kiln: ON" entry for an earlier build signed differently; remove it and add the installed app. Settings shows whether this copy is trusted.

## Analyze

**Ghidra is unavailable.** Install a stable release in `~/Applications` or `/Applications` (or set `GHIDRA_HOME`) and restart Kiln. Ghidra 11 needs JDK 21 and fails under newer JDKs; Kiln pins 21 when installed. A bad compiled-script bundle from an earlier run can be deleted from `~/Library/ghidra/<version>/osgi/compiled-bundles`.

## Build

**"No Team Found in Archive" or ad-hoc signing.** Edits in Xcode's Signing & Capabilities are lost on the next `xcodegen generate` and can leave a stray identity setting; change signing in `project.yml`.

**The old icon or behavior still shows.** Confirm which `.app` is running; a build does not replace other copies.

**Concurrent builds fail or stall.** Run one build at a time in a DerivedData folder.

## Devices and Browser

**Setup needed card.** Install Xcode command-line tools (for `simctl`) or the Android SDK (for `adb` and `emulator`); Kiln never downloads them.

**Tapping an iPhone simulator does nothing.** Not possible through `simctl`; use URL open and launch.

**A website will not let me use a passkey or autofill.** Not verified in Kiln; see [[Browser]].

**A streaming or cloud-gaming site says the browser is unsupported.** Kiln identifies as Safari, which most of them accept. Some check more than the browser name, and voice chat in a page needs a microphone prompt the browser does not have yet; tell us which service and the exact message.

## Still stuck

Open an issue with a minimal reproduction, or ask in Discussions. For security concerns follow [[Security and Privacy]].

---

**Verified status.** Each item is taken from `SUPPORT.md`, `docs/KNOWN-ISSUES.md`, `docs/11-CURRENT-STATE.md` and `docs/GHIDRA.md`. **Not checked:** reproducing each failure in this documentation pass.
