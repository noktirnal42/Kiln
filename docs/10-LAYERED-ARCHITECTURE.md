# SuperMetaApp — Layered Architecture & Component Harvest Map

> **Revision note**: This document supersedes the "port app X as module Y" framing in the earlier specs. We **reuse code, not apps**. Existing projects are treated as **component libraries** — their features are harvested, regrouped by function, and composed in new ways. No existing app ships as a unit.

---

## 1. The Layered Model

```
┌─────────────────────────────────────────────────────────────────┐
│  LAYER 3 — ACTIVITIES (UI arrangements, not separate apps)      │
│  Develop · Analyze · Lab · Orchestrate                          │
│  Each activity composes shared UI surfaces differently          │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│  LAYER 2 — DOMAIN ENGINES (pure logic, no UI)                   │
│  agent-runtime · swarm-orchestrator · training · analysis ·     │
│  build-adapters · lldb-bridge · policy · audit                  │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│  LAYER 1 — CORE SERVICES (single implementations, shared)       │
│  model-providers · mcp · terminal · git · file-index ·          │
│  editor-core · lsp · approval · settings · keychain             │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│  LAYER 0 — KERNEL (app shell)                                   │
│  module system · event bus · workspace · persistence · kernel   │
└─────────────────────────────────────────────────────────────────┘
```

**The rule that prevents "clunky building blocks":** every service exists **once**. The chat view, the playground, a swarm agent, and the IDE's AI completion all call the *same* provider layer. The IDE and the swarm both use the *same* terminal service. There is no per-module duplicate of anything.

---

## 2. Why Regrouping Matters — Examples

The existing projects each solved overlapping problems independently. SuperMetaApp keeps the **best implementation of each component** and deletes the duplication:

| Capability | Duplicated in existing projects | SuperMetaApp decision |
|------------|--------------------------------|----------------------|
| Model providers | OpenClaudeCodexDesktop (7 providers), AppleHarness (Foundation+MLX), System5 (Anthropic/OpenRouter/Ollama/openai-compat) | **One** `ModelProviders` service; harvest each provider from whichever implementation is strongest |
| Tool-call agent loop | OpenClaudeCodexDesktop AppTools, AppleHarness AgentRuntime+ToolRuntime, System5 orchestrator | **One** `AgentRuntime` engine; chat AND swarm both run on it |
| MCP client | OpenClaudeCodexDesktop MCP, System5 (implicit), ghidraclone (axiom CLI/MCP server) | **One** `MCPService`; the axiom MCP tool surface becomes tools *served by* the app, not a separate server |
| Terminal/PTY | OpenClaudeCodexDesktop TerminalService, AppleHarness TerminalBridge | **One** `TerminalService`; surfaced in Develop and in agent tool calls identically |
| Policy + approvals | System5 policy.py/approvals, AppleHarness ExecutionPolicy/ApprovalCenter | **One** `PolicyEngine` + `ApprovalCenter`; both single-agent and swarm traffic flows through them |
| Model storage | AppleHarness private cache, Axiom RE universal store, ModelLab store | **One** Universal Model Store (HF_HUB_CACHE layout) |
| Audit log | System5 audit.py (hash-chained, tested) | **One** `AuditService`; used by agents, swarm, RE, training runs |
| File indexing | OpenClaudeCodexDesktop FileIndexService, RealNexus FTS5 architecture | **One** `FileIndexService` |
| Git | OpenClaudeCodexDesktop GitService, AppleHarness WorkspaceManager git bridge | **One** `GitService` |

---

## 3. Activities (Layer 3) — How It Feels Integrated

The five capabilities are not five windows. They are **activity modes** of one app sharing one workspace. The user switches activities from the toolbar; panels (chat, terminal, inspector, issues) persist across activities.

### 3.1 Develop
```
┌──────────┬───────────────────────────────┬──────────────┐
│ Navigator│  Editor (editor-core + LSP)   │  Inspector   │
│ (files,  │                               │ (variables,  │
│ targets, │                               │  properties) │
│ tests)   ├───────────────────────────────┤              │
│          │  Bottom dock (tabbed):        │  Chat panel  │
│          │   Terminal · Debug · Issues · │  (agent with │
│          │   Build Log · Test Results    │  repo tools) │
└──────────┴───────────────────────────────┴──────────────┘
```
Composes: editor-core, LSP, build-adapters, lldb-bridge, TerminalService, GitService, chat panel (AgentRuntime with code tools).

### 3.2 Analyze
```
┌──────────┬───────────────────────────────┬──────────────┐
│ Binary   │  Disassembly / Decompilation  │  Inspector   │
│ tree:    │  (synced panes)               │ (xrefs,      │
│ functions│                               │  strings,    │
│ strings  ├───────────────────────────────┤  crypto hits)│
│ sections │  Hex viewer · Call graph      │              │
│          ├───────────────────────────────┤  Chat panel  │
│          │  Tool belt dock: crypto ·     │  ("explain   │
│          │  entropy · decrypt · rules ·  │   this fn")  │
│          │  gadgets · forensics          │              │
└──────────┴───────────────────────────────┴──────────────┘
```
Composes: analysis engine (harvested AxiomCore components), hex viewer, chat panel (AgentRuntime with RE MCP tools).

### 3.3 Lab
```
┌──────────┬───────────────────────────────┬──────────────┐
│ Registry │  Playground / Training board  │  Inspector   │
│ (models, │                               │ (metrics,    │
│ datasets,├───────────────────────────────┤  run history)│
│ runs,    │  Datasets · Evals · Distill   │              │
│ exports) │  · Red team                   │  Chat panel  │
│          │                               │              │
│          │  (playground reuses the SAME  │              │
│          │   chat surfaces as Develop)   │              │
└──────────┴───────────────────────────────┴──────────────┘
```
Composes: training engines, eval engine, Universal Model Store, chat surfaces (shared with Develop/Analyze).

### 3.4 Orchestrate
```
┌──────────┬───────────────────────────────┬──────────────┐
│ Swarms   │  Task graph / Agent activity  │  Inspector   │
│ (runs,   │                               │ (bus feed,   │
│ agents,  ├───────────────────────────────┤  audit tail) │
│ policies)│  Coordination bus timeline    │              │
│          ├───────────────────────────────┤  Approvals   │
│          │  Shared workspace view        │  queue       │
└──────────┴───────────────────────────────┴──────────────┘
```
Composes: swarm orchestrator, PolicyEngine, ApprovalCenter, AuditService — and its agents are the **same** AgentRuntime used everywhere, just N instances.

### Cross-activity integration (what makes it feel like one app)

- The **chat panel is one component** used in all four activities — only its tool surface changes by context.
- **Approvals are global**: a file-write approval from a swarm agent interrupts you in Develop exactly as in Orchestrate.
- **Artifacts** created anywhere are browsable everywhere.
- A swarm task can *open Develop* on the repo it's working in; clicking a file in the bus feed jumps to it.
- RE findings can be handed to Lab (e.g., extracted crypto material → ML feature vectors) via the event bus.

---

## 4. Component Harvest Map

For each component: **source of truth** (the existing implementation to harvest), **destination layer**, and notes. "Port" means adapt into the layer's package with tests retained.

### Layer 0 — Kernel

| Component | Harvest from | Notes |
|-----------|-------------|-------|
| Project scaffolding, project.yml/XcodeGen patterns | OpenClaudeCodexDesktop, AppleHarness | Build config conventions only |
| SwiftData schema (Conversation, Message, Artifact) | OpenClaudeCodexDesktop Core/Models | Extend with Workspace, Run, TrainingJob |
| Settings (UserDefaults + layered config) | AppleHarness Preferences + System5 config.py layering | Merge |
| Ring-buffer logging | AppleHarness AppLog | As-is |
| App paths | AppleHarness AppPaths | As-is |

### Layer 1 — Core Services

| Component | Harvest from | Notes |
|-----------|-------------|-------|
| Provider protocol + capability OptionSet | OpenClaudeCodexDesktop (primary) | Merge deltas AppleHarness learned |
| Ollama/OpenRouter/NIM/custom-endpoint providers | OpenClaudeCodexDesktop | Port |
| Apple Foundation provider (availability gating, exact unavailability reasons) | AppleHarness FoundationModelsProvider + AILab | AppleHarness is the more complete one; AILab has the honest-availability UX pattern |
| MLX provider | AILab MLXInferenceProvider | Keep `MLX.compile(enable:false)` workaround; keep "verified in GUI, fragile in CLI" notes |
| Ollama Cloud / OpenAI-compatible client | System5 providers/openai_compatible.py | Port logic, not Python |
| Reasoning config + per-provider mapping | OpenClaudeCodexDesktop Reasoning | As-is |
| Universal Model Store | Axiom RE Intelligence/ModelStore + AppleHarness UNIVERSAL_MODEL_STORE.md | HF_HUB_CACHE chain, `models--org--repo` walk, adopt/verify |
| HF model/dataset search + resumable downloads | AILab HuggingFaceClient, Axiom RE ModelStore | Merge |
| MCP client (transports, registries) | OpenClaudeCodexDesktop MCP | Port; adopt System5's key-handling discipline |
| Terminal/PTY (SwiftTerm) | OpenClaudeCodexDesktop TerminalService | Port |
| Git (libgit2) | OpenClaudeCodexDesktop GitService | Port |
| File index (Spotlight + FTS5 + FSEvents) | OpenClaudeCodexDesktop FileIndexService; RealNexus FTS5 schema ideas | Port + extend |
| Editor core (buffer, highlighting, folding) | **New** (CodeY/OpenXcode as learnings only) | Greenfield — this is the one big build |
| LSP client | New | sourcekit-lsp first |
| Approval engine (queue, grants, revocation) | System5 approvals + AppleHarness ApprovalCenter | Merge — System5 has persistence/revocation, AppleHarness has UI integration |
| Secret redaction | AppleHarness SecurityPermissions | Port |

### Layer 2 — Domain Engines

| Component | Harvest from | Notes |
|-----------|-------------|-------|
| Agent tool-call loop | AppleHarness AgentRuntime (dual-gate design) | Port; generalize so swarm = N instances |
| Tool registry + 16 built-in tools | AppleHarness ToolRuntime | Port |
| Execution policy | AppleHarness (pre-model filter) + System5 policy.py (declarative rules) | **Merge both halves** — this is the key regrouping |
| Declarative allow/approve/deny rules | System5 policy.py | Port rules engine + its tests |
| Sandbox backends (docker/seatbelt/subprocess) | System5 sandbox/ | Port |
| Egress proxy (SSRF backstop) | System5 proxy/egress_gateway.py | Port |
| Behavior monitor (tripwires + rubric) | System5 monitor.py | Port |
| Hash-chained audit | System5 audit.py | Port — tamper + tail-truncation tests included |
| Swarm orchestration (pool, bus, decompose) | System5 orchestrator.py/bus.py | Port; consensus flagged experimental |
| Training: CreateML paths | AILab CreateML providers | Port (verified working) |
| Training: MLX LoRA | AILab MLXFineTuningProvider | Port with documented caveats |
| Training: from-scratch char-LM | AILab | Port (verified) |
| Distillation pipeline | AILab | Port (verified end-to-end) |
| Eval metrics, auto-prompt, red-team | New | Greenfield, thin layer over engines |
| RE analysis core (import, inspection, engines) | AxiomCore Analyzer, UniversalBinary, EngineWorker | Port faithfully — tested code |
| RE tool belt (crypto/entropy/carve/decrypt/YARA/ROP/forensics/device) | AxiomCore ToolBelt | Port faithfully — tested code |
| RE project store (revisions, edit log) | AxiomCore Models.swift | Port |
| Build adapters (swiftpm, xcodebuild) | New; OpenXcode re-analysis as reference | Greenfield but thin (process + parse) |
| LLDB MI2 bridge | New; modeled on AxiomCore EngineWorker actor pattern | Reuse the worker pattern, not the code |

### Layer 3 — Activities & Shared UI

| Component | Harvest from | Notes |
|-----------|-------------|-------|
| Chat surfaces (ConversationView, MessageBubble, Composer, ReasoningView) | OpenClaudeCodexDesktop UI | Port **once**, used in all activities |
| Artifacts system | OpenClaudeCodexDesktop ArtifactService | Port |
| Model picker + reasoning panel | OpenClaudeCodexDesktop | Port |
| Design system | New; AppleHarness UI conventions | Greenfield |
| Swarm dashboard views | New (System5's browser GUI is the reference UX) | Greenfield |
| RE views (disasm/decomp/hex/graphs) | New | Greenfield over ported engine |
| Lab views | New over ported engines; AILab Playground as reference | Mostly new |
| IDE views | New | Greenfield |

---

## 5. Regrouped Feature Set (what the user actually gets)

Features are regrouped by *function*, not by origin project:

1. **One conversation system** — chat, playground, agent sessions, and swarm agent transcripts are all the same object type with different tool surfaces.
2. **One approval system** — human-in-the-loop applies identically to a single agent, a swarm, a build script, or an RE auto-decrypt sweep.
3. **One audit trail** — agents, swarm, RE, training, and builds all write to the same hash-chained log.
4. **One model layer** — "which model" is a global choice with per-activity overrides, not per-app configuration.
5. **One terminal** — the same PTY instance can be attached to the editor dock, driven as an agent tool, or captured by a swarm sandbox.
6. **One workspace** — Develop/Analyze/Lab/Orchestrate all operate on the same workspace object; switching activities never reloads state.

---

## 6. Impact on the Other Documents

- **00-MASTER-SPEC**: the "Module Inventory" table and the `Modules/` tree are superseded by this document's layers + activities. The contracts, security model, and targets remain valid.
- **01-MODULAR-ARCHITECTURE**: module manifests remain, but modules are now *activities + engines*, not ported apps; capability grants apply at the activity level.
- **02–06 module specs**: their *content* (components, protocols) remains the implementation guide; their framing changes from "port project X" to "build activity Y over harvested components." The harvest map above is the authoritative source→destination mapping.
- **08-ROADMAP**: phase order unchanged; wording of work items now means "harvest component → integrate into layer" rather than "port app."
- **09-AGENT-PROMPTS**: prompts 1–7 remain usable but should be read with this map in hand — "port from" now always means the specific component listed here, and shared services are built **once** in Phase 0/1, not per-module.

---

## Document Version

- **Version**: 2.0 (component harvest revision)
- **Date**: 2026-10-17
- **Supersedes**: per-app module framing in 00–06