# Kiln — current state (2026-11-01)

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
- Tests: `xcodebuild test -project Kiln.xcodeproj -scheme Kiln -destination 'platform=macOS'` (466 tests, no
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
- **Approvals:** reads run freely; writes, commands and network calls open the approval sheet. "Always Allow"
  creates a standing grant (revocable under Approvals). `ApprovalCenter` is a Combine `ObservableObject`: views must
  observe it directly (`ApprovalSheetHost`), reading it through `AppModel` never re-renders.
- **Swarm:** planner (JSON plan or fixed research → implement → review fallback), parallel workers over the
  coordination bus, blockers reported not retried, every worker call through the same gates.
- **Kiln as an MCP server:** Develop → MCP → Start. Loopback only, bearer token in
  `Application Support/Kiln/mcp-server.json` (0600). 34 tools incl. `re_*`, `lab_*`. External calls run as
  "External: <client>" and are audited; reads are free, anything else waits for approval in Kiln.
- **Reverse engineering:** import via `re_import_binary` (returns `project_id`; every other `re_*` tool takes it;
  the analysis id is accepted too). Native `otool` engine; Ghidra optional.
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

## Known limits and ideas

- App Sandbox: child shells cannot set a controlling tty (`zsh: can't set tty pgrp` in Develop → Terminal; harmless)
  and the system `python3` shim fails (agents fall back to Homebrew Python). Shell commands run inside the sandbox.
- Custom endpoint with a 3B model returned "None" after a tool call; the same model is fine on the native Ollama route.
- `Packages/ModelLabCore/Package.resolved` is rewritten by every build; never commit it.
- Ideas, in order of value: hand context from a tool to the agent (selected function, dataset) instead of generic
  starter prompts; LM Studio and Ollama-directory scanning; a first-run flow (project, one model, one key); consistent
  header chrome for Lab and Analyze, which still carry their own toolbars; auto-title with a model instead of the
  first line; show reasoning/tool calls inline in the thread like the reference apps.
