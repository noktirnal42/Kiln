# Kiln — Documentation Library

**A unified, native macOS application (Swift 6, Xcode 27) combining a development platform, reverse engineering console, AI/ML model lab, AI agentic harness, and multi-agent swarming engine — organized as a layered architecture (Kernel → Core Services → Domain Engines → Activities) in one cohesive app.**

> **Reorganization principle (v2)**: We **reuse code, not apps**. Existing projects in `/dev` are component libraries — features are harvested, regrouped by function, and composed in new ways. Every service exists **once** and is shared across all activities. No existing app ships as a unit. The authoritative blueprint is **10-LAYERED-ARCHITECTURE.md**.

---

## Document Index

| # | Document | Contents |
|---|----------|----------|
| **00** | [MASTER-SPEC.md](00-MASTER-SPEC.md) | Vision, feature regrouping by function, unified architecture, data flow, security model, dependencies, performance targets, success criteria |
| **01** | [MODULAR-ARCHITECTURE.md](01-MODULAR-ARCHITECTURE.md) | Module system design: manifests, lifecycle, capability-based access control, service registry, event bus, workspace integration, Plugin SDK, marketplace, testing strategy |
| **02** | [DEV-PLATFORM.md](02-DEV-PLATFORM.md) | IDE capability set: source editor + LSP, project navigator, SwiftPM/xcodebuild build system, LLDB debugger, test runner, git UI, device/simulator manager, templates, extension points |
| **03** | [REVERSE-ENGINEERING.md](03-REVERSE-ENGINEERING.md) | RE capability set: binary import, Ghidra headless + radare2 engines, decompiler, function/xref analysis, crypto scanner, auto-decryptor, YARA rule scanner, ROP/JOP gadgets, dump forensics, device bench, scripting, guardrails |
| **04** | [MODEL-LAB.md](04-MODEL-LAB.md) | ML capability set: unified model registry + universal store, CreateML/MLX LoRA/distillation/from-scratch/RL training engines, evaluation + auto-prompt + red-team, quantization/export, hardware awareness |
| **05** | [AGENTIC-CONSOLE.md](05-AGENTIC-CONSOLE.md) | Agent capability set: 7 model providers (Ollama, Ollama Cloud, OpenRouter, NIM, Apple FM/PCC, MLX, custom), reasoning controls, chat + artifacts, terminal, MCP client, agent runtime + tools, skills |
| **06** | [SWARMING-ENGINE.md](06-SWARMING-ENGINE.md) | Swarm capability set: orchestration, task decomposition, agent types, coordination bus + shared memory, consensus (experimental), sandbox backends (Docker/seatbelt/subprocess), approval queue, behavior monitor, hash-chained audit log |
| **07** | [INTEGRATION-PATTERNS.md](07-INTEGRATION-PATTERNS.md) | The glue: 6 core integration patterns, plugin architecture + marketplace, cross-activity workflows, security boundaries, extension points, layered configuration, contract testing, observability |
| **08** | [ROADMAP.md](08-ROADMAP.md) | 7 phases across ~46 weeks with work items, estimates, exit criteria, dependency graph, risk register, resourcing notes, definition of done |
| **09** | [AGENT-PROMPTS.md](09-AGENT-PROMPTS.md) | 11 ready-to-use agent prompts (one per major work unit) + standing agent rules + verification prompts for building the app incrementally with AI agents |
| **10** | [LAYERED-ARCHITECTURE.md](10-LAYERED-ARCHITECTURE.md) | **The authoritative blueprint**: 4-layer model, 4 activities (Develop · Analyze · Lab · Orchestrate), and the complete **Component Harvest Map** — every component, its source project, and its destination layer |

---

## How the Architecture Works (v2)

```
LAYER 3  ACTIVITIES — Develop · Analyze · Lab · Orchestrate
         (UI arrangements; panels persist across activities)
LAYER 2  DOMAIN ENGINES — agent-runtime · swarm · training ·
         analysis · build · lldb · policy · audit (pure logic, no UI)
LAYER 1  CORE SERVICES — providers · mcp · terminal · git ·
         file-index · editor-core · lsp · approval · keychain
         (ONE implementation of each, shared by everything)
LAYER 0  KERNEL — module system · event bus · workspace · settings
```

Key consequences:
- The **chat panel is one component** — used in Develop (pair programming), Analyze (explain a function), Lab (playground), and Orchestrate (swarm monitoring); only its tool surface changes by context.
- A **swarm agent is the same AgentRuntime** as the chat assistant — just N instances with different profiles.
- **Approvals and audit are global** — a swarm's file-write approval interrupts you in Develop exactly as it would in Orchestrate.
- Overlapping implementations across the old projects (e.g., four separate model-provider stacks) are **merged into one** harvest of the strongest parts.

---

## Key Findings from the /dev Survey

The removable drive contains **~220 projects**; the survey identified these as **component sources** (harvest targets, not shipping units):

| Existing Project | Components We Harvest | Destination Layer |
|------------------|----------------------|-------------------|
| **OpenClaudeCodexDesktop** | 5 of 7 providers, MCP client, chat/artifacts UI, terminal (SwiftTerm PTY), git, file indexing, reasoning config | Layers 1 + 3 |
| **ghidraclone (Axiom RE)** | RE analysis core (analyzers, EngineWorker pattern), entire tested ToolBelt, project store w/ revisions, universal model store, JS scripting | Layer 2 (+ Layer 1 model store) |
| **AILab (ModelLab)** | CreateML training paths, MLX LoRA fine-tuning (with crash workarounds), from-scratch LM, distillation pipeline, MLX provider, hardware profile, honest-availability UX | Layer 2 (+ provider) |
| **System5** | Policy rules engine, sandbox backends, egress proxy, hash-chained audit, approval persistence/revocation, behavior monitor, swarm orchestration + bus | Layer 2 |
| **AppleHarness (LumenDeck)** | Agent runtime dual-gate design, 16-tool registry, approval UI, settings/logging/paths, Apple Foundation provider, secret redaction | Layers 1 + 2 |
| **RealNexus** | FTS5 search patterns, source-adapter architecture, provenance discipline | Layer 1 patterns |
| **PlateWatch-Agent-Bridge** | coremltools conversion learnings, Vision pipeline patterns | Layer 2 reference |
| **NIMLauncher** | NIM integration reference | Feeds NIM provider |
| **CodeY / OpenXcode** | Editor learnings/analysis only | Layer 1 editor-core reference |

**Bottom line: roughly 60–70% of the total feature surface already exists as working, tested code. The work is harvesting components into the right layers, merging duplicates, and building the shared shell — not porting apps.**

---

## Build Order (TL;DR)

```
Phase 0  Foundation: shell + module system + demo module        (4 wks)
Phase 1  Agentic Console — the app becomes useful day one       (6 wks)
Phase 2  Model Lab          ┐
Phase 3  RE Console         ├─ parallelizable after Phase 1      (6 wks ea)
Phase 4  Swarming Engine    ┘
Phase 5  Development Platform (largest greenfield piece)         (10 wks)
Phase 6  Polish + Plugin SDK + v1.0                              (8 wks)
```

Start with the **Prompt 0** in [09-AGENT-PROMPTS.md](09-AGENT-PROMPTS.md).

---

## Design Principles (Non-Negotiable)

1. **Reuse code, not apps** — harvest components into layers; merge overlapping implementations; no old project ships as a unit
2. **One of everything** — every service (providers, terminal, git, approvals, audit, agent runtime) has exactly one implementation, shared across all activities
3. **Model-agnostic** — any provider; reasoning controls mapped per provider
4. **No fake capabilities** — unavailable features show their specific reason, never pretend success (inherited from AILab/Axiom RE discipline)
5. **Bounded everything** — size caps, row caps, recorded truncation
6. **Secrets in Keychain only** — fingerprints in outputs, never key material
7. **Dual approval gates** — policy filters tools pre-model AND approval gates execution post-model
8. **Native performance** — Swift 6 strict concurrency, actors for stores, deltas for streaming
9. **Analysis never executes** — the RE capability inspects binaries without running them

---

*Library version 2.0 — 2026-10-17 — Draft for Review (v2: layered architecture + component harvest revision)*