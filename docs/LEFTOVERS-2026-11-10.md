# Leftovers from the QA and polish session (2026-11-10)

Running list, updated as the session goes. Read with `docs/HANDOFF-2026-11-10.md`. "Verified" means seen working in
a Debug build of this checkout with a real model selected; screenshots are in `docs/qa/final-polish/`.

## Working arrangement found at the start

- The checkout was on branch `codex/kiln-qa-completion` (same commit as `main`, `03c0eb2`) with uncommitted edits by
  another agent in 13 files (usage pane, schedules pane, devices, image studio, sidebar toggle, transport). Branches
  were not switched. Commits from this session are on that branch and include those edits only in files this
  session also had to change (`Modules/Devices/DevicesRootView.swift`, `UI/MainWindow.swift`,
  `UI/Workstation/WorkstationModel.swift`, `Core/Chat/ChatSession.swift`).
- GUI checks ran against one Debug build in `/private/tmp/claude-501/build-triage`, with no other Kiln process.
- The hosted reference model (NVIDIA NIM GLM 5.3 Flash) accepted a request and never answered (the queue problem
  already noted in `11-CURRENT-STATE.md`). Agent checks used the local Ollama model `qwen2.5-coder:7b` instead.

## Verified on screen

| Feature | Result |
|---|---|
| Usage pane (`/cost`) | Opens, budget and price fields, empty state. No usage had been recorded yet. |
| Scheduled tasks (`/schedule`) | Opens, empty state, add form. A schedule was not left to fire. |
| Sessions (`/sessions`) | Lists every conversation with state, Open and Fork. |
| Memory pane (`/memory`) | Lists user and project `KILN.md`, `AGENTS.md`, `CLAUDE.md`, token cost, editor. |
| Commands pane (`/commands`) | Built-ins listed, add form. |
| Command palette | Opens, filters, runs; new project, settings and chat-pane entries work. |
| Plan mode and plan card | Plan toggle on, local model explored read-only, card with Approve and run, Edit, Reject; Reject clears it. |
| Checkpoints and rewind | `write_file` created a file in a demo package; the Rewind control removed it, put the prompt back in the message box and reported "removed 1 the agent created". The checkpoint survived a relaunch. |
| Context meter with a real model | Shows a percentage on one line (2% hosted, 59% for the 7B local model after its tool schemas). |
| Collapsed tool calls | "Used 2 other tools", "Edited 1 file" rows under finished replies. |
| Analyze tabs | Functions, Graph, Hex, Types, Patches, Diff, Package, Findings, Debug, Script all open on the sample project. |
| Approvals sheet | Opens; 33 standing grants listed (see below). |

## Fixed in this session

- Empty states did not fill their pane, so Analyze → Diff, Package and Findings pushed the activity header halfway
  down the window (`SSEmptyState`).
- Sidebar chat rows and activity rows were clickable only on their text; the whole row is now the target. Approvals
  and Settings icon buttons have names for VoiceOver.
- Command palette: rows are buttons, the `esc` cap closes it, it is modal for assistive technology, and it gained
  Settings, Open Project, Switch Project (recents) and the chat panes (usage, schedules, sessions, memory, commands,
  hooks, plan mode, compact).
- Message actions (copy, regenerate, fork, delete) were removed from the accessibility tree while not hovered.
  Rewind is now always visible on a message that has a checkpoint.
- Sessions pane: delete a conversation (with confirmation), "1 message" grammar. The sidebar reloads after a delete.
- Analyze: delete a project from its row (with confirmation; the context menu deleted without asking), Patches row
  no longer truncates its Add button, a one-block function no longer fills the graph minimap.
- Media and Devices use the shared activity header like every other activity.
- Approvals sheet: the grants list gets the sheet when nothing is waiting, dates show the day, Revoke All asks first.
- A message typed while a reply was still stopping was dropped; it now stays in the message box.
- Command answers (`/model`, `/plan`, `/help`) are no longer shown in the warning colour.
- Home no longer flashes "Connect a model" before the provider check has answered.
- Tests leaked a preferences file per run into `~/Library/Preferences` (787 files removed; the tests now clean up).

## Standing approval grants (33, none removed)

Tools: `edit_file`, `write_file`, `lab_import_dataset`, `lab_create_experiment`, `lab_start_training`,
`lab_export_model`, `lab_start_small_lm`, `lab_start_distillation`. Shell commands: 25 exact command lines from
earlier QA (Python unit tests, `pip install pytest`, Swift and Xcode version probes, a `NewsReader` scaffold, a
`sed -i` and a `git commit` inside `~/kiln-qa-project`, `echo deny-test`, `echo allow-check-1`, `find . -maxdepth 3`,
`swift test 2>&1 | tail -60`). Because `write_file` and `edit_file` are granted, the agent writes files in Ask mode
without asking; that is what the checkpoint test above ran into. Owner decision: revoke in Approvals (shield icon
in the sidebar footer) → Standing grants.

## OpenCode's uncommitted work (found mid-session)

OpenCode left about 20 untracked files in the checkout (`Core/Capabilities`, `Core/ModelRouting`, `Core/Notifications`,
`Core/Settings`, `Core/Agent/SlashCommands.swift`, `Core/Swarm/SwarmCoordinator.swift`, `Core/Voice/VoiceManager.swift`,
`Core/Devices/DevicesService.swift`, `Modules/{Notifications,Settings,Swarm,Voice}`, `Modules/Devices/DevicesTools.swift`, docs 24-28,
and `ENABLE_CAPABILITY_REGISTRY` in `project.yml`). After `xcodegen generate` they broke the build: six files had syntax errors,
`SlashCommands.swift` duplicated `Core/Platform/SlashCommands.swift` (same product file name), and most of the rest
re-implements features that exist and are tested. Docs 24-28 say "implementation complete" and quote 592 tests, which is
not true of the code. Everything was **moved unchanged** to the shared notes folder
`.../side-session-notes/local_cb5577b1-.../opencode-quarantine/` (with a README); nothing was deleted. Worth a second look:
`Core/ModelRouting` (routing rules), `Core/Settings/SettingsLayers.swift` (user/project settings layers),
`Core/Notifications`. Its `docs/29-VISUAL-QA-2026-11-10.md` is about the committed Maps/News work and was left in place (untracked).
Codex committed Maps and News (`ae74b83`..`45c9655`) on this branch during the session; those are not part of this QA.

## Open items (not done in this session)

- **Not yet seen on screen:** the Develop debugger UI and a Swarm run. Seen since: Settings and its About sheet, light mode on Browser and Analyze,
  Images generation (SD-Turbo, MLX, 56.8 s including the first model load from the drive; `verified-images-generation-sd-turbo.jpg`),
  Send to Media then the Media viewer (`verified-media-viewer.jpg`), and Devices booting an iPad simulator and showing its live screen
  (`verified-devices-booted-ipad.jpg`; the very first boot kept the row busy for about three minutes while the simulator migrated its data).
- **Palette:** the Maps and News activities are Codex's; their toolbars clip at narrow widths (see docs/29).
- **Cleanup (done):** 12 merged worktrees (11 under `.claude/worktrees/`, plus `../kiln-codex-integration`) were removed and 20 merged
  `claude/*` and `codex/*` branches deleted with `git branch -d` after `git branch --merged HEAD`; prunable `/private/tmp/kiln-*` entries pruned.
  **Kept because they are not merged:** `claude/image-studio-8ff931` (+2 commits, worktree with an untracked upscale screenshot),
  `claude/integration-registry-bf14c5` (+1), `codex/axiom-core-tests` (+2), `codex/ghidra-setup` (+2), `codex/lab-agent-start` (+2). Their owners should
  say whether to merge or drop them. Build folders under `/private/tmp/claude-501/` are kept (`build-triage` is in use); the leaked `stub-m1` selection is fixed (below).
  Test chats `hooks/`, the empty "New Conversation" and the checkpoint-test chat and the `kiln-qa-re-sample` project were deleted through the app.
  The demo project `~/KilnDemo/DemoPackage` is untouched (the checkpoint test file was rewound away).
- **Parity (doc 17):** a Permissions pane (per-tool and per-path rules) and approval notifications remain; the approvals sheet now
  shows and revokes grants but has no rules editor.
- Full test suite not run (other agents were building); targeted suites pass: 49 tests (Workstation, registry, editor settings, usage, push).

## Added after the OpenCode review

- Fixed: Git tab explains "No repository" / "Working tree clean"; after 60 s without a reply the thread says the provider may be busy and suggests Stop and another model.
- Verified: Devices (shared header, simulator list, empty detail guidance) and Images Create at a 1416 pt window with the agent dock.
- **Fixed (the `stub-m1` mystery):** `ChatSession.recordRecent` wrote to `UserDefaults.standard`, so any unit test that switched models put `stub-m1` at the top of the real recent-models list (and so into the status bar after relaunch). It now writes nothing under XCTest, and the value was removed from the real defaults. `defaults read` can lag `cfprefsd`; read the plist with `plutil -p` to see the file.
- Another set of leaked test preferences appeared (`kiln.tests.*`, `kiln.news.tests.*`, `kiln.remote.test.*` in `~/Library/Preferences` and the container); the News tests (Codex) do not remove their suites.
- A blind click on a stale element index pressed Play on a simulator (iPad A16 booted); it was shut down with `simctl shutdown all`.
- Added: an Appearance control (System, Light, Dark, High Contrast) in Settings; `ThemeManager` existed but nothing used it. The palette's "Settings…" entry now opens the window (it used a selector that did nothing); the menu bar route always worked.

## Test status at the end of the session

Full suite on this branch (`c3bc270` plus Codex's Maps/News work in the tree): **884 tests in 185 suites passed** (82 s, nothing else building).
The suites still leave preference files behind in `~/Library/Preferences` (246 more appeared in this run: `kiln.tests.*`, `kiln-tests-*`,
`kiln.news.tests.*`, `kiln.migration.*`); they were deleted again by pattern. The remaining leakers use `UserDefaults(suiteName:)` without
`removePersistentDomain` (ContextSessionTests, UnifiedShellTests, AppleMLXAndRegistryTests, WorkstationTests/RegistryTests `isolatedDefaults`,
News tests, BundlePreferencesMigrationTests). A shared test helper that removes the suite in a `defer` would fix them.

## Finishing pass

- Test suites now clean up all preference suites (`Tests/Support/TestDefaults.swift`); a run leaves 0 files behind (was hundreds).
- Fixed: Images result actions collapse to icons instead of scrolling Delete off the edge; Devices Boot/Shut down buttons have per-device accessibility labels.
- The generated test image ("a small red kiln glowing…") is in Images → History and Media → Gallery of the real app; deleting needs a right-click or the Delete action, which background control cannot press. Delete it from the app if unwanted.
- Still open: Permissions pane (per-tool/per-path rules), approval notifications beyond the existing Dock badge, Develop debugger UI check, Swarm run.
