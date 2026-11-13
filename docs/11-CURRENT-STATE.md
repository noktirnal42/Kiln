# Kiln — current state (updated 2026-11-12)

> **Next session: read [HANDOFF-CODEX-2026-11-10.md](HANDOFF-CODEX-2026-11-10.md) first** (how to build, test and check the UI, and the pitfalls), then [21-EVERYTHING-APP-ROADMAP.md](21-EVERYTHING-APP-ROADMAP.md), which has the owner's priority order with per-item status.

Read this first. It says what exists, how it was checked, how to build and ship it, and what is still open.
Older docs describe the plan; this describes the app. Sections dated before 2026-11-12 are kept as the record of when a thing was verified; where they disagree with the section below, the section below wins.

## State on 2026-11-12

- **Branches.** Everything described here is merged to `main` (pull requests through #38; GitHub still lists #38 as closed because its merge call returned a 502, but its merge commit `4b647e8` is on `main`). The published preview, `v0.1.1` (2026-11-03), is far behind `main`. Builds from `main` report version **0.2.0 (3)** (`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, set when the 0.2 preview was prepared); no 0.2 release exists yet, so the version in Settings → About and the version of the download differ on purpose.
- **Activities.** 22 are registered in `Core/Registry/ActivityCatalog.swift`: Home, Agent, Swarm, Develop, Analyze, Lab, Audit, Browser, Devices and Media (⌘1 to ⌘9, then ⌘0), then Images, Maps, News, Mail, Messages, Contacts, Calendar, Notes, Cloud Drives, Research, GitHub and Slack (no shortcut). Home groups its cards as Work, Communication, and Files and knowledge; an activity not listed in `UI/Workstation/HomeSections.swift` still appears, under More.
- **Tests.** The full Mac suite passed on `main` at `4b647e8` on 2026-11-12, run locally: 1,063 tests in 216 suites (about 95 seconds). CI runs the same suite on a hosted macOS runner (about 15 minutes); on 2026-11-12 three attempts on one pull request never got a runner ("The job was not acquired by Runner of type hosted"), so that change was merged on the local result. A speech-synthesis test is skipped on CI (the workflow forwards `CI=true` to the test process as `TEST_RUNNER_CI`; before that the skip never applied).
- **Installed builds checked on screen, 2026-11-12** (Developer ID signed and notarized, built from `main` at `39fd052` and `4b647e8`): Home and its grouping, the command palette, the empty states and permission screens of Mail, Messages, Contacts, Notes, Cloud Drives, Research and GitHub, Calendar reading real events and reminders, the Browser (below), and an Agent run with a hosted model (below). **Not seen with real data:** a Mail account, the Messages database, Contacts, Notes, a cloud-drive folder, the PDF reader's highlight and save buttons, Spotlight search, creating a calendar event or reminder. No real text or email has been sent from Kiln.
- **Tools on demand.** About 21,000 tokens of tool definitions (more than 200 tools) used to go to the model on every request, which overflowed any window below that and pinned the context meter at 100%. Now, when the definitions would use more than a tenth of the window, a run starts with the file, search, shell, Git and web tools plus `kiln_tool_search` (`Core/Agent/OnDemandTools.swift`); the agent searches by need and the matching tools are added for the rest of the run, and calling an unloaded tool loads it and returns its arguments instead of running it. `Core/Agent/ToolFit.swift` trims what still does not fit a small window (core tools first, then whole groups, to 30% of the window). The meter and `/compact` count only what is loaded; the thread says "N of M tools are loaded". Checked on screen with `nemotron-3.5-super` on NVIDIA NIM: 22 of 199 tools loaded, the agent searched for "reminders" and named the four tools it loaded, the meter read 3% to 4% (11% idle, because the idle figure also counts the system prompt and loaded tools; during a run the meter counts only the conversation). Swarm workers do not pass a window, so they still get their tools up front. Tests: `ToolLoaderTests`, `ToolFitTests`.
- **Browser.** It now identifies as Safari of the Mac's own version (`Modules/Browser/BrowserIdentity.swift`: `Version/27.0 Safari/605.1.15` on this Mac, confirmed by a real server echoing it), turns on element fullscreen and click-free playback, because a bare `WKWebView` sends no Safari token and streaming and cloud-gaming sites refuse it. **Not verified:** that any cloud-gaming service then starts (needs a sign-in); there is no microphone permission prompt for voice chat inside a page.
- **Messages.** Sending goes to each conversation by its own chat id (iMessage, SMS and groups), with a handle fallback for one-to-one iMessage chats; a permission refusal is never retried; a failed send is shown in red. Tested with fake senders; no real text sent.
- **Reasoning options.** The brain button beside the context meter is a per-model reasoning control (`Core/Reasoning/ReasoningOptions.swift`): it lists only what the selected model offers (an on/off switch, or named levels such as low, medium, high), and is greyed out with the reason when the model offers none. Memory files moved to the composer's "+" menu. Rules and verification are in section 8 of `30-CHAT-MAPS-LAYOUT-PLAN.md`; no live API has been sent a level yet and the open menu was not seen on screen.
- **Spotlight.** Conversations can be added to Spotlight (Settings: Off by default, Titles only, or Titles and text). Unit-tested; a real Spotlight search has not been tried.
- **Polish from the 2026-11-12 screen pass.** The palette ranks "Go to <activity>" above that activity's tool rows and a list that reorders under a resting pointer no longer steals the highlight; Calendar no longer says "Nothing" while loading; Research and Notes have proper empty states; permission and privacy footnotes are readable.
- **Notifications and Focus (branch `codex/kiln-notifications`, roadmap item 12).** `Core/Notifications`: a pure policy (`NotificationPolicy`), a coordinator that posts through `UNUserNotificationCenter` only when the rules allow and asks macOS for permission only then, per-kind preferences (Settings → Notifications), optional Focus status through `INFocusStatusCenter` (asks first; developers report it may read "off" without the Communication Notifications capability, which Kiln does not have), and the tools `notify_user` and `notifications_status` (under the Agent activity). The existing approval and scheduled-task notices now go through it, and a finished, failed or paused run notifies when Kiln is not in front. Unit-tested with fakes; the Settings card was seen on screen (2026-11-12, a debug build; the permission buttons were not pressed). **No real notification posted, Focus never read.**
- **Slack (added after the checks above).** `Core/Slack` and a Slack activity: you paste a bot (`xoxb-`) or user (`xoxp-`) token from a Slack app you create; it is checked with `auth.test` before it is saved to the Keychain and is never shown again or given to a model. Channels, direct messages and history (names resolved, Slack markup turned into text); posting needs your approval of the exact conversation and text and refuses `@channel`, `@here`, `@everyone` and user-group mentions, with link previews and name linking off. Tools `slack_status` (read), `slack_channels`, `slack_read` (execute), `slack_send` (admin); text from Slack is labelled untrusted. Tested with an in-process stub of the Slack API (no network, no real Keychain); **not seen on screen and not tried against a real workspace.** Not built: real-time events (it polls every 15 seconds), search, threads beyond the reply count, files, reactions, other workspaces, other chat services (Discord, Teams).
- **Open.** The rest of the roadmap ([21](21-EVERYTHING-APP-ROADMAP.md)); the unverified items above; Return in the command palette could not be confirmed with the available automation (the handler is `onSubmit`).

## Build, test, sign, notarize

- **`project.yml` is the source of truth.** `Kiln.xcodeproj` is generated (`xcodegen generate`) and gitignored.
  Edits made in Xcode's Signing & Capabilities screen are lost on the next generate (and once wrote a stray
  `CODE_SIGN_IDENTITY[sdk=macosx*] = "-"` that made archives ad-hoc signed — "No Team Found in Archive").
  Change signing in `project.yml`.
- Signing: automatic, team `LH8KLB9N4F`, Apple Development identity; Release archives are re-signed with
  Developer ID at export. `xcodeVersion: 2710` plus the recommended build settings keep Xcode's
  "Update to recommended settings" prompt away. Bump it when moving to a newer Xcode.
- Tests: `xcodebuild test -project Kiln.xcodeproj -scheme Kiln -destination 'platform=macOS'` (see the test count above; it was 592 on 2026-11-03; no
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

- **Sidebar and toolbar** (`UI/Workstation/WorkstationSidebar.swift`, `UI/MainWindow.swift`): the sidebar holds New chat, Scheduled tasks, the project switcher and the conversation history
  (auto-titled from the first message), with approvals and Settings at the bottom. Navigation is in the toolbar: Chat, Code, Browser, Maps and Devices buttons and a Work menu that lists the other activities. The Kiln logo opens
  Home. ⌘1–⌘9, ⌘0 and ⌘K (command palette) work.
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
- **Develop IDE pass (2026-11-09, unit-tested, not yet seen on screen):** `Core/Editor/DevelopController.swift` is the one service behind the editor view, palette
  (`UI/Workstation/DevelopCommands.swift`) and the `ide_*` agent/MCP tools (`DevelopAgentTools.swift`, registered through `DevelopActivity`): open at line, outline,
  definition, references, hover, rename (LSP, applied and saved inside the project), diagnostics, blame, build / test / run with issues returned, scheme choice,
  debugger start / control / state, conditional breakpoints, expression evaluation. New UI in `DevelopChrome.swift`: jump bar with back/forward, Symbols / Issues / Tests /
  References navigators, inspector (Quick Help, file, blame), activity strip, symbol context menu. Debugger gained threads, conditions and `expression`. **Not done:** multi-root
  workspaces, inline (end-of-line) blame, watch expressions, debugger attach, completion beyond ⌥Esc. None of the new views has been looked at in the running app.
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
  `AgentEvent.contextCompacted` / `.contextMeasured`. Since 2026-11-12 tool definitions are loaded on demand and trimmed to fit (see the section above), so the "tool-schema size" in that budget is only what is loaded. `ChatSession` keeps per conversation the summary + covered-message
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
  `Application Support/Kiln/mcp-server.json` (0600). the full tool registry (34 tools when this was written, more than 200 now), including `re_*` and `lab_*`. External calls run as
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
- **Analyze workbench (2026-11-09, `Core/ReverseEngineering/` + `Modules/ReverseEngineering/`):** services behind GUI, `re_*` tools and MCP:
  control-flow graph with minimap and zoom (`REGraphs.swift`; engine blocks when Ghidra/radare2 provide them, otherwise rebuilt from branches),
  call graph (callers above, callees below, DOT export), a project-wide cross-reference index (`REXrefs.swift`) so every address, symbol and
  quoted string in the listing and pseudocode is a link that opens a references sheet (which also sets address comments, labels and bookmarks),
  hex view synced to the selected function with `de ad ?? ef` / `"text"` search and a virtual-address map read from the load commands
  (`REHexPatch.swift`), patches assembled with clang or typed as hex/NOP and written only to a copy (original never touched, expected bytes
  checked), C-style struct/union editor with undo and apply-to-variable (`REWorkspace.swift`, stored in `kiln-workspace.json` beside the analysis),
  function-level binary diff with listing diff (`REDiff.swift`), IPA/APK inspector (Info.plist, entitlements, manifest, permissions, components,
  classes, resources; extract and import one entry) (`REPackage.swift`), findings with evidence and screenshots exported as Markdown and
  HTML (`REReport.swift`), lldb plan/run (load-only, or launch with a confirmation) (`REDebugLink.swift`), and a JS console whose `re` object is
  the same API the tools use (`REScript.swift`). New tools: `re_get_cfg`, `re_get_call_graph`, `re_get_references`, `re_read_bytes`,
  `re_search_bytes`, `re_annotate_address`, `re_change_variable`, `re_list/define/delete/apply_structure(s)`, `re_bookmark_address`,
  `re_create/remove/list_patch(es)`, `re_export_patched`, `re_diff_projects`, `re_inspect_package`, `re_import_package_entry`,
  `re_list/add_finding(s)`, `re_export_report`, `re_plan_debugger`, `re_run_debugger` (execute), `re_run_script` (execute). `re_get_xrefs` had
  `to`/`from` swapped and is fixed. Tests: `Tests/ReverseEngineeringTests/REWorkbenchTests.swift`. Screenshots: `docs/qa/analyze-re/`.
  **Not done yet vs Ghidra/IDA:** a full data-type manager, decompiler-integrated retyping UI, switch/jump-table recovery, FLIRT-style library
  signatures, emulation, collaborative projects, a patch assembler beyond clang for arm64/x86_64, string/crypto rows beyond strings and gadgets
  linking to code, and live checks of the Patches, Diff, Package, Findings and Debug panes in the running app (covered by tests only).
- **Reverse engineering:** import via `re_import_binary` (returns `project_id`; every other `re_*` tool takes it;
  the analysis id is accepted too). Native `otool` engine; Ghidra optional.
- **Browser (`Modules/Browser/`, activity ⌘8):** tabbed WKWebView browser: address bar (bare hosts get https, other text searches
  DuckDuckGo, only http/https open), back/forward/reload, tabs (⌘T, ⌘⌥W), find in page (⌘F), a Kiln-only persistent website data store
  (`WKWebsiteDataStore(forIdentifier:)`, cleared from the ⋯ menu), and downloads saved to the package-intake folder with an
  "Analyze in Kiln" button (never auto-imported). Agent/MCP tools `browser_open` (execute, egress-checked like `web_fetch`),
  `browser_read_page`, `browser_screenshot`, `browser_list_tabs` (read), `browser_click`, `browser_type` (write; approval). Page content is
  labelled untrusted; `browser_type` refuses password, card and one-time-code fields and password values are never read out. Not done:
  popup windows with `window.opener` (they open as new tabs), JS dialogs, HTTP auth prompts, per-tab incognito, history/bookmarks.
- **Package downloader (Analyze → Download…, `re_search_packages`, `re_download_package`):** one code path
  (`Core/ReverseEngineering/PackageIntake.swift`) serves the sheet, the in-app agent and the MCP server. Aptoide search returns
  direct APK links with the store's MD5, which the download verifies; Apple, Google Play, APKPure and Amazon only open a
  store listing (Kiln does not sign in to any store). Only http(s) is accepted, a non-2xx answer is an error, and
  `re_download_package` is a write, so it needs approval like `edit_file`. Files land in
  `Application Support/Kiln/ReverseEngineering/Downloads` and are analyzed, never run.
- **Devices (Apple simulators + Android emulators):** list/boot/shutdown/screenshot/install/launch/open URL/record/logs via `xcrun simctl` and `adb`/`emulator`, `device_*` agent and MCP tools, live screenshot view with Android touch forwarding. Apple input is not possible through simctl. See `docs/16-DEVICES.md` (also Windows/Linux design and sandbox notes).
- **Media (⌘0, `Modules/Media`, `Core/Media`):** viewer (AVKit video with scrub and 0.5–2× speed, zoomable images, audio with waveform) that opens workspace files,
  drops and agent results; a gallery of generated items in `Application Support/Kiln/Media`; image generation behind `ImageGenerationProvider`
  (Apple Image Playground when this Mac has it, else a custom OpenAI-compatible `/images/generations` endpoint — unverified against a live endpoint; with neither
  configured the call fails and says why, nothing is faked); text to speech to a file (AVSpeechSynthesizer.write) and speech to text from a file
  (`AudioTranscriber.transcribe(fileAt:)`; the composer's existing mic button is the dictation hook, untouched). Tools: `media_open`, `media_list` (read),
  `media_generate_image`, `media_speak`, `media_transcribe` (write, need approval). Verified here: a real MP4 plays in the viewer; TTS then STT round trip returned the spoken sentence.
- **Image studio (no shortcut, `Modules/ImageStudio`, `Core/ImageStudio`; research and measurements in `docs/18-IMAGE-STUDIO.md`):** activity "Images" with Create (prompt, negative prompt, style chips, engine and model pickers, task, size presets, steps, guidance, seed, batch, sampler and LoRA stack when the engine has them, queue with cancel, canvas with history strip), Models (engine status with setup steps, catalogue from four sources, downloads with progress) and History. Engines behind `ImageEngine`: **MLX** in-process (SD 2.x-architecture and SDXL-architecture diffusers folders: SD-Turbo, SDXL-Turbo, SDXL base and fine-tunes; text-to-image and image-to-image only; a vendored fork of mlx-swift-examples' StableDiffusion in `Packages/KilnDiffusion`), **Draw Things** (A1111-style HTTP API, default port 7860), **ComfyUI** (workflow API, 8188) and **AUTOMATIC1111/Forge** (7861); an engine that is not running shows a setup state and never fakes output; inpaint, outpaint and LoRA are offered only where an engine has them, with the reason shown otherwise. Catalogue: curated list (SD-Turbo, SDXL-Turbo, SDXL base/refiner, fine-tunes, SD 1.5, SD 3.5, FLUX.1 schnell/dev, Playground, LCM and Lightning LoRAs, ControlNets, VAEs, upscalers; sizes and licences checked 2026-11-09), Draw Things' live list (`models.drawthings.ai`), Hugging Face search and Civitai search (public API, no key). Downloader: resumable (Range), SHA-256 / git-SHA-1 verified, disk-space check, queue, into the universal model store in the Hugging Face cache layout (or the folder of another tool for single files); gated models need the user's own token (Settings → Providers, Keychain) and terms accepted on the model page, Kiln never accepts for the user; downloads over 8 GB need confirmation. Every PNG embeds its request as `kiln-generation` JSON plus an A1111-style `parameters` chunk, so "Re-run" and "Load settings" work from the file. Upscale is Lanczos resampling (labelled as such); AI upscalers, ControlNet, face fix and a LoRA in the MLX engine are **not** implemented. Tools: `image_list_models`, `image_history` (read), `image_download_model`, `image_generate`, `image_edit`, `image_upscale` (write; approval). Verified here: see docs/18 for what was actually generated.
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

## Verification status (2026-11-03; see the 2026-11-12 section above for later checks)

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

## Agent platform (2026-11-09, `Core/Platform/`)

Parity work against Claude Code Desktop and Codex (doc 17 §2). Each feature is a service in `Core/Platform/`, UI in the chat, tools named
`kiln_*` (so the in-app agent and MCP clients get them; enabled for the Coding and Workstation profiles) and an audit record for state changes.
**Unit-tested; not yet seen in the running app.**

- **Memory files** (`MemoryFiles.swift`, `Modules/Chat/MemoryPaneView.swift`): `KILN.md`, `AGENTS.md`, `CLAUDE.md` from `~/.kiln`, `~/.claude`, `~/.codex`
  and the project root are read when a run starts and appended to the system prompt (32 KiB per file, identical copies sent once; guidance only, never
  permissions). The brain button beside the context meter shows their token cost and opens an editor. `kiln_memory_read` / `kiln_memory_write`;
  audit `memory.saved`. Not done: `@import` lines, nested per-directory files.
- **Slash commands** (`SlashCommands.swift`, `CommandsPaneView.swift`): `.kiln/commands/**/*.md` (also reads `.claude/commands`), user scope
  `~/.kiln/commands`; frontmatter `description`, `argument-hint`, `model`; `$ARGUMENTS`, `$1`..`$9`; project overrides user; built-ins `/compact /clear /model
  /memory /commands /hooks /help` always win. Composer shows completions while typing `/…` (Tab completes). Tools `kiln_command_list/expand/write`; audit
  `command.invoked`, `command.builtin`, `command.saved`. Not done: command-palette (⌘K) entries.
- **Hooks** (`Hooks.swift`, `HooksPaneView.swift`): `.kiln/hooks/hooks.json` (project) and `~/.kiln/hooks/hooks.json`; events `pre_tool`, `post_tool`,
  `prompt_submit`, `stop`; script gets JSON on stdin; exit 2 or `{"decision":"deny"}` blocks, `annotate` adds a note to the tool result or prompt, `allow` is only
  recorded. pre_tool runs after the policy checks and before the approval gate, so a hook can only make a run stricter. A hook that errors or times out is
  recorded as `failed` and has no effect. Audit `hook.decision`, `hooks.saved`. `kiln_hooks_list`.
- **Plan mode** (`PlanMode.swift`, plan card in `ChatRootView`): the Plan toggle or `/plan` runs the agent with `AgentMode.plan` (write/execute tools neither offered nor accepted); its final
  reply becomes a plan card with Approve and run, Edit, Reject. Approval starts a normal run with the (edited) plan. Audit `plan.mode/proposed/approved/rejected`.
- **Checkpoints and rewind** (`Checkpoints.swift`): before `write_file`/`edit_file`/`delete_file` the old file is saved under `Application Support/Kiln/Checkpoints`, grouped by the user message.
  Right-click a user message → "Rewind to here (restore files)" or "Rewind conversation only" (hover button when a checkpoint exists). Files outside the project are never touched; a file changed by
  someone else after the run is left alone and reported; commands (`run_command`, `git_commit`, …) are listed as not undone. The rewound message goes back in the message box. Audit `checkpoint.created/rewound`.
- **Sessions** (`Sessions.swift`, `/sessions`): every conversation with Running / Waiting for approval / Idle, Open and Fork. Dock badge and a system notification when a run needs approval and Kiln is not in front.
  **Not done:** runs do not continue in the background while another conversation is open (opening one stops the current run), and worktree-per-task.
- **Usage and cost** (`Usage.swift`, `/cost`): ledger of tokens per provider, model and day (`Application Support/Kiln/Usage`). Cost is an estimate from prices you enter; local models are 0, hosted
  models without a price show as unpriced. A daily token and/or USD budget stops a run before its next model call (`UsageBudgetGate`, audit `usage.budget_stop`). Agent runs record a total only (no input/output split).
- **Scheduled tasks** (`Schedules.swift`, `/schedule`): every N minutes or daily at HH:mm, runs a prompt with a profile in its own conversation while Kiln is open; approvals still apply. Audit `schedule.run/saved`.
- **Verifier** (`Verifier.swift`): with `defaults write com.kiln.app agent.verifier.model <model id>` a second model checks each final answer against the run's tool results and lists unsupported claims under the reply
  (audit `verifier.report`). No settings control yet; advisory only.
- All of the above are unit-tested with stub providers; **none has been seen in the running app** (GUI checks were deferred to the lead).

## Maps and News development activities

See [Maps and News status](23-MAPS-AND-NEWS.md) for capabilities, agent/MCP permissions, verification and remaining gaps. These activities have not been included in a public release.

Changes on 2026-11-13: themes (`UI/DesignSystem/KilnTheme.swift`, `UI/Settings/ThemeSettingsCard.swift`): seven built-in themes and saved custom themes (colours for dark and light, font design, text size), applied through the design tokens (`SSColor`, `SSTypography`) and a redraw of the main window; seen on screen switching to Violet, duplicating, and Serif; views with hard-coded fonts and colours do not follow, light mode and the other windows are not checked; in the chat's bottom bar the agent profile picker and the step limit are one menu;  the model picker has an Ollama library sheet (download by name with progress and cancel, remove with confirmation) and the agent has `models_*` tools; tested against a stub and seen listing real models, not yet used for a real download or removal; MLX and Hugging Face downloads are not built.

Changes on 2026-11-12: Maps gained US weather (forecast sheet and `weather_*` tools, National Weather Service) and a NOAA radar layer with a time loop and `maps_radar`; the My Location button is back in the toolbar and Kiln now asks macOS for location permission (before, it never requested it; not yet answered on this Mac). Turning on the menu-bar item crashed the 0.2.0 build (stack overflow); fixed and merged, in the build installed that day. Seen on screen: the Weather sheet and the radar bar, loop and light echoes. Not seen: the My Location button's permission prompt, the menu-bar icon and popover.
