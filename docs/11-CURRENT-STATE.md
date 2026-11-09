# Kiln — current state (2026-11-03)

Read this first. It says what exists, how it was checked, how to build and ship it, and what is still open.
Older docs describe the plan; this describes the app.

## Build, test, sign, notarize

- **`project.yml` is the source of truth.** `Kiln.xcodeproj` is generated (`xcodegen generate`) and gitignored.
  Edits made in Xcode's Signing & Capabilities screen are lost on the next generate (and once wrote a stray
  `CODE_SIGN_IDENTITY[sdk=macosx*] = "-"` that made archives ad-hoc signed — "No Team Found in Archive").
  Change signing in `project.yml`.
- Signing: automatic, team `LH8KLB9N4F`, Apple Development identity; Release archives are re-signed with
  Developer ID at export. `xcodeVersion: 2710` plus the recommended build settings keep Xcode's
  "Update to recommended settings" prompt away. Bump it when moving to a newer Xcode.
- Tests: `xcodebuild test -project Kiln.xcodeproj -scheme Kiln -destination 'platform=macOS'` (592 tests as of 2026-11-03, including the opt-in live Ghidra test; no
  warnings except four from mlx-swift's Metal kernels, which cannot be silenced from this project; mlx-swift 0.32
  is worse, 76 warnings).
- **Notarize from Xcode:** Product → Archive, Organizer → Distribute App → Direct Distribution → Export
  Notarized App. **Or from the shell:** archive, then `xcodebuild -exportArchive … destination=upload`, then
  `xcodebuild -exportNotarizedApp` (retry until Apple finishes; both use the Apple ID signed into Xcode).
  `Scripts/notarize.sh` is the `notarytool` route and needs a one-time `xcrun notarytool store-credentials kiln-notary`
  (not set up on this Mac as of 2026-11-01; the Xcode Apple ID route above is what shipped the current build).
  Export options used: `method developer-id`, `teamID LH8KLB9N4F`, `destination upload`, `signingStyle automatic`;
  `-exportNotarizedApp` answers "archive is processing" until Apple finishes, so retry.
- This Mac has two "Developer ID Application: Jeremy McVay" certificates; the older (issued 2026-04-05) can be
  deleted. Xcode picks one itself; `codesign --sign "<name>"` reports it ambiguous, so use the hash.
- Keychain: a change of signing identity (Apple Development ↔ Developer ID) makes macOS ask for the login password
  once per stored key. Click Always Allow; staying on one identity avoids it.

## Shape of the app

One window, one sidebar, one conversation.

- **Sidebar** (`UI/Workstation/WorkstationSidebar.swift`): New chat, project switcher, chat history grouped by day
  (auto-titled from the first message), then the tools: Swarm, Develop, Analyze, Lab, Audit. The Kiln logo opens
  Overview (the old Home). ⌘1–⌘7 and ⌘K still work.
- **Shared activity chrome** (`UI/DesignSystem/ActivityChrome.swift`, added in the 2026-11-09 UI pass): every activity (Develop, Analyze, Lab,
  Swarm, Audit) opens with `SSActivityHeader` (40 pt: name, optional `SSTabStrip`, trailing actions) and uses `SSPaneHeader` (28 pt) over its panes,
  `SSCodeBlock` for listings and `SSEmptyState` for empty panes. Activities never use the window toolbar or `.navigationTitle`, so the title bar
  stays "Kiln — <Activity>" and the same height on every screen. The tab strip shows full labels when they fit, then keeps only the selected label,
  then scrolls. **Analyze** is now a Ghidra-style browser: project list (collapses below ~820 pt; header button brings it back) | function list with
  filter | decompiler and listing panes (side by side from 640 pt, stacked below), callers/callees as links, annotations in a popover, engines in one
  Analyze menu, engine status as one quiet line. QA screenshots: `docs/qa/ui-rework/`.
- **Develop → Editor** (`UI/Workstation/EditorView.swift`, `Core/Editor/*`): file navigator (new / rename / trash, Find in Project, Changes list with
  discard), tabs and a split pane, native text editing (system undo, find bar, line numbers, auto-indent, regex syntax colouring, bracket matching,
  soft wrap, font/tab settings), Open Quickly (⌘P), go to line (⌘L), save (⌘S / ⇧⌘S). Documents live in `AppModel.editor`, so unsaved edits survive
  switching tools; recovery copies are written to `Application Support/Kiln/EditorRecovery` and offered back, and quitting with unsaved edits asks first. Files
  changed on disk by an agent, git or another editor reload when clean and raise a Reload / Keep mine / Overwrite banner when edited; binary, over 2 MB and
  unreadable files are refused with a reason. **Language server:** sourcekit-lsp (Swift and C-family files) gives live diagnostics as underlines and in Problems,
  ⌘-click go to definition and ⌥Esc completion; it degrades to nothing when `xcrun sourcekit-lsp` is unavailable. **Git:** gutter markers against HEAD, "Revert
  Change" at the caret. **Build / Test / Run** (⌘B, ⌘U, ⌘R): scheme and configuration pickers from `xcodebuild -list` / `swift package describe` (remembered per
  project), streamed output, `file:line:col: error:` and Swift Testing issues as clickable problems, a test list with per-test results and "Run only this test", and
  Run for packages and Xcode apps; "Ask the agent to fix the errors" drafts a prompt. **Debugger:** Debug (⌥⌘R) builds the selected target and launches it under LLDB.
  Toggle file/line breakpoints from the gutter or at the caret (⌘\); continue, pause, step over/into/out, inspect the stack and locals, and read program output.
  Breakpoints persist per project. Switching projects and quitting end the previous debugger; build actions save only current-project documents.
  The debugger panel switches to Stack / Variables / Console tabs in narrow editor panes. **Not in Kiln:** debugger attach, conditional breakpoints, watches,
  SwiftUI previews, code folding, multi-cursor, completion/diagnostics for languages other than Swift/C-family, and stage-hunk / blame UI in the editor.
- **Project** = the folder the agent works in. `WorkspaceStore` keeps a security-scoped bookmark per recent folder;
  without it the sandbox forgets the folder on every relaunch.
- **Composer** (model, Agent toggle, agent profile) is shared by the Agent view and the panel beside every tool.
  The empty chat asks "What should we work on in <project>?" with starter prompts that change with the tool
  (`StarterPrompts`).
- The agent panel hides itself below 1240pt window width instead of overflowing.
- **Chat layout** (`Modules/Chat/MessageBubble.swift`, `ChatRootView.swift`): user messages are a right-aligned soft
  bubble, assistant replies are plain full-width markdown, actions (copy, regenerate, fork, delete) appear on hover,
  thinking text streams into a collapsible block, and the column is capped at 760pt. Return sends; ⌘/⇧/⌥-Return
  inserts a newline at the caret (`ComposerView.insertNewline`, via `NSTextView.insertText`).
- **Streaming:** `ChatChunk.reasoning` carries `reasoning_content` / `reasoning` deltas; the agent loop emits
  `AgentEvent.reasoningDelta` (not audited, like text deltas). An empty reply is reported instead of silently ending.
- **Never run the model-store scan on the Swift cooperative pool.** `UniversalModelStore.installed()` stats every
  weight file; on the external drive that takes minutes and, run from async code, starved every other task (chat
  streams never started, the UI showed "Working" forever). Use `installedOffPool()` from async code.
- Settings (⌘,): provider API keys (Keychain, last four shown, each with a "Get an API key" link) and the
  Local model store.

## What the agent can do

- **Agent mode** runs `AgentOrchestrator` (policy gates A and B, approvals, behavior monitor, tamper-evident audit).
  Profiles: Research Assistant (read-only), Coding Agent, Workstation Agent (adds `re_*` and `lab_*`).
- **Context management** (`Core/Agent/ContextCompactor.swift`, `ChatSession`): before each model call, if the estimate
  (chars/3.5 + tool-call arguments) passes 70% of window − `maxTokens` − tool-schema size, (a) older tool results become
  `[result cleared: <tool>, N chars]` stubs (newest 4 kept), (b) if still over, the older part is summarised by the
  model into one message (system messages and the recent tail stay verbatim, a tool call never separated from its
  results), (c) if the summary call fails the oldest part is dropped with an honest note. `run(contextWindow:)` nil = off.
  `AgentEvent.contextCompacted` / `.contextMeasured`. `ChatSession` keeps per conversation the summary + covered-message
  count (UserDefaults key `chat.compaction.v1`; off under tests) and rebuilds history as [summary] + later messages.
  The run limit is 200 steps and **pauses** ("Paused after N steps; say continue…") instead of erroring.
  UI: context meter + compact button in the composer bar (tooltip has detail), `/compact`, "Context compacted (A → B
  tokens)" notes in the thread, and a finished run's tool calls collapsed to one line ("Ran 4 commands · edited 2 files ·
  read 6 files", expandable; stored with the reply as name + arguments, results are not kept); live rows are compact.
  Test aid: launch with `-agent.contextWindowOverride 4000`. **Not verified:** none of the UI has been seen in the running
  app (computer-use access was declined), compaction quality with a real model, tool calls from earlier turns are still
  not replayed to the model (only the summary and text). Test suite: all pass except the relay test
  (`a device reaches the Mac only through the relay…`, times out here; unrelated).
- **Approvals:** reads run freely; writes, commands and network calls open the approval sheet. "Always Allow"
  creates a standing grant (revocable under Approvals). `ApprovalCenter` is a Combine `ObservableObject`: views must
  observe it directly (`ApprovalSheetHost`), reading it through `AppModel` never re-renders.
- **Swarm:** planner (JSON plan or fixed research → implement → review fallback), parallel workers over the
  coordination bus, blockers reported not retried, every worker call through the same gates.
- **Kiln as an MCP server:** Develop → MCP → Start. Loopback only, bearer token in
  `Application Support/Kiln/mcp-server.json` (0600). 34 tools incl. `re_*`, `lab_*`. External calls run as
  "External: <client>" and are audited; reads are free, anything else waits for approval in Kiln.
- **Shared tool configuration (no duplicates).** Kiln reads, never copies, what Claude Code, Codex and OpenCode already
  have: MCP servers from `~/.claude.json`, `~/.codex/config.toml` and `~/.config/opencode/opencode.json`
  (`Core/Integrations/ToolSourceImporter.swift`) and skills (`SKILL.md` folders) from `~/.claude/skills`, `~/.codex/skills`,
  `~/.config/opencode/skills`, OpenCode's `skills.paths` and installed Claude plugins (`SkillCatalog`). A server
  that launches the same command (or URL) is one server however each tool names it; same name with a different command is
  kept as `name-<tool>`. Environment values (API keys) stay in memory; every imported server still needs
  "Approve & Connect" in Develop → MCP. Agents get `list_skills` / `read_skill`. **Not imported:** OpenCode's JS plugins
  (`plugins`), Claude Code hooks and slash commands, and MCP servers bundled inside Claude plugins.
- **Ghidra:** Kiln discovers existing stable releases in `~/Applications` and `/Applications`, or a valid `GHIDRA_HOME`, and bundles its export script.
  Analyze → Analyze with Ghidra and `re_analyze_binary` call the same bounded service; the agent action requires execution approval. Reanalysis preserves annotations
  and analyst signatures, checks project revision and binary hash, and rejects concurrent runs. Ghidra 12.1.4 + Java 21 produced real persisted pseudocode here.
- **Reverse engineering:** import via `re_import_binary` (returns `project_id`; every other `re_*` tool takes it;
  the analysis id is accepted too). Native `otool` engine; Ghidra optional.
- **Package downloader (Analyze → Download…, `re_search_packages`, `re_download_package`):** one code path
  (`Core/ReverseEngineering/PackageIntake.swift`) serves the sheet, the in-app agent and the MCP server. Aptoide search returns
  direct APK links with the store's MD5, which the download verifies; Apple, Google Play, APKPure and Amazon only open a
  store listing (Kiln does not sign in to any store). Only http(s) is accepted, a non-2xx answer is an error, and
  `re_download_package` is a write, so it needs approval like `edit_file`. Files land in
  `Application Support/Kiln/ReverseEngineering/Downloads` and are analyzed, never run.
- **Model Lab:** `lab_hardware`, `lab_list_experiments`, `lab_list_datasets`, Hugging Face search tools.

## Providers (all verified with real calls, 2026-11-01)

| Provider | Chat | Tool use | Notes |
|---|---|---|---|
| Apple Foundation | yes | no | on-device |
| Ollama (local) | yes | yes | only models the running server knows; your drive's `Ollama/models` is used only if the server is started with `OLLAMA_MODELS` pointing there |
| Ollama Cloud | yes | yes | gemma4:31b ok; some models (glm-5.2) need paid credits and say so |
| NVIDIA NIM | yes | yes | GLM 5.3 Flash is the reference model for QA |
| OpenRouter | yes | yes | free models come and go; `openrouter/auto` works |
| Custom endpoint | yes | yes | any OpenAI-compatible URL (Settings); tested against Ollama's `/v1` |
| MLX (local) | yes | no | models from the shared Hugging Face cache; first load ~45 s from a drive |

**Catalog ids are `<provider>-<model>`.** `ModelRegistry` hands each provider the bare model name; forgetting this
was a 404 for every hosted model. Reasoning is turned off for models the catalog says cannot reason (Ollama
rejects `think` otherwise). Replies that are exactly one JSON call to an offered tool are accepted as that call
(small local models write calls as text).

## Local model store ("universal model store")

Hugging Face cache layout (`models--org--repo/snapshots/…`) on the drive. Kiln is sandboxed, so choose the folder
once in Settings → Local model store (the `hub` folder, or `huggingface` above it); a bookmark keeps access.
Only language models (`architectures` ending in `CausalLM`) are listed; speech, audio and vision-only repos in the
same cache are skipped (9 of 32 in this user's store). Lab → Models also lists them; Playground reads them from
disk instead of downloading.

## Verification status

Verified with the real app or real models: provider matrix above; agent fixing a failing test (listed folder, read
files, ran tests, edited, re-ran); swarm writing and reviewing a README whose examples were then run and matched;
RE import and string search (headless and in the Analyze tab); MCP server (401 without token, 34 tools, real
`lab_hardware`, audited as an external run); Audit "Verify now" intact; approval sheet and standing grants; Lab
tabs, HF dataset search, Apple Playground, Terminal, command palette; MLX chat from the drive store.

**Not verified:** Return / ⌘Return with real keystrokes (the automation used here sends Return through accessibility, so only the code path is reviewed); a full streamed reply from a hosted reasoning model after the starvation fix (NVIDIA gemma-4-31b sent a request and returned no headers for 25 s+, cause unknown, probably the provider's queue);  the unified sidebar after the last commit was seen only in a development build, not the
notarized one; the agent panel on a window narrower than 1240pt; Git and Search tabs in Develop; Analyze with a
freshly imported binary through the file picker (the picker cannot be driven from outside); Ghidra; GGUF export;
LM Studio's own model folder is not scanned.

## Live QA tests

Opt-in, they spend network calls: `TEST_RUNNER_KILN_LIVE=1 xcodebuild test … -only-testing:KilnTests/LiveQATests`
(also `LiveChatTests`, `LiveHostedModelTests`). `LiveMLXStoreTests` must run unsandboxed
(`CODE_SIGN_ENTITLEMENTS=` empty) because the sandboxed host cannot read an external drive. They use the keys saved
in Settings; none are read or printed by the tests.

## Voice and remote control (2026-11-03)

- **Voice in the Mac app.** The composer has a mic (dictate into the message), a speaker (read finished replies aloud) and a
  conversation button (listen, send when you pause, speak the reply, listen again). Speech recognition is Apple's, on this
  Mac when the model is installed; speech output is the best installed system voice. Code and markdown are not read out
  (`Core/Voice/SpokenText.swift`, tested). The first use asks macOS for Microphone and Speech Recognition permission.
  Not yet: speaking while the reply is still streaming, an MLX neural voice (Kokoro is cached on the dev Mac), wake word.
- **Remote control.** Develop → MCP has a Remote control card: Start shows a QR pairing code. A paired iPhone or Apple Watch
  on the same network can list and open conversations, send text or dictated messages, stop a reply, and allow once or deny
  an approval. It cannot grant standing access or change settings. Frames are ChaCha20-Poly1305 encrypted with a pairing key shared with paired companions; replay, reordering and tampering are rejected. Protocol and threat model:
  `docs/14-REMOTE-CONTROL.md`; shared code: `Packages/KilnRemoteKit`; Mac side: `Core/Remote`.
- **Approval alerts through Apple push (verified 2026-11-03).** A phone registers its push token with the Mac; an approval unanswered for about 4 seconds is pushed through the relay (which holds the APNs key as a Cloudflare secret) to the phone, and the notification mirrors to the watch. A real Ask-mode approval was answered from the notification with the phone locked: the approvals log recorded `via: remote` after a 39 s wait. See `docs/14-REMOTE-CONTROL.md` for the one-time key and secrets setup.
- **Companion apps** live in `Companion/iOS` and `Companion/Watch` (own XcodeGen projects, see their READMEs).
- **Verified:** the wire contract and Mac bridge by unit tests, the Mac server over a real local socket (right key works,
  wrong key is dropped before reaching the chat), and the iOS app in the simulator against the real notarized Kiln
  (conversations listed, message sent, a real approval allowed from the app and the command ran).
  **Not verified:** a physical iPhone and Apple Watch end to end, voice with a real microphone, pairing through the camera.
- **Known limits:** one pairing key is shared by all devices, so unpairing is all-or-nothing; the link is local network
  across devices. An operator-deployed relay completed an encrypted handshake with the running Mac, and a relay-only physical iPhone carried a watch message through it; an earlier reconnect timed out. Physical iPhone and watch tests each produced remote Deny and Allow once decisions; broader coverage remains open. Each remote message goes into the one open conversation on the Mac. Earlier unexpected standing approval decisions remain under investigation.
- **Model Lab tools added:** `lab_start_lora` (verified end to end: SmolLM-135M, 20 iterations, completed) and
  `lab_start_distillation` (verified: Qwen2.5-3B teacher into SmolLM-135M, loss 0.83 training / 1.88 validation), both
  approval-gated with a download policy. Agents polling `lab_get_experiment` can exhaust their tool rounds on a slow job.
- **Editor:** code folding (gutter chevrons, ⌘⌥[ and ⌘⌥], checked in the running app), ⌘D multi-cursor, drag-reorder tabs,
  and VoiceOver access to the gutter (breakpoints, folds, diff and execution markers).

## Approval modes: Ask, Auto, Bypass (2026-11-03)

The composer's mode bar has a **Permissions** menu. **Ask** (default) waits for you on every approval. **Auto** approves
routine calls for you (non-destructive, inside the project, not flagged by the execution policy, not admin tier); anything
destructive, outside scope, new to the network, risky-shell or admin still asks. **Bypass** (red, confirmed first) approves
everything except hard policy blocks and behavior-monitor holds. A mode answers once: it never creates a standing grant,
never answers a monitor hold, and resets to Ask whenever Kiln launches. Each decision it makes is written to
`approvals.jsonl` with `via: auto-mode` or `bypass-mode`, mode changes go to the audit chain, and every human answer now
records `via` (mouse, keyboard, programmatic, remote) and how long it waited. Unit-tested policy and logging; Bypass was exercised
by a real agent run on 2026-11-03 (computer-use calls approved with `via: bypass-mode`, no waits). Auto has not been run by a real agent yet. This is separate from macOS permissions (Accessibility, microphone), which a mode
cannot grant. Codex's experimental native computer-use and MCP agent tools are merged (`Core/Tools/ComputerUseTool.swift`): off until enabled in Settings, macOS Accessibility required, each call asks in Ask and Auto, Bypass skips the question. Actions: `list_apps`, `open_app`, `read`, `inspect` (query, max_elements, max_depth), `press`, `set_value`. Verified 2026-11-03: Kiln's own agent opened Messages and read the latest message from a named contact. Lesson: macOS keeps a stale "Kiln: ON" Accessibility entry for an earlier build with a different signature; remove it and add the installed app (Settings shows whether this copy is trusted).

## Known limits and ideas

- **Kiln is no longer sandboxed (decided 2026-11-02).** The agent must be able to run real git, package managers and
  shells in any folder to replace a terminal coding tool such as OpenCode. `Config/Entitlements.plist` is empty; the
  hardened runtime and notarization still apply. The safety layer is the approval sheet, policy gates A/B, the
  behavior monitor, tripwires and the audit chain. File tools stay confined to the project root (`WorkspacePathResolver`);
  `run_command` is not, so a command can touch anything the user can.
- Data moved from `~/Library/Containers/com.kiln.app/Data/Library/…` to the normal `~/Library/Application Support`.
  `LegacyContainerMigration` copies Kiln/ModelLab/ReverseEngineering and preferences once at launch (a development
  copy that is older is kept as `<name>.before-container-migration`; the container is never deleted).
- Agent mode is on by default with the Workstation Agent profile (it was off, then read-only Research Assistant).
- `ShellRunner` used to crash the app (`NSTask terminationStatus` on a still-running task) when Stop was pressed during a hung command; fixed 2026-11-02 with tests.
- Custom endpoint with a 3B model returned "None" after a tool call; the same model is fine on the native Ollama route.
- `Packages/ModelLabCore/Package.resolved` is rewritten by every build; never commit it.
- Ideas, in order of value: hand context from a tool to the agent (selected function, dataset) instead of generic
  starter prompts; LM Studio and Ollama-directory scanning; a first-run flow (project, one model, one key); consistent
  header chrome for Lab and Analyze, which still carry their own toolbars; auto-title with a model instead of the
  first line; show reasoning/tool calls inline in the thread like the reference apps.
