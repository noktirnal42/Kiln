# Handoff for Codex (2026-11-10, written by Claude at the end of its session)

Read this, then `docs/LEFTOVERS-2026-11-10.md` (what was verified and what was not), `docs/30-CHAT-MAPS-LAYOUT-PLAN.md` (the plan and the owner's todo list, sections 5 to 7)
and `docs/31-CHAT-VISUAL-COMPARISON.md` (how Codex and Claude Code Desktop look next to Kiln). `docs/HANDOFF-2026-11-10.md` is the older handoff and still right about the project.

## State

- Branch `codex/kiln-qa-completion`, head `38f7421`, **nothing pushed**. Full suite at `82cebf5`: **924 tests, 191 suites, all pass** (82 s, run only when nothing else builds).
- Your own commits `510003f`..`45c9655` (Maps, News) are in. OpenCode's uncommitted work was moved out of the tree because it did not compile and duplicated existing features:
  it is in `~/Library/Application Support/Claude/side-session-notes/local_cb5577b1-7ce2-4d4a-a0c8-f954e2e2630b/opencode-quarantine/` with a README. Do not copy it back wholesale. `Core/ModelRouting`, `Core/Settings` and `Core/Notifications` there are worth a look.
- `Packages/ModelLabCore/Package.resolved` is always dirty and must never be committed.

## What changed this session (all committed, each with tests)

| Area | Change | Where |
|---|---|---|
| Polish | Empty states fill panes; sidebar rows are whole-row targets; palette rows are buttons; Settings, Open Project, Switch Project, chat panes in the palette; delete for sessions and Analyze projects (confirmed); Media and Devices use the shared header; Lab uses `SSMasterDetail` | `UI/DesignSystem`, `UI/Workstation`, `Modules/*` |
| Settings | Appearance (System, Light, Dark, High Contrast); palette opens Settings through `openSettings` | `UI/Settings/ProviderSettingsView.swift`, `UI/MainWindow.swift` |
| Devices | Mirror follows actions in seconds; "Open in Simulator"; honest note that simctl cannot send taps or keys | `Modules/Devices` |
| Chat composer | `@file` mentions with a ranked picker, attachments (files, folders, images by path only), queue while the agent works (paused by Stop), card composer, **`NSTextView` message box** (Return sends or queues, Shift/Option/Control+Return line break, ⌘Return sends, Tab completes) | `Core/Chat/ComposerContext.swift`, `Modules/Chat/ComposerTextView.swift`, `ComposerChips.swift`, `ChatRootView.swift` |
| Chat thread | Diff card with per-file confirmed Revert; agent task list tool `kiln_todo_write` with a card; Claude-style tool summaries (sentences), live status line with elapsed time, friendly step titles, notice when a model writes a tool call as text, several text calls accepted (all or nothing) | `Core/Platform/RunDiff.swift`, `TodoList.swift`, `Core/Chat/ToolActivitySummary.swift`, `Modules/Chat/RunCards.swift`, `AgentActivityView.swift`, `MessageBubble.swift`, `Core/Agent/AgentOrchestrator.swift` (`TextToolCall.parseAll`) |
| Tests | `Tests/Support/TestDefaults.swift` removes every preference suite at exit; `ComposerTextViewTests` sends real `keyDown` events | `Tests/` |
| Housekeeping | 12 merged worktrees and 20 merged branches removed; unmerged kept (`claude/image-studio-8ff931`, `claude/integration-registry-bf14c5`, `codex/axiom-core-tests`, `codex/ghidra-setup`, `codex/lab-agent-start`) | git |

## The todo, in the owner's priority order

The owner's words: the chat must be at parity with Claude and Codex and **better**; Maps at parity with Apple Maps; the whole app cohesive; verify everything and implement what is missing.
Details and acceptance notes are in doc 30; this is the order I would work in.

1. **Thread display, second pass** (doc 30 section 6 item 1, doc 31): Codex-style "Worked for X ›" as an option next to the Claude-style sentence lines; per-burst sentence lines between the assistant's sentences (store the text of each model round with the reply:
   `MessageSnapshot` has no field for it, add one with a SwiftData migration); file-name chips that open the editor at the line; tables and math (Copy on code blocks is done: `CodeBlockHeader`, seen on screen); dismissible banner above the composer; edit-and-resubmit; "Undo all / View changes" on the diff card header.
2. **Round limit as a setting** (`AgentOrchestrator.defaultRoundLimit = 200`, "Paused after N steps"): visible, per profile, "keep going" without typing.
3. **Verify Shift+Return in the running app** with real keystrokes (it is tested with synthesized events only) and the whole chat against doc 30's parity table.
4. **Layout** (doc 30 section 7): sidebar for projects, sessions, pins and Settings only; modes become a title-bar icon row (session rail, Terminal ⌘J, changes, browser, devices, files, view options) opening a Canvas beside the thread;
   **Swarm folds into chat** (Team toggle plus `/swarm` and the `swarm_*` tools); native toolbar and full menu bar, tooltips everywhere, Help menu and in-app documentation, standard About panel.
5. **Maps parity** (doc 30 section 3, your code in `Modules/Maps`): suggestions, categories, place card within MapKit's limits, multi-route directions with ETA and steps, Look Around, Flyover, traffic and filters, collections and share. Offline maps, indoor maps, hours and ratings are not public APIs; say so in the UI.
6. **Chat parity leftovers**: images as pixels to vision-capable models (the development branch now has image message and transport groundwork, but the composer and persistence are not wired), `@symbol/@page/@device`, steering a running agent, thread rename/pin/archive/search, background runs, PR/CI flow, push-to-talk.
7. **Cleanup and open bugs**: Develop debugger UI and Analyze debugger were never seen on screen (needs a package with an executable and a folder picker); real iOS simulator input needs `idb` or a HID bridge (brief in LEFTOVERS); a model that calls tools natively is needed to see the live status line and task-list card on screen
   (hosted NVIDIA stalls, Ollama Cloud needs paid credits, local qwen2.5-coder:7b writes calls as text and invents tools, gemma4:e4b is slow).

## How to work here (what cost me time)

- Build: `xcodegen generate` (needed after adding any file), then `xcodebuild build -project Kiln.xcodeproj -scheme Kiln -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/build-triage`.
  Targeted tests: add `-only-testing:KilnTests/<Suite>`. Full suite only when nothing else is building or running Kiln.
- **Before any GUI check:** `pgrep -fl "Contents/MacOS/Kiln"`; every build shares the bundle id `com.kiln.app`. Kill your own copy before relaunching: `pkill -f "build-triage/Build/Products/Debug/Kiln.app/Contents/MacOS/Kiln"`.
  Confirm the status bar shows a real model, not `stub-m1`. The model picker now hides unavailable recents, but something outside the tests of this checkout still wrote `stub-m1` into `chat.recentModels`; `plutil -p ~/Library/Preferences/com.kiln.app.plist` shows the file (the `defaults` command can lag the preferences daemon).
- GUI automation: `app_*` tools with `com.kiln.app`; use `app_ax_find` and element indices after every screenshot (indices shift); type into the message box by element index (raw-input typing into the cramped dock composer scrambles text); never press Play on a device row blindly (it boots a simulator);
  a `.task` on an empty `Group` never runs (put it on a `VStack`).
- Tests leak preference files into `~/Library/Preferences` when a test uses `UserDefaults(suiteName:)` directly: use `TestDefaults.suite(...)`. If you find `kiln*test*` plists there, delete them by pattern.
- Local models for QA: Ollama has `qwen2.5-coder:7b` (loads in about 45 s from disk, then answers in seconds), `gemma4:e4b`, `qwen3-coder:30b`. Ollama Cloud models answer "payment required". None of the local ones calls tools reliably.
- The Claude Code Desktop app cannot be addressed by the computer-use tools from a session running inside it; Codex's app is `com.openai.codex` and can be opened read-only. Keep screenshots of the owner's real threads out of the repo (the session notes folder is fine).
- Rules from the owner: never read, print or enter keys, passwords or tokens; never click "Always Allow"; no pushing or publishing without the owner; leave no test data in real app folders
  (known leftovers: one test chat and `~/KilnDemo/DemoPackage/notes.txt`, plus the generated image in Images and Media); commit trailer `Co-Authored-By: <your model name> <noreply@...>`; the licence (PolyForm Noncommercial, FreeRange Labs) is already applied and must not change;
  run `sh Scripts/check-docs.sh` after docs changes.

## Not verified on screen (be honest about it)

Task-list card, live status line, Shift+Return in the running app, drop of a file onto the composer, Develop and Analyze debugger UIs, a booted device with real touch, Maps and News (yours), light mode beyond Browser and Analyze.


## Update 2026-11-11

- Local model audit and capability detection: see `docs/32-LOCAL-MODELS.md` and the last section of `docs/LEFTOVERS-2026-11-10.md`. `Scripts/test-ollama-tools.sh <model>` checks structured tool calling.
- Blocked: the external model drive is full (pulls fail), and GUI verification of the live status line and task card is pending an unlocked screen.
