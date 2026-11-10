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

## Open items

(continued below as they are found)
