# SuperMetaApp — Development Roadmap & Phases

## Overview

This roadmap organizes SuperMetaApp development into phases that maximize reuse of existing, working code from the `/dev` folder. Each phase delivers a usable increment.

**Core strategy**: The existing projects (OpenClaudeCodexDesktop, Axiom RE, ModelLab, System5, LumenDeck) are individually advanced. SuperMetaApp's job is *integration*, not reinvention. Port working engines, build the shell around them.

---

## Phase Overview

```
Phase 0: Foundation & Core Shell          (Weeks 1-4)     ← START HERE
Phase 1: Agentic Console First            (Weeks 5-10)    ← Working app
Phase 2: Model Lab Integration            (Weeks 11-16)   ← AI lab live
Phase 3: Reverse Engineering Integration  (Weeks 17-22)   ← RE console live
Phase 4: Swarming Engine                  (Weeks 23-28)   ← Multi-agent live
Phase 5: Development Platform             (Weeks 29-38)   ← IDE (hardest, last)
Phase 6: Polish, Plugin SDK, Release      (Weeks 39-46)   ← v1.0
```

**Rationale for order**: Agentic Console is the most complete existing code (OpenClaudeCodexDesktop has providers, MCP, artifacts, terminal working). Model Lab and Axiom RE are self-contained engines that port cleanly. The Development Platform (Xcode clone) is the largest greenfield effort and benefits from the shared editor infrastructure built in earlier phases.

---

## Phase 0: Foundation & Core Shell (Weeks 1–4)

**Goal**: A runnable app shell with the module system, shared services, and one trivial module proving the plugin architecture.

### Work Items

| # | Item | Source | Est. |
|---|------|--------|------|
| 0.1 | Xcode 27 project + Swift 6 strict concurrency setup | New | 2d |
| 0.2 | SwiftData schema: Workspace, ModuleState, Conversation, Artifact, Settings | OpenClaudeCodexDesktop models | 3d |
| 0.3 | Module protocol + ModuleManager (lifecycle, dependency resolution) | New (spec: 01-MODULAR-ARCHITECTURE.md) | 5d |
| 0.4 | ModuleContext, ServiceRegistry, ModuleEventBus | New | 4d |
| 0.5 | Capability system (manifests, grants, runtime enforcement) | New | 4d |
| 0.6 | Settings service (layered config: env → user → workspace → defaults) | AppleHarness Preferences | 2d |
| 0.7 | Keychain service (module-namespaced) | OpenClaudeCodexDesktop | 1d |
| 0.8 | Design system (colors, typography, layout primitives, themes) | New | 4d |
| 0.9 | MainWindow + ModuleHostView (sidebar, tab bar, inspector) | New | 5d |
| 0.10 | Universal Model Store resolution (HF_HUB_CACHE chain) | Axiom RE ModelStore + AppleHarness UNIVERSAL_MODEL_STORE.md | 3d |
| 0.11 | CI: build + test matrix on macOS runners | New | 2d |

### Exit Criteria
- [ ] App launches < 2s, shows module host with one demo module
- [ ] Module loads/unloads dynamically from manifest
- [ ] Event bus delivers cross-module events
- [ ] Capability denial works (module requesting ungranted capability fails cleanly)
- [ ] Swift Testing suite green in CI

---

## Phase 1: Agentic Console First (Weeks 5–10)

**Goal**: The chat/agent experience working end-to-end — the "daily driver" that makes the app useful immediately.

### Work Items

| # | Item | Source | Est. |
|---|------|--------|------|
| 1.1 | Port ModelProvider protocol + registry | OpenClaudeCodexDesktop Core/Providers | 3d |
| 1.2 | OpenCode/Ollama provider (HTTP streaming) | OpenClaudeCodexDesktop OpenCodeProvider | 2d |
| 1.3 | OpenRouter provider | OpenClaudeCodexDesktop | 2d |
| 1.4 | NVIDIA NIM provider | OpenClaudeCodexDesktop + NIMLauncher | 2d |
| 1.5 | Apple Foundation Models provider (availability gating, graceful degradation) | OpenClaudeCodexDesktop + AILab | 3d |
| 1.6 | MLX provider | AILab MLXInferenceProvider (proven code) | 3d |
| 1.7 | Custom endpoint provider (OpenAI-compatible/vLLM/TGI) | OpenClaudeCodexDesktop | 2d |
| 1.8 | Reasoning config system + provider-specific mapping | OpenClaudeCodexDesktop Reasoning/ | 3d |
| 1.9 | Conversation persistence + branching | OpenClaudeCodexDesktop ConversationService | 4d |
| 1.10 | Chat UI: ConversationView, MessageBubble, Composer, ReasoningView | OpenClaudeCodexDesktop UI | 6d |
| 1.11 | Model picker UI with reasoning panel | OpenClaudeCodexDesktop | 4d |
| 1.12 | Artifacts system (code/MD/HTML/Mermaid/data renderers, versioning) | OpenClaudeCodexDesktop ArtifactService | 6d |
| 1.13 | Terminal: PTY via SwiftTerm, tabs, sessions | OpenClaudeCodexDesktop TerminalService | 4d |
| 1.14 | MCP client (stdio + HTTP transports, server discovery, tool palette) | OpenClaudeCodexDesktop MCP + System5 | 6d |
| 1.15 | File indexing (Spotlight + SQLite FTS5 + FSEvents) | OpenClaudeCodexDesktop FileIndexService | 4d |
| 1.16 | Git integration (libgit2 wrapper, status/diff/commit UI) | OpenClaudeCodexDesktop GitService | 4d |
| 1.17 | Agent runtime single-loop: tool calls, approval gate, execution policy | AppleHarness AgentRuntime + ToolRuntime | 6d |
| 1.18 | Built-in tools: file, shell, git, web, search | AppleHarness 16 tools + System5 | 5d |
| 1.19 | Skills system (sandboxed Swift scripts, discovery) | OpenClaudeCodexDesktop spec | 4d |
| 1.20 | Ollama Cloud support | System5 openai_compatible provider | 2d |

### Exit Criteria
- [ ] Stream chat with all 7 provider types; switch mid-conversation
- [ ] Reasoning controls map correctly per provider
- [ ] Tool calls gated by approval for write/execute permissions
- [ ] Artifacts render all 5 types; exportable
- [ ] Terminal tabs functional; MCP tool palette lists connected servers
- [ ] Memory < 300 MB idle; first token < 500ms local

---

## Phase 2: Model Lab Integration (Weeks 11–16)

**Goal**: Full AI/ML laboratory — training, fine-tuning, distillation, evaluation — embedded as a module.

### Work Items

| # | Item | Source | Est. |
|---|------|--------|------|
| 2.1 | Port ModelLabCore as framework module | AILab Packages/ModelLabCore | 5d |
| 2.2 | Unified model catalog (local MLX + HF + Apple FM in one registry) | AILab ModelRegistry + OpenClaudeCodexDesktop ModelStore | 4d |
| 2.3 | Dataset manager (CSV/JSON/JSONL import, HF datasets API) | AILab HuggingFaceDatasetProvider | 4d |
| 2.4 | CreateML training paths (text/tabular/image classifiers) | AILab (verified working) | 4d |
| 2.5 | MLX LoRA fine-tuning (with scheduler crash workarounds documented) | AILab MLXFineTuningProvider | 5d |
| 2.6 | From-scratch small LM training | AILab (verified: 500-iter run) | 4d |
| 2.7 | Automated distillation pipeline (teacher → synthetic data → student LoRA) | AILab (verified end-to-end) | 5d |
| 2.8 | Experiment tracker (runs, metrics, artifacts, comparison) | New + AILab | 5d |
| 2.9 | Playground (chat/completion/embedding modes against any registered model) | AILab Playground | 5d |
| 2.10 | Evaluation: perplexity, accuracy, BLEU/ROUGE, custom metrics | New | 5d |
| 2.11 | Auto-prompt engine (generate + optimize prompts per task) | New | 5d |
| 2.12 | Red-team harness (jailbreak/injection suites) | New | 5d |
| 2.13 | Export: CoreML, MLX package, GGUF (ONNX later) | New + PlateWatch convert_models.py learnings | 6d |
| 2.14 | Hardware profile + memory-aware warnings (18GB constraint honesty) | AILab CAPABILITIES.md approach | 3d |
| 2.15 | Benchmark runner (tok/s, latency, memory across providers) | New | 4d |

### Exit Criteria
- [ ] Train text classifier from CSV → .mlmodel → run in playground, zero network
- [ ] LoRA fine-tune Qwen3-0.6B-4bit in GUI (matches AILab verified runs)
- [ ] Distillation: Apple FM teacher → jsonl → student adapter, one click
- [ ] Every unavailable capability shows the specific reason (AILab "no fake capabilities" rule)
- [ ] Exported CoreML model loads in a DevPlatform test target

---

## Phase 3: Reverse Engineering Integration (Weeks 17–22)

**Goal**: Port Axiom RE's engine as the RE console module. This is the most code-complete existing asset — mostly integration, not writing.

### Work Items

| # | Item | Source | Est. |
|---|------|--------|------|
| 3.1 | Port AxiomCore (Models, Analyzer, ProjectStore, EngineWorker) | ghidraclone Sources/AxiomCore | 6d |
| 3.2 | Binary import + inspection (Mach-O/ELF/PE, universal binary slices) | AxiomCore | 3d |
| 3.3 | Ghidra headless + radare2 engine bridges | AxiomCore Analyzer providers | 5d |
| 3.4 | Disassembly + decompilation views | New UI over AxiomCore data | 6d |
| 3.5 | Function browser, call graphs, xrefs | New UI | 5d |
| 3.6 | String search + reference finding | AxiomCore | 3d |
| 3.7 | Tool Belt: crypto constants, entropy, format carving | AxiomCore ToolBelt (complete) | 3d |
| 3.8 | Auto-decryptor + recipes | AxiomCore ToolBelt/AutoDecryptor | 4d |
| 3.9 | Rule scanner (YARA subset) | AxiomCore RuleScanner | 3d |
| 3.10 | ROP/JOP gadget finder | AxiomCore Workbench | 4d |
| 3.11 | Dump forensics + module extraction | AxiomCore DumpForensics | 4d |
| 3.12 | Device bench: serial console, GDB-RSP | AxiomCore DeviceConsole | 5d |
| 3.13 | Scripting console (JavaScriptCore + axiom API) | AxiomCore Scripting | 4d |
| 3.14 | Annotation/bookmark/edit-log UI with revision conflicts | AxiomCore Models.swift | 5d |
| 3.15 | RE MCP tools exposed app-wide (import, analyze, decompile, scan...) | ghidraclone axiom CLI/MCP server | 4d |
| 3.16 | Guardrails preserved: no execution, bounded imports, fingerprint-only keys | Axiom RE conventions (non-negotiable) | 2d |

### Exit Criteria
- [ ] Import 10MB binary < 5s; Ghidra analysis < 60s
- [ ] Decompilation renders with rename/comment persisted across sessions
- [ ] Auto-decrypt finds XOR/AES candidates with structural evidence, keys as fingerprints only
- [ ] RE tools callable from AgenticConsole via MCP ("explain this function")
- [ ] All Axiom RE tests ported and green

---

## Phase 4: Swarming Engine (Weeks 23–28)

**Goal**: Multi-agent orchestration. Port System5's proven orchestration/policy/audit core, rebuild as native Swift with the experimental pieces flagged.

> **Note**: User states System5-class swarming is "experimental and not working completely correctly." The roadmap assumes: policy engine, audit chain, sandbox backends, and approval flow are *solid* (per README tests); consensus and complex task decomposition need hardening.

### Work Items

| # | Item | Source | Est. |
|---|------|--------|------|
| 4.1 | Swarm orchestrator (task → subtasks → agent pool → results) | System5 orchestrator.py | 6d |
| 4.2 | Task decomposer (LLM-driven, with deterministic fallback) | System5 + new | 5d |
| 4.3 | Agent types: planner, implementer, reviewer, researcher | New (profiles reuse AgenticConsole AgentProfile) | 6d |
| 4.4 | Coordination bus (topics, shared memory, history) | System5 bus.py | 5d |
| 4.5 | Policy engine (allow/approve/deny declarative rules) | System5 policy.py (tested) | 4d |
| 4.6 | Sandbox backends: Docker, seatbelt, subprocess | System5 sandbox/ (tested) | 5d |
| 4.7 | Mediated egress proxy (SSRF backstop, allowlist) | System5 proxy/egress_gateway.py | 4d |
| 4.8 | Approval queue + UI (consequences spelled out, persist allowlists) | System5 approvals | 5d |
| 4.9 | Behavior monitor: tripwires + LLM rubric pass | System5 monitor.py | 5d |
| 4.10 | Hash-chained audit log (tamper detection incl. tail truncation) | System5 audit.py (tested) | 4d |
| 4.11 | Consensus engine (unanimous/supermajority/majority/plurality) | New (experimental — flag as such) | 6d |
| 4.12 | Swarm dashboard UI (agent activity, task graph, messages, audit) | New | 8d |
| 4.13 | Integration: swarm can drive DevPlatform builds and RE analyses | New | 5d |

### Exit Criteria
- [ ] 3-agent swarm (plan/implement/review) completes a small feature in a real repo
- [ ] Tripwire fires on out-of-workspace write → run pauses → approval resumes
- [ ] Audit chain verification detects tampered row and truncated tail
- [ ] Consensus marked experimental in UI; falls back to human approval
- [ ] No covert inter-agent channel except the readable bus

---

## Phase 5: Development Platform (Weeks 29–38)

**Goal**: The Xcode-class IDE. Largest greenfield effort; built last so it inherits the editor, terminal, and agent infrastructure from earlier phases.

### Work Items

| # | Item | Source | Est. |
|---|------|--------|------|
| 5.1 | Text engine: buffer, syntax highlighting, folding, multi-cursor | New (CodeY learnings) | 10d |
| 5.2 | LSP integration (sourcekit-lsp first, then clangd/pylsp/ts) | New | 8d |
| 5.3 | Completion engine (LSP + AI-powered via ModelRegistry) | New | 5d |
| 5.4 | Project navigator + FSEvents file tree | New | 5d |
| 5.5 | SwiftPM build integration (resolve, build, parse output) | New | 6d |
| 5.6 | xcodebuild integration (project parse, schemes, destinations) | New + OpenXcode analysis | 8d |
| 5.7 | Build log parsing → clickable diagnostics | New | 4d |
| 5.8 | LLDB debug bridge (MI2 protocol, breakpoints, variables, memory) | New | 10d |
| 5.9 | Debug views: call stack, watchpoints, registers, disassembly | New | 6d |
| 5.10 | Test runner (Swift Testing + XCTest, coverage via profdata) | New | 6d |
| 5.11 | Simulator manager (list/boot/install/launch/screenshot) | New (xcrun simctl wrapper) | 4d |
| 5.12 | Device manager + provisioning | New | 5d |
| 5.13 | Git full UI (blame, history, branch manager, merge tool) | Extends Phase 1 GitService | 6d |
| 5.14 | Asset catalog editor | New | 6d |
| 5.15 | Refactoring engine (rename, extract, via LSP + agents) | New | 6d |
| 5.16 | Templates (project/file/snippets) | New | 4d |
| 5.17 | AI pair-programming flows (agent edits editor buffer with diff preview) | New, ties AgenticConsole ↔ editor | 6d |
| 5.18 | Quick help + DocC browser | New | 3d |

### Exit Criteria
- [ ] Open a real SwiftPM package; edit, build, see diagnostics, run tests
- [ ] Debug a crashing program: breakpoint → inspect variables → step
- [ ] Agent proposes multi-file change → diff view → approve → builds green
- [ ] 10k-file project opens < 1s

---

## Phase 6: Polish, Plugin SDK, Release (Weeks 39–46)

| # | Item | Est. |
|---|------|------|
| 6.1 | Performance pass (launch, memory, streaming) | 5d |
| 6.2 | Accessibility (VoiceOver, keyboard, contrast, reduced motion) | 5d |
| 6.3 | Localization (EN + 5 languages) | 4d |
| 6.4 | Plugin SDK docs + template + 3 example plugins | 8d |
| 6.5 | Module marketplace index format + installer | 5d |
| 6.6 | Sparkle auto-update + Ed25519 signing | 3d |
| 6.7 | Code signing + notarization pipeline | 3d |
| 6.8 | Onboarding + first-run experience | 4d |
| 6.9 | Beta (TestFlight/GeoCastle) + feedback iteration | 14d |
| 6.10 | v1.0 release | 2d |

---

## Dependency Graph

```
Phase 0 (Foundation)
   │
   ├─▶ Phase 1 (Agentic Console)  ──────┐
   │         │                          │
   │         ├─▶ Phase 2 (Model Lab)    │
   │         │                          │
   │         ├─▶ Phase 3 (RE Console)   │
   │         │                          ▼
   │         ├─▶ Phase 4 (Swarming) ◀── uses agents/tools from P1
   │         │                          │
   │         └─▶ Phase 5 (Dev Platform) │
   │                  │                 │
   └──────────────────┴─────────────────┴─▶ Phase 6 (Release)
```

**Parallelization**: Phases 2, 3, 4 can proceed in parallel after Phase 1, each as an independent module. Phase 5 is the long pole — start its text engine early (it has no module dependencies) if staffing allows.

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| MLX scheduler segfaults (beta OS) | Medium | High | AILab workarounds (`MLX.compile(enable:false)`, GUI-not-CLI pattern); keep MLX provider optional with honest unavailability states |
| LLDB MI2 bridge complexity | High | High | Timebox to read-only inspection first; fall back to lldb CLI scripting |
| xcodebuild project parsing (no public API) | High | Medium | Shell out to `xcodebuild -list`; use XcodeGen for own projects; consider XCFormat/CoreAnim ideas from CodeY |
| Swarming consensus instability | High (experimental) | Medium | Ship as experimental flag; default to orchestrator + human approval |
| Ghidra/radare2 external dependency drift | Medium | Medium | Pin versions; Axiom RE already treats engines as optional with graceful degradation |
| Scope creep in IDE phase | High | High | Strict milestone gates; IDE v1 = SwiftPM-only, xcodeproj read-only |
| Apple Foundation Models API changes | Medium | Medium | Availability-gated provider; per-AILab pattern show exact unavailability reason |

---

## Resourcing Notes

- **Minimum viable team**: 2 engineers (one UI-heavy, one systems-heavy) per phase
- **Phase 5 alone** is ~110 engineer-days — consider splitting into 5a (editor+build) and 5b (debug+test)
- Existing assets represent **~60% of the total feature surface already built** in other projects; this roadmap's estimates assume porting, not rewriting

---

## Definition of Done (per phase)

1. All work items checked with verification evidence (test run, screenshot, or manual QA log)
2. No "fake capabilities" — unavailable features disabled with specific reasons
3. Swift Testing suite green; new behavior has tests
4. Module loads/unloads cleanly; no cross-module regressions
5. Documentation updated (module README + spec deltas)
6. Performance targets from 00-MASTER-SPEC.md measured and recorded

---

## Document Version

- **Version**: 1.0
- **Date**: 2026-10-15
- **Status**: Draft for Review