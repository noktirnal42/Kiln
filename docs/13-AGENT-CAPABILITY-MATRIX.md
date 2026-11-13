# Can the agent operate Kiln itself?

Kiln exposes application services as ordinary tools. The Workstation Agent profile can use the registered `re_*` and `lab_*` tools, alongside file, shell, Git and workspace tools. Each tool still passes through policy and approval checks. The external MCP endpoint uses the same registry and gates.

**The agent cannot yet operate every feature in Kiln.** Shell access is not equivalent to a supported, service-backed application action. The table below distinguishes the two.

| Area | Service-backed agent access | Missing application actions |
| --- | --- | --- |
| Workspace files | Read, write, edit, delete, list, glob and grep; workspace path containment. Files the agent changes appear in the Editor within about two seconds (clean tabs reload; tabs with unsaved edits raise a conflict banner) | Agent-edit review (accept/reject hunks); `ide_open` now opens a file at a line |
| Development | Run/stream/background commands; Git status, diff, commit, branch, log; file-name search | Project settings, multi-root workspaces. Covered by `ide_*` tools: open at line, outline, definition, references, hover, rename, diagnostics, blame, scheme selection, build, test, run, debug start/control/state, breakpoints, evaluate |
| Reverse engineering | `re_import_binary`, `re_search_packages`, `re_download_package` (write; approval), `re_analyze_binary` (installed Ghidra; execution approval), `re_analyze_function`, `re_get_disassembly`, `re_get_decompilation`, `re_search_strings`, `re_get_xrefs`, `re_scan_crypto`, `re_auto_decrypt`, `re_find_gadgets`, `re_carve_formats`; read: `re_get_cfg`, `re_get_call_graph`, `re_get_references`, `re_read_bytes`, `re_search_bytes`, `re_list_structures`, `re_list_patches`, `re_diff_projects`, `re_inspect_package`, `re_list_findings`, `re_plan_debugger`; write (approval): `re_annotate_address`, `re_change_variable`, `re_define_structure`, `re_delete_structure`, `re_apply_structure`, `re_bookmark_address`, `re_create_patch`, `re_remove_patch`, `re_export_patched` (copy only), `re_import_package_entry`, `re_add_finding`, `re_export_report`; execute (approval): `re_run_debugger` (launch runs the target), `re_run_script` | Project selection, annotation editing, scan-rule management, forensics/script workflows and device-bench operations need dedicated adapters |
| Browser | `browser_read_page`, `browser_screenshot`, `browser_list_tabs` (read), `browser_open` (execute; egress rules), `browser_click`, `browser_type` (write; approval; refuses credential fields) | History, bookmarks, popups with opener, JS dialogs and HTTP auth are not exposed |
| Model Lab discovery | Hardware report, experiment/dataset lists, Hugging Face model/dataset search; `lab_import_dataset` (local CSV/TSV/JSON/JSONL/TXT or image folder → dataset library, same service as the GUI import) | Model download/library registration and deletion |
| Model Lab experiment control | `lab_get_experiment` reads status, recent metrics and artifact ID; `lab_cancel_training` requests cancellation only for the exact running experiment; `lab_start_training` starts an existing Create ML classifier through shared GUI/job validation; `lab_create_experiment` (draft text/tabular classifier over a registered dataset, columns validated), `lab_predict` (run a trained Create ML text classifier over inputs), `lab_predict_images` (run a trained Create ML image classifier over up to 200 images or a label-named folder and report accuracy against the folder names; file listing and scoring are unit-tested, not yet run against a real trained image model), `lab_evaluate_predictions` (accuracy/F1/BLEU/ROUGE, same runner as the Evaluation tab), `lab_export_model` (Core ML / MLX package into an existing folder, never overwriting), `lab_list_models` / `lab_register_model` (an MLX Hub repository, downloads nothing) / `lab_delete_model` (unregisters a Hub entry without touching the cache; deletes a local artifact's library copy; execute tier, approval required), shared with the Models tab registry | `lab_start_small_lm` (create + start a from-scratch character-level language model over a text dataset, bounded); `lab_start_lora` (MLX LoRA over a txt/jsonl dataset; the base model must already be cached, otherwise the call fails without downloading until the user agrees and `allow_download=true` is passed; run end to end in the installed app: SmolLM-135M, 20 iterations, completed after approval); `lab_start_distillation` (teacher "apple" or a cached MLX repo answers seed prompts, then a LoRA student trains on the answers; same download policy for teacher and student; implemented and unit-tested, not yet run end to end); `lab_create_experiment` also accepts `image_classification` over an imported image folder (untested with a real image set) | Training configuration edits, experiment comparison |
| Image studio | `image_list_models`, `image_history` (read); `image_download_model` (write; approval; refuses over 8 GB without `confirm_large`, never accepts licence terms, needs the user's own Hugging Face token for gated models), `image_generate`, `image_edit` (image-to-image, inpaint, outpaint), `image_upscale` (write; approval). Same `ImageStudioService` as the GUI; an engine that cannot do a mode says why. | Prompt/style library edits, ControlNet, AI upscalers and face fix have no tool or engine yet; model search of Hugging Face/Civitai is GUI-only |
| Mail | `mail_accounts`, `mail_folders`, `mail_recent`, `mail_read` (execute; message text labelled untrusted); `mail_send` (admin; approval of the exact account, recipients and subject) | Account setup and removal, replying and drafting in the GUI, attachments, search, folder actions |
| Contacts | `contacts_status`, `contacts_search` (read-only) | Creating or editing contacts |
| Notifications | `notify_user` (write; approval in Ask mode; labelled "Kiln agent:", plain text, 5 per 10 minutes, held when Kiln is in front, when Focus is on or when the person turned agent notices off); `notifications_status` (read) | Choosing which notices are sent and allowing Focus status (the person's settings), other apps' notifications (macOS offers no access), notification actions |
| Slack | `slack_status` (read); `slack_channels`, `slack_read` (execute; text labelled untrusted); `slack_send` (admin; approval of the exact conversation and text; refuses whole-channel mentions) | Connecting or removing the token (the person's), search, files, reactions, real-time events, other chat services |
| Messages | `messages_status`; `messages_conversations`, `messages_read` (execute; text labelled untrusted); `messages_send`, `messages_compose` (admin; approval of the exact conversation and text) | Attachments, new group conversations; delivery cannot be confirmed |
| Calendar and Reminders | `calendar_status`, `calendar_events`, `reminders_list` (read); `calendar_create_event` (admin), `reminders_create` (write) | Editing or deleting events and reminders |
| Notes | `notes_recent`, `notes_search`, `notes_read` (execute; locked notes refused); `notes_create` (write; approval) | Editing, deleting, attachments, checklists |
| Cloud Drives | `drive_*`: list drives, browse, search names, read text files (read); copy in or out (write; approval; never overwrites) | Online-only files cannot be read; content search |
| Research | `pdf_info`, `pdf_read`, `pdf_search` (read); `pdf_highlight`, `pdf_note` (write; always a new file); `library_search`, `library_cite` (read); `library_add`, `library_note` (write) | OCR for scanned PDFs, whole-library export, full-text library search |
| GitHub | `github_prs`, `github_pr`, `github_issues`, `github_runs` (read-only, through the signed-in `gh`; text labelled untrusted) | Comments, reviews, merges |
| Weather | `weather_forecast`, `weather_alerts` (execute: they send coordinates to weather.gov; National Weather Service, US only; reply names the source, issue time and issuing office; text labelled as data) | Radar, places outside the United States |
| Maps and News | `maps_*` (19 tools) and `news_*` (6 tools), see [Maps and News](23-MAPS-AND-NEWS.md) | See that document |
| Loading tools | `kiln_tool_search` loads module tools on demand when their definitions would use more than a tenth of the model's window; it is part of the agent loop, not a registered tool, and runs nothing | Swarm workers do not use it |
| Swarm | Workers use team messaging, shared memory and blocker tools | No ordinary top-level tool yet to create, inspect or cancel another swarm run |
| Chat and artifacts | Shared model registry and tool-run loop underpin chat | Conversation management, artifact creation/rendering/export and provider configuration need explicit tools |
| Audit and approvals | Every agent run records decisions and tool results; writes and execution can require approval | Agent-facing audit queries and verification tools are missing; agents must never approve themselves or alter the approval policy |


## Registry gaps

These activity capabilities currently lack a dedicated agent tool. The IDs correspond to the registry and are not evidence of implemented behavior.
*Updated 2026-11-12 to mirror the exemptions declared in the activity descriptors. Build, test, run, debug, diagnostics and open-at-line are no longer gaps: the `ide_*` tools cover them. Swarm control and audit queries still have no agent tool.*

- `agent.approvals` — Approve or deny tool calls and standing grants. Deliberate: an agent must never approve itself or alter the approval policy.
- `agent.artifacts` — Create and export artifacts. Gap: artifact creation, rendering and export have no tool yet (docs/13, Chat and artifacts).
- `agent.choose-model` — Choose the model and agent profile. Deliberate: the model and profile decide what the agent may do, so the user picks them.
- `agent.new-conversation` — Start a new conversation. Gap: conversation management has no tool yet (docs/13, Chat and artifacts); an agent starting its own fresh context is better served by compaction.
- `agent.plan` — Approve or reject a proposed plan. Deliberate: a plan is approved by the person; an agent approving its own plan would defeat plan mode.
- `agent.rewind` — Rewind files and conversation to an earlier message. Deliberate: rewinding discards work, so the person does it from the conversation; the agent can list checkpoints.
- `agent.sessions` — List sessions with status; resume and fork them. Gap: the conversation store is not yet reachable from tools; the Sessions pane (`/sessions`) covers it for the person.
- `agent.usage-budget` — Set prices and the daily budget. Deliberate: the budget limits the agent, so an agent must not be able to raise it.
- `agent.verifier` — Check a reply against the tool evidence with a second model. Deliberate that the agent cannot run it; gap: the model is set with the `agent.verifier.model` default, no settings control yet.
- `analyze.delete-project` — Delete a project. Gap: no delete tool yet; destructive, so it needs an approval-gated adapter before it is offered.
- `analyze.device-bench` — Device bench: connect, read registers and memory. Gap: device-bench operations need a dedicated adapter with its own limits (docs/13, Reverse engineering).
- `analyze.engines` — Choose Ghidra or radare2, set the Ghidra folder. Deliberate: which external engine runs, and from where, is a trust decision the user makes.
- `analyze.select-project` — Choose the open project. Gap: tools take a project id, but there is no tool to list projects or to set the one on screen (docs/13, Reverse engineering).
- `audit.browse` — Browse the audit record. Gap: agent-facing audit queries are not built yet (docs/13). Until they are, an agent can only see its own run's tool results.
- `audit.configure` — Change audit settings. Deliberate: an agent must never alter the policy that records or gates its own actions.
- `audit.verify` — Verify the audit chain. Gap: no verification tool yet (docs/13). It would be read-only; the chain itself stays append-only for agents.
- `browser.analyze-download` — Analyze in Kiln (hand a download to Analyze). Deliberate: a download reaches Analyze only when the user presses the button; re_download_package and re_import_binary cover the agent path.
- `browser.clear-site-data` — Clear cookies and site data. Deliberate: erasing the user's sessions is the user's decision.
- `browser.find-in-page` — Find in page. browser_read_page returns the text for the agent to search itself; no separate find tool is needed.
- `browser.navigate-history` — Back, forward, reload. Gap: history navigation is not a tool yet; browser_open reaches any address (docs/13, Browser).
- `browser.tab-management` — New and close tab. Gap: browser_open can open a new tab; closing tabs has no tool yet (docs/13, Browser).
- `develop.jump-bar` — Jump bar, navigators, inspector and panel toggles. Layout of the editor window; the agent reads the same facts through ide_outline, ide_diagnostics and ide_project.
- `develop.mcp-connect` — Connect or revoke an MCP server. Deliberate: connecting a server grants it access, so only the user does it; the agent uses mcp_list_tools and mcp_call_tool on approved servers.
- `develop.mcp-server` — Start or stop Kiln's own MCP endpoint. Deliberate: exposing Kiln's tools to outside agents is the user's decision, not an agent's.
- `develop.remote-pairing` — Pair phones for Kiln Remote. Deliberate: pairing grants a device control of this Mac, so an agent must not do it.
- `develop.save-buffer` — Save the editor's unsaved buffers. Buffers hold the user's unsaved typing; the agent writes files directly with write_file and the editor reloads them.
- `develop.terminal` — Interactive terminal tabs. An interactive human terminal; the agent has run_command, stream_command and background_command instead.
- `devices.live-view` — Live screen view. A continuous human view; the agent takes device_screenshot frames on demand.
- `images.prompt-library` — Save prompts and styles. Gap: prompt and style library edits are GUI-only; image_generate accepts a style name.
- `images.queue-controls` — Cancel or clear queued generations. image_generate runs to completion inside one tool call; the visible queue is for GUI jobs.
- `images.search-remote` — Search Hugging Face, Civitai and Draw Things' list. Gap: the agent only sees the curated catalogue; remote search results carry untrusted descriptions and need a vetted adapter.
- `images.send-to-media` — Send a picture to the Media gallery. Gap: no tool yet; the file path from image_history can be opened with media_open.
- `lab.compute-perplexity` — Compute perplexity. Gap: no tool yet for perplexity or prompt optimization (docs/13, Model Lab).
- `lab.edit-training-config` — Edit training configuration and compare runs. Gap: training configuration edits and experiment comparison have no tool yet (docs/13).
- `lab.model-download` — Download a model into the library. Gap: model download has no tool yet (docs/13); lab_start_lora takes allow_download for its own base model only.
- `lab.playground` — Playground chat and compare runs. Gap: prompting a lab model from the playground has no tool yet; the Agent activity chats with the same registry models.
- `lab.red-team` — Run a red-team assessment. Gap: no tool yet for red-team assessment or report export (docs/13, Model Lab).
- `media.delete-item` — Delete a generated item. Gap: deleting library items has no tool yet; destructive, so it needs an approval-gated adapter.
- `media.playback-controls` — Play, seek, speed, zoom, waveform. Interactive viewing controls; media_open with play and rate sets up playback for the agent.
- `media.reveal-copy` — Reveal in Finder, copy. Hand-off to Finder and the clipboard for the user; the agent already has the file path from media_list.
- `notifications.preferences` — Choose which notices Kiln sends and allow Focus status. Deliberate: what interrupts the person, and whether Kiln may read their Focus, are the person's settings, not an agent's.
- `slack.connect` — Paste or remove the Slack token. Deliberate: the token is a credential the person pastes into Kiln and never gives to a model, and an agent must not be able to connect or disconnect an account.
- `swarm.inspect` — Inspect a run's tasks and team channel. Gap: no top-level tool yet to read a run's plan, results or channel; tracked in docs/13 (Swarm row).
- `swarm.run` — Run a goal with a team. Gap: no top-level tool yet to create a swarm run; tracked in docs/13 (Swarm row).
- `swarm.stop` — Stop a swarm run. Gap: no top-level tool yet to cancel a swarm run; tracked in docs/13 (Swarm row).

## Streaming behavior

Plain chat updates `ChatSession.streamingText` for each provider delta. Agent mode now emits `textDelta` events while its provider stream is still open, instead of waiting for a complete turn. Partial output is cleared when a transient failure triggers a retry, and when a text-only reply is recognized as a tool call. The final persisted response continues to use the completed, redacted turn.

Streaming redaction is heuristic. The accumulated visible text is rechecked as chunks arrive; a previously emitted prefix is replaced if a split secret becomes recognizable. This is not a guarantee that an incomplete secret fragment is never briefly visible. Text content is not written to the audit log.

## Extension contract

A new application action should:

1. Call the same service used by the GUI, rather than drive private view state or simulate clicks.
2. Declare its read/write/execute permission and consequences before registration.
3. Accept stable IDs and bounded parameters; reject missing or ambiguous targets.
4. Return structured status and artifact IDs, including partial, blocked and failed outcomes.
5. Preserve cancellation and report cancellation as requested until the coordinator reaches its final state.
6. Include behavior tests for the real service boundary, permissions and failure handling.

Create ML classifier job construction and dataset validation now live in `ModelLabModule.classifierTrainingJob`, used by both the GUI and `lab_start_training`. The action targets an exact existing draft/failed/cancelled experiment, permits only a local library-contained dataset, validates saved settings, writes a unique artifact, and refuses to start while any training coordinator is active. It reports that training has started, not that it has succeeded; use `lab_get_experiment` to follow the outcome. LoRA/distillation and other start actions still need shared configuration builders and explicit resource limits.

## Current verification

The repository's live QA has exercised file and shell tools, reverse-engineering import/string search, Model Lab hardware reporting over MCP, shared approval gates, and a hosted researcher → implementer → reviewer swarm. Plain chat has answered through Apple Foundation Models, local Ollama, Ollama Cloud, NVIDIA NIM and OpenRouter. A smaller local model has also failed tool-use scenarios; provider connectivity alone does not establish agent reliability.

The new streaming and Model Lab status/cancel adapters have syntax checks and focused regression tests in source. Their runtime test result must be recorded after the integrated Xcode test run completes.

## Classifier training start (2026-11-02)

The `lab_start_training` adapter uses the same `startClassifierExperiment` service as the GUI's Create ML button. It accepts only an experiment ID, so it cannot replace the saved dataset or hyperparameters in the tool call. Starting a job is execution-gated, and only one training coordinator may be active. Completed experiments must be preserved by creating a new experiment rather than restarting them in place.

Six focused regression tests passed for the status/cancel/start tool contracts and classifier job validation, including path traversal, symlink escapes, missing datasets, invalid fractions and unique output paths. This verifies construction and failure handling; a real agent-driven classifier lifecycle through training completion, artifact reload and GUI inspection still requires an end-to-end check. LoRA/distillation start and the remaining lifecycle adapters remain open work; experiment creation, prediction, evaluation and export are described below.

## Dataset → training → evaluation → export, driven by the agent (2026-11-02)

A hosted model (Ollama Cloud `gemma4:31b`, Workstation Agent profile, Kiln Debug build from this commit range) ran the whole lifecycle with `lab_*` tools only: `lab_import_dataset` on a 120-row two-class CSV → `lab_create_experiment` (text classification, `text` → `label`) → `lab_start_training` → `lab_get_experiment` (validation accuracy 1.0) → `lab_export_model` (core_ml) → `lab_evaluate_predictions`. The exported `.mlmodel` was then compiled with `coremlcompiler` and loaded with CoreML outside Kiln, where it classified "Absolutely wonderful, I love it" as positive and "Terrible, a total waste of money" as negative. A first export attempt failed because the tool took a *file* destination while the exporter copies into a *folder*; the tool now takes `destination_folder` and says so. The dataset and experiment remain in the Model Lab library as QA data.

## Small language model from scratch, driven by the agent (2026-11-02)

With `lab_import_dataset` → `lab_start_small_lm` (100 iterations, 64 dimensions, 2 layers over an 11 KB text corpus) → `lab_get_experiment`, a hosted model (Ollama Cloud `gemma4:31b`, Workstation Agent) trained a small transformer on this Mac's GPU to completion (final training loss 0.493, artifact registered). The GUI and the tool build the job through the same `ModelLabModule.smallLMJob` and validator. `lab_start_lora` now exists behind a download policy (`ModelDownloadPolicy`: valid `org/name`, cached or explicitly allowed); `lab_start_distillation` uses the same policy for its teacher ("apple" or a cached MLX repo) and student.

## Agent platform (memory, commands, hooks)

| Area | Service-backed agent access | Missing application actions |
| --- | --- | --- |
| Memory files | `kiln_memory_read` (read), `kiln_memory_write` (write; approval; only KILN.md / AGENTS.md / CLAUDE.md in the project or user folders; audit `memory.saved`) | `@import`, per-directory files |
| Slash commands | `kiln_command_list`, `kiln_command_expand` (read), `kiln_command_write` (write; approval; built-in names refused; audit `command.saved`) | Palette entries |
| Hooks | `kiln_hooks_list` (read). Hooks themselves run in every agent run and external MCP call that goes through the orchestrator's `run`; MCP `callTool` does not run hooks yet | Hook editing by the agent (edit `.kiln/hooks/hooks.json` with the file tools, which need approval) |
| Plan mode, rewind, sessions, budget | Deliberately not agent actions (a plan is approved, rewound and budgeted by the person); `kiln_checkpoint_list`, `kiln_usage_report` read-only | Sessions list has no tool until the conversation store is reachable from tools |
| Usage | `kiln_usage_report` (read) | Prices and budget are set by the person only |
| Schedules | `kiln_schedule_list` (read), `kiln_schedule_write` (write; approval; interval ≥ 5 min; audit `schedule.saved`) | |
