# Parity and beyond (2026-11-09; chat-platform rows updated 2026-11-12)

The product goal: one workstation that is as good as the best standalone app in each area, and better than
Claude Code Desktop and the Codex app because everything is wired together. Status words below are honest:
**have** (works, verified), **partial**, **missing**. Nothing here is "done" until it has been seen working in the app.

## 1. The integration rule (applies to every feature)

A capability is not finished until all of these exist:

1. A **service** in `Core/` with no UI dependency (the single code path).
2. A **GUI** surface in its activity, using the shared chrome (`SSActivityHeader`, `SSPaneHeader`, `SSEmptyState`).
3. An **agent tool** (`<module>_*`) and the same tool over **MCP**, with the right permission level
   (read / write / execute) so approvals work like every other tool.
4. A **command-palette entry** and, where it fits, a starter prompt.
5. An **audit record** (the tamper-evident chain) for anything that changes state.
6. **Tests**, plus a look at the running app.

Enforcement (to build): a `CapabilityRegistry` that every GUI action registers with (id, title, tool name or an explicit
reason it has none). A test fails when a GUI capability has neither an agent tool nor a recorded exemption, so a
feature cannot ship as GUI-only.

## 2. Parity with Claude Code Desktop and the Codex app

| Area | Status | Gap to close |
|---|---|---|
| Agent loop, tool approvals, Ask/Auto/Bypass | have | Per-tool and per-path rules editable in a Permissions pane |
| Context meter, compaction, `/compact`, graceful pause | have (merged 2026-11-09; GUI unverified by its author) | Persist compaction across relaunch; show what was cleared |
| Collapsed tool calls in the thread | have (same caveat) | Diff view for edits, inline command output |
| MCP client and MCP server | have | Per-server permissions UI, OAuth for remote servers |
| Computer use, browser, devices | have / new | Fold into one "Environment" permission surface |
| Skills (`list_skills`, `read_skill`) | partial | Authoring UI, project and user scopes, install from a folder or URL |
| Slash commands (custom, project-level) | have (built 2026-11-09; unit-tested, not seen in the running app) | Palette (⌘K) entries for custom commands |
| Hooks (pre/post tool, on stop, on prompt) | have (built 2026-11-09; unit-tested, not seen in the running app) | Hook results shown in the thread |
| Memory files (`AGENTS.md`, `CLAUDE.md`, `KILN.md`) | have (built 2026-11-09; unit-tested; the pane sits behind the brain button beside the context meter) | `@import` lines, nested per-directory files; the brain button is now the reasoning control and Memory moved to the composer's "+" menu (2026-11-12, see section 8 of doc 30) |
| Plan mode (read-only exploration, then approve a plan) | have (built 2026-11-09; unit-tested, not seen in the running app) | Plan card polish |
| Checkpoints and rewind (files and conversation) | have (built 2026-11-09; unit-tested; edit and resend was seen on screen 2026-11-12) | Commands are listed as not undone |
| Parallel sessions, worktree isolation, background tasks | partial (swarm, remote, a sessions list with fork and resume) | Runs do not continue in the background while another conversation is open; worktree per task |
| Subagents | partial (swarm) | Spawn from a chat turn, with their own context and a summary back |
| Diff review (accept / reject hunks, inline comments to the agent) | partial (Git panel) | Review pane that feeds comments back as a task |
| Git/PR workflow (branch, commit message, PR, CI watch, review comments) | partial | `gh`-backed PR pane and tools; CI status in the status strip |
| Scheduled and recurring tasks, triggers | missing | Cron-like schedules that run an agent profile; notifications |
| Usage, cost and limits view | missing | Per-provider tokens and cost, daily totals, budgets that stop a run |
| Model routing and fallback | partial | Rules by task and privacy tier; fallback on failure or rate limit |
| Attachments, vision, drag and drop, `@` mentions | partial | Images and PDFs in chat, `@file`, `@function`, `@page`, `@device` |
| Voice in and out | partial (Media session added STT/TTS) | Push-to-talk in the composer, spoken replies |
| Notifications when an agent needs you | unknown | Dock badge, system notification, approvals inbox |
| Settings layers (user, project, enterprise policy) | partial | `.kiln/settings.json` layered over user settings |

## 3. Beyond them (features neither has that suit this suite)

1. **Evidence ledger and run bundles.** The audit chain is already tamper-evident. Export any agent run as a signed,
   replayable bundle (prompts, tool calls, results, artifacts, hashes) that another Kiln can verify and replay offline.
   Useful for reverse-engineering reports, security work and code review.
2. **Pinboard (context tray).** Pin any object from any activity into the agent's context with provenance: a function and
   its pseudocode, a string, a page selection, a device frame, a dataset slice, a media clip, a file range. The meter shows
   what each pin costs. One drag instead of copy and paste between tools.
3. **Workflows.** Saved, parameterised pipelines that cross modules, runnable by hand, on a schedule, or as a single agent
   tool: download a package, analyze it, decompile the entry points, summarize findings, write a report. Start as an
   ordered list of tool calls with variables; a graph editor comes later.
4. **Closed-loop app analysis.** Run an app in a simulator, capture its network traffic and screens, and link observed
   endpoints and strings to the decompiled functions that produce them (Devices, Browser, Analyze together).
5. **Verifier agent.** A second, independent model re-checks the main agent's claims against the recorded tool evidence
   and flags unsupported statements (extends the existing rubric monitor and "say plainly what you did not verify").
6. **Privacy tiers and local-first routing.** Per project: local only, local first, any. The router picks a model by task
   and tier, and the egress policy (already used by `browser_open`) enforces it across every module.
7. **Time-travel workspace.** Checkpoints that span files, RE annotations, lab experiments, browser tabs and the
   conversation, so "rewind to before the agent renamed 200 functions" is one action.
8. **Mission control.** One strip and pane for everything running: agents, swarm workers, downloads, trainings, devices,
   transcriptions, with the approvals inbox in the same place.
9. **Project knowledge graph.** A local index linking functions, files, pages, datasets and the agent's notes, with local
   embeddings for search; the agent queries it through `knowledge_*` tools.
10. **Policy as code.** `.kiln/policy` governs tools, paths, egress and spend for every module, versioned with the project.
11. **Agent-driven QA.** Record a session on a simulator and turn it into a repeatable regression run the agent can execute.

## 4. "Best standalone alternative" bar, per module

Each module is measured against the best standalone app in its area. The list is the must-have set; anything missing
is a tracked gap, not a footnote.

| Module | Benchmark apps | Must-haves not yet met (known) |
|---|---|---|
| Develop (IDE) | Xcode, Zed, VS Code | Jump bar and symbol outline, code completion (LSP), refactor/rename, build/run/test with a scheme picker, debugger variables/threads UI, Interface Builder-class previews are out of scope, source control gutter, multi-root workspaces |
| Analyze (RE) | Ghidra, IDA, Hopper, Axiom RE | Graph view, structures/types editor, patching, scripting console, diffing two binaries, YARA/signature scans in the UI, debugger link, Kiln-branded listing with xrefs everywhere |
| Lab (ML) | LM Studio, Ollama, Draw Things (for image) | Model browser with one-click download for every format, quantization and conversion, benchmark runs, fine-tune runs with live curves, prompt playground with compare |
| Image studio | Draw Things, ComfyUI, InvokeAI | See section 5 |
| Browser | Safari, Arc | History, bookmarks, downloads manager, reader view, content blockers, devtools-lite (network, DOM), profiles |
| Devices | Xcode Simulator, Android Studio emulator, UTM | Windows and Linux guests, snapshots, network conditioning, logs and crash reports, record/replay, push and deep-link tools |
| Media | IINA, QuickTime, Descript | Timeline trim and export, subtitle tracks, batch transcribe with diarization, voice library, clip search |
| Voice | MacWhisper, Superwhisper | Push-to-talk anywhere, model choice, custom vocabulary, spoken agent replies |
| Swarm | Claude Code subagents, Codex parallel tasks | Task board, per-worker context and cost, review before merge |

## 5. Image studio (FLUX, SDXL and everything Draw Things offers)

Goal: pick any popular open image model from a catalog, download it once to the universal model store, and generate,
edit and upscale with it from the GUI, the agent and MCP.

- **Catalog.** Curated list with sizes, licenses and "needs a Hugging Face token" flags: SD 1.5, SD 2.1, SDXL base and
  refiner, SDXL Turbo and Lightning, SD 3.5, FLUX.1 schnell and dev, Playground, Pony-family and other SDXL fine-tunes,
  Qwen-Image, plus LoRAs, ControlNets, VAEs and upscalers. Sources: Hugging Face and Civitai (user supplies tokens in
  Settings; Kiln never stores or prints them). Licensing and gating are shown before download; FLUX.1 dev is non-commercial.
- **Downloader.** Resumable, checksum-verified, disk-space check, progress and queue, location in the universal store (the
  external drive when present). Reuses `Core/ReverseEngineering/PackageIntake.swift` patterns and `DownloadManager`.
- **Engines behind one protocol.** (a) In-process on Apple silicon (MLX Swift stable-diffusion, Core ML Stable Diffusion),
  to be chosen by a short research spike that measures speed and memory for SDXL and FLUX on this Mac; (b) external
  backends when installed or running: Draw Things' local HTTP API, ComfyUI, AUTOMATIC1111/Forge. A backend that is not
  there shows a setup state; nothing fake is ever shown as output.
- **Features.** Text-to-image, image-to-image, inpaint and outpaint, ControlNet, LoRA stack with weights, samplers and
  schedulers, seeds, batch, aspect presets, upscale and face fix, queue, prompt library and styles, history with the
  generation settings embedded in each file, "send to Media" and "use as reference".
- **Agent and MCP.** `image_list_models`, `image_download_model` (write, approval), `image_generate` (write), `image_edit`,
  `image_upscale`, `image_history`, with the same permission model as other tools.

## 6. Delivery

Work runs as parallel sessions, each in a worktree and each ending in a branch. Known merge hot spots are the shell
registration files (`WorkstationModel`, `MainWindow`, `WorkstationSidebar`, `AppModel`, `AgentProfile`, `ExecutionPolicy`);
the first task of the integration session is to replace those per-module edits with a registry so modules stop
colliding. Order of value: (1) integration rule and `CapabilityRegistry`; (2) agent-platform parity (slash commands,
hooks, memory files, plan mode, checkpoints, sessions list, usage view); (3) image studio; (4) Develop and Analyze to the
Xcode and Ghidra bar; (5) the novel features in section 3, starting with Pinboard, Workflows and run bundles.

Definition of done for any item: service, GUI, agent tool, MCP, palette entry, audit record, tests, and a screenshot of it
working in the app, recorded under `docs/qa/`.
