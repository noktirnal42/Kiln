# SuperMetaApp — Agent Prompts & Specifications

This document contains ready-to-use prompts for AI agents (Claude Code, Codex, opencode, local models) to build SuperMetaApp incrementally. Each prompt is self-contained and references the specs in this folder.

**Usage pattern**: Feed one prompt per work session. Each prompt assumes prior phases' exit criteria are met. Adjust paths for your environment.

---

## Prompt 0: Project Bootstrap

```
You are building SuperMetaApp, a unified native macOS application (Swift 6,
Xcode 27, SwiftUI) that combines: a development platform (IDE), a reverse
engineering console, an AI/ML model lab, an AI agentic harness console, and a
multi-agent swarming engine — all as loadable modules in one app.

Read these specs before writing any code:
- /Volumes/Artificial_Intelligence_Machine_Learning/dev/SuperMetaApp/SuperMetaApp/00-MASTER-SPEC.md
- /Volumes/Artificial_Intelligence_Machine_Learning/dev/SuperMetaApp/SuperMetaApp/01-MODULAR-ARCHITECTURE.md
- /Volumes/Artificial_Intelligence_Machine_Learning/dev/SuperMetaApp/SuperMetaApp/08-ROADMAP.md
- /Volumes/Artificial_Intelligence_Machine_Learning/dev/SuperMetaApp/SuperMetaApp/10-LAYERED-ARCHITECTURE.md

Your task: implement Phase 0 (Foundation & Core Shell).

All work happens in the project root:
/Volumes/Artificial_Intelligence_Machine_Learning/dev/SuperMetaApp/SuperMetaApp/

Create the Xcode project (use XcodeGen with project.yml) with:
1. Swift 6 strict concurrency, macOS 15+ target, App Sandbox + Hardened Runtime
2. SwiftData schema: Workspace, ModuleState, Conversation, Artifact, Settings
3. The Module protocol with lifecycle: initialize/activate/deactivate/shutdown
4. ModuleManager: discovery via ModuleManifest.json, dependency resolution,
   load/unload, capability validation
5. ModuleContext with ServiceRegistry and ModuleEventBus (actor-based)
6. Capability system: ModuleCapabilities OptionSet, manifest declaration,
   runtime enforcement (ungranted capability → clean failure with reason)
7. Layered SettingsService: env vars → user config → workspace → defaults
8. Design system primitives: ThemeManager, typography, spacing
9. MainWindow with NavigationSplitView + ModuleHostView that displays the
   active module's root view
10. One demo module ("Hello") proving dynamic load/unload from manifest

Non-negotiable conventions (from the spec):
- No fake capabilities: features must report specific unavailability reasons
- Bounded everything: file imports and outputs have explicit size caps
- Secrets only in Keychain, namespaced by module identifier
- Swift Testing framework for tests; every behavior tested
- No external Swift dependencies in Phase 0

Verification: app launches < 2s, demo module loads/unloads via manifest,
event bus delivers a test event cross-module, capability denial produces a
clear error. Run `xcodebuild test` and report results honestly.
```

---

## Prompt 1: Model Provider Layer (Phase 1, items 1.1–1.8)

```
You are implementing the model provider layer for SuperMetaApp's Agentic
Console module.

Read first:
- 05-AGENTIC-CONSOLE.md (sections: Model Provider Abstraction, Reasoning Control)
- Reference implementation (DO NOT rewrite, port and adapt):
  /Volumes/Artificial_Intelligence_Machine_Learning/dev/OpenClaudeCodexDesktop/Sources/Core/Providers/
  /Volumes/Artificial_Intelligence_Machine_Learning/dev/OpenClaudeCodexDesktop/Sources/Core/Reasoning/
  /Volumes/Artificial_Intelligence_Machine_Learning/dev/AppleHarness/Sources/ModelProviders/

Implement:
1. ModelProvider protocol: id, name, providerType, capabilities,
   fetchModels(), streamChat(_:reasoning:), countTokens(), checkAvailability()
2. Providers: OpenCode (Ollama/LM Studio HTTP), OpenRouter, NVIDIA NIM,
   Apple Foundation Models (SystemLanguageModel availability-gated),
   MLX (port from AILab — see CAPABILITIES.md for the known MLX scheduler
   crash workarounds: MLX.compile(enable:false), GUI-context pattern),
   Ollama Cloud, Custom Endpoint (OpenAI-compatible)
3. ReasoningConfig with per-provider mapping: Ollama options, NIM
   reasoning_effort, Apple reasoningEffort
4. ModelRegistry actor: register/resolve/streamChat with capability-based
   selection; emits ModelSwitchedEvent on the module event bus
5. Streaming: providers emit DELTAS, never cumulative snapshots
6. Wire API keys through KeychainService — never log, never persist to disk

Test with a MockProvider via URLProtocol stubs (no real network in tests).
Every provider that cannot initialize must report its specific reason
(missing key, offline, Apple Intelligence not enabled, MLX load failure) —
never a generic "unavailable".

Verification: contract tests run against all providers through the registry.
```

---

## Prompt 2: Chat UI + Artifacts (Phase 1, items 1.9–1.12)

```
You are building the chat interface and artifacts system for SuperMetaApp.

Read first:
- 05-AGENTIC-CONSOLE.md (sections: Chat Interface, Artifacts System)
- Port UI patterns from:
  /Volumes/Artificial_Intelligence_Machine_Learning/dev/OpenClaudeCodexDesktop/Sources/UI/
  /Volumes/Artificial_Intelligence_Machine_Learning/dev/AppleHarness/Sources/UI/

Implement:
1. ConversationView: streaming messages, ScrollViewReader auto-scroll,
   context menus (copy/regenerate/fork/delete), message branching
2. MessageBubble: role indicator, collapsible reasoning display, tool call
   rendering, artifact attachments, token usage
3. ComposerView: model picker (compact), attachments, @-mention file
   references via FileIndexService, ⌘⏎ send
4. ModelPickerView: provider-grouped sections, search, recents, expandable
   ReasoningPanel (budget/depth/temperature/topP/maxTokens/stop sequences)
5. Artifacts: ArtifactStore (SwiftData), version history, renderers for
   code (syntax highlighted), markdown (GFM), HTML (sandboxed WKWebView),
   mermaid, data tables; export to file/project
6. Conversation persistence with branching (fork-from-message)

Constraints: all UI @MainActor; stores are actors; providers never touch UI.
Performance: message render < 16ms/frame while streaming; artifact render
< 200ms. Verify with 10k-message synthetic conversation.
```

---

## Prompt 3: Terminal + MCP + Git (Phase 1, items 1.13–1.16)

```
You are implementing terminal, MCP client, and git integration for
SuperMetaApp's Agentic Console.

Read first:
- 05-AGENTIC-CONSOLE.md (sections: Terminal Integration, MCP Client, Git)
- Port from:
  /Volumes/Artificial_Intelligence_Machine_Learning/dev/OpenClaudeCodexDesktop/Sources/Core/Services/
  (TerminalService.swift, MCPClientService.swift, GitService.swift)
  /Volumes/Artificial_Intelligence_Machine_Learning/dev/System5/system5/
  (bus patterns for MCP server registry)

Implement:
1. Terminal: SwiftTerm-based TerminalView, PTYManager actor (session create/
   resize/close), shell detection (zsh/bash/fish), tabs, theme sync,
   command history persisted per workspace
2. MCPClientService: stdio (subprocess + pipes), HTTP, WebSocket transports;
   discovery from ~/.config/mcp/servers.json and project .mcp.json; tool/
   resource/prompt registries; tool palette UI; every server connect
   requires explicit user approval
3. GitService: libgit2 wrapper — status/diff/commit/branch/log/blame;
   sidebar panel; inline diffs in chat messages
4. FileIndexService: Spotlight (MDQuery) + SQLite FTS5 + FSEvents watcher;
   unified search API merging and ranking both sources

Security: PTY sessions are per-workspace-rooted (cwd constrained); MCP
server credentials in Keychain; git operations never auto-push.
```

---

## Prompt 4: Agent Runtime + Tools (Phase 1, items 1.17–1.19)

```
You are implementing the single-agent runtime for SuperMetaApp.

Read first:
- 05-AGENTIC-CONSOLE.md (section: Agent Runtime)
- Port from (this is proven code — adapt, don't redesign):
  /Volumes/Artificial_Intelligence_Machine_Learning/dev/AppleHarness/Sources/AgentRuntime/
  /Volumes/Artificial_Intelligence_Machine_Learning/dev/AppleHarness/Sources/ToolRuntime/
  /Volumes/Artificial_Intelligence_Machine_Learning/dev/System5/system5/policy.py

Implement:
1. AgentOrchestrator: the tool-call loop — stream model → parse tool calls
   → policy check → approval gate → execute → feed results back → repeat
   until no tool calls
2. TWO INDEPENDENT GATES (from AppleHarness architecture — non-negotiable):
   (a) ExecutionPolicy filters the tool list BEFORE the model sees it
   (b) ApprovalCenter stops execution even if a tool slipped through
3. AgentProfile: name, system prompt, model preferences, tool permissions,
   max concurrent tasks, timeout
4. Built-in tools with permission levels (read/write/execute/admin):
   file (read/write/list/glob/grep/delete), shell (run/stream/background),
   git (status/diff/commit/branch/log), web (search/fetch), search
5. ApprovalCenter: queue, UI presentation with consequences spelled out,
   persistable "always allow this host/command" grants (revocable)
6. Secrets: SecretRedactor strips potential keys from prompts before they
   reach any provider
7. Transient provider failures (429, gateway) retry with backoff; Stop is
   checked every second during backoff

Tests: policy filtering, approval gating, out-of-scope write denial, shell
block patterns, retry/backoff with mid-backoff stop. Port System5's pytest
coverage intent to Swift Testing.
```

---

## Prompt 5: Model Lab Module (Phase 2)

```
You are porting the Model Lab into SuperMetaApp as a module.

Read first:
- 04-MODEL-LAB.md
- /Volumes/Artificial_Intelligence_Machine_Learning/dev/AILab/CAPABILITIES.md
  (this documents what is PROVEN to work on this machine and what is not —
  trust it over your assumptions)
- Port the verified engine from:
  /Volumes/Artificial_Intelligence_Machine_Learning/dev/AILab/Packages/ModelLabCore/

Port these VERIFIED-working capabilities (do not rewrite the ML code):
1. CreateML training: MLTextClassifier, MLClassifier (tabular),
   MLImageClassifier — dataset import → train → .mlmodel → inference
2. MLX LoRA fine-tuning via mlx-swift-lm LoRATrain (keep the
   MLX.compile(enable:false) workaround; LoRA runs are verified in GUI
   context, not bare CLI)
3. From-scratch char-level transformer (verified: 500-iter run, loss 3.1→1.0)
4. Automated distillation pipeline: teacher generates → jsonl dataset →
   student LoRA (verified end-to-end)
5. HardwareProfile with memory-aware compatibility warnings (18GB host)
6. HuggingFace model/dataset discovery via public APIs

Then build NEW around the engine:
7. ExperimentTracker (SwiftData): runs, hyperparams, metrics, artifacts,
   comparison view
8. Evaluation: perplexity, accuracy, BLEU/ROUGE; custom metric protocol
9. AutoPromptEngine: generate prompts (templates + mutation + LLM),
   optimize against an evaluator
10. RedTeamHarness: jailbreak/prompt-injection suites, structured reports
11. Export: CoreML via CreateML conversion, MLX package, GGUF (ONNX later)

Hard rules from AILab's CAPABILITIES.md:
- No fake capabilities: every unavailable feature shows the SPECIFIC reason
- swift test cannot exercise MLX paths on this machine (metallib packaging
  issue) — provide `swift run ModelLabSmoke <task>` equivalents and say so
- MLX status is machine/environment-sensitive; surface live status, never
  cache a stale "working" claim
```

---

## Prompt 6: Reverse Engineering Module (Phase 3)

```
You are porting Axiom RE into SuperMetaApp as the Reverse Engineering module.

Read first:
- 03-REVERSE-ENGINEERING.md
- /Volumes/Artificial_Intelligence_Machine_Learning/dev/ghidraclone/AGENTS.md
  (conventions are non-negotiable)
- Port from: /Volumes/Artificial_Intelligence_Machine_Learning/dev/ghidraclone/Sources/AxiomCore/
  This is a complete, tested engine. Port it as the module's core; write
  only the SuperMetaApp module wrapper and the new UI.

Port the engine faithfully:
1. Models.swift → project data, ProjectStore (atomic saves, revision
   conflicts, edit log/undo)
2. Analyzer.swift → import, inspection, strings/assembly, Ghidra headless +
   radare2 providers (engines are OPTIONAL external tools — graceful
   degradation with specific unavailability reasons)
3. ToolBelt: CryptoConstants, Entropy, FormatSignatures, Transforms,
   Validators, AutoDecryptor, Recipes, RuleScanner (YARA subset —
   unsupported syntax is a compile ERROR, never a silent approximation),
   Workbench (ROP/JOP), DumpForensics, DeviceConsole, GDBRSP, Scripting
4. Intelligence/ModelStore → the universal model store (shared HF cache)

Build new:
5. SwiftUI views: disassembly, decompilation (rename/comments persisted),
   function list/call graphs/xrefs, strings, tool belt panels, audit
6. Expose RE operations as MCP tools app-wide: import_binary,
   analyze_function, get_disassembly, get_decompilation, search_strings,
   get_xrefs, scan_crypto, auto_decrypt, find_gadgets, carve_formats

Non-negotiable guardrails (from AGENTS.md):
- NEVER execute the analyzed file
- Bounded everything: imports ≤ 256 MiB, wordlists ≤ 64 MiB, row caps,
  extraction-bomb guards; record truncation
- No fabricated success: results carry validator evidence
- Key material appears ONLY as SHA-256 fingerprints, never persisted
- Provenance labels on derived artifacts, never silently merged
- Working exploit/payload/C2 tooling stays out of scope
- Port the existing test suite; it must stay green
```

---

## Prompt 7: Swarming Engine (Phase 4)

```
You are porting System5 into SuperMetaApp as the Swarming Engine module.

Read first:
- 06-SWARMING-ENGINE.md
- /Volumes/Artificial_Intelligence_Machine_Learning/dev/System5/README.md
  (threat model → feature map section is the design rationale)
- Port from: /Volumes/Artificial_Intelligence_Machine_Learning/dev/System5/system5/
  (Python; port logic and test intent, not code verbatim)

IMPORTANT CONTEXT: The user states this swarming approach is experimental
and not working completely correctly. Port the PROVEN parts faithfully and
flag the experimental parts in the UI.

Port these PROVEN components (System5 has test coverage for them):
1. Policy engine (policy.py): declarative allow/require-approval/deny,
   per-run scope, capability requests route to the human
2. Sandbox backends (sandbox/): docker, seatbelt, subprocess with
   auto-detection; explicit user choice wins over env var
3. Mediated egress proxy (proxy/egress_gateway.py): allowlist, logging,
   SSRF backstop that parses addresses (not spelling matches)
4. Hash-chained audit log (audit.py): append-only, tamper detection for
   rewritten rows AND tail truncation (head recorded outside the DB);
   on-demand verification; signed export
5. Approval flow: pause agent → human answers → resume/stop; standing
   allowances survive restarts and stay revocable
6. Behavior monitor (monitor.py): deterministic tripwires + LLM rubric
   pass; findings pause only the originating run
7. Transient error retry with backoff; Stop checked every second

Build NEW (flag as EXPERIMENTAL in UI):
8. TaskDecomposer: LLM-driven with deterministic fallback
9. CoordinationBus: readable, first-class inter-agent channel — the ONLY
   channel (no covert communication); shared memory with versioning
10. ConsensusEngine: unanimous/supermajority/majority/plurality; default
    OFF — falls back to human approval
11. Agent types (planner/implementer/reviewer/researcher) built on the
    Agentic Console's AgentRuntime + AgentProfile
12. Swarm dashboard: agent activity, task graph, message bus view,
    approvals, monitor, audit tabs

Threat-model invariants (from README, encode in tests):
- Workspace escape refused outright; .git/ writes refused
- sudo / rm -rf / chmod +s require approval; every category configurable
- Reward hacking countered via solvability flag + report_blocker
- Reward: a 3-agent swarm completes a small feature in a real committed
  repo with zero policy violations and a verifiable audit chain
```

---

## Prompt 8: Development Platform — Editor & Build (Phase 5a)

```
You are building the Development Platform module (editor + build) for
SuperMetaApp. This is the largest greenfield component.

Read first:
- 02-DEV-PLATFORM.md (sections: Source Editor, Project Navigator, Build System)
- /Volumes/Artificial_Intelligence_Machine_Learning/dev/OpenXcode/re-analysis/
  (prior analysis of what an Xcode clone requires)
- /Volumes/Artificial_Intelligence_Machine_Learning/dev/CodeY/
  (prior Swift editor attempt — learn from its structure)

Scope for this prompt (editor + build ONLY; debugger is a later prompt):
1. TextBuffer: gap buffer or piece table, line index, transactions
   (undo/redo groups), background syntax highlighting with token
   attribution
2. LanguageServerClient: LSP over stdio — sourcekit-lsp FIRST (swift,
   Objective-C); then clangd, pylsp, typescript-language-server, rust-
   analyzer as configuration-discovered servers
3. CompletionEngine: merge LSP completions + local (keywords/snippets) +
   AI completions via ModelRegistry (streamed, ranked last)
4. ProjectNavigator: file tree over FSEvents, target inspector,
   Package.swift-aware (dependencies, products, targets)
5. SwiftPMBuilder: `swift build`/`swift test` integration, output parsing
   to diagnostics (file:line:col: error), incremental builds, build log
   persisted per workspace
6. XcodeBuilder: shell out to xcodebuild -list/-showBuildSettings;
   scheme/destination pickers; parse xcodebuild output to diagnostics
7. Diagnostics pipeline: inline editor annotations + issues navigator,
   click-to-navigate

Performance targets (enforce): project open < 1s (10k files), file open
< 100ms, completion < 200ms, keystroke latency < 16ms.
Testing: snapshot tests for highlighting, LSP against a real sourcekit-lsp
in integration tests (skip gracefully if unavailable — report reason).
```

---

## Prompt 9: Development Platform — Debugger & Test (Phase 5b)

```
You are implementing debugging and testing for SuperMetaApp's Development
Platform module. Prerequisite: Phase 5a editor/build are merged.

Read first:
- 02-DEV-PLATFORM.md (sections: Debugger, Test Runner, Device Manager)

Implement:
1. LLDBBridge: drive lldb via MI2 protocol over a persistent subprocess
   (mirror Axiom RE's EngineWorker actor pattern: framing, watchdog,
   request/response correlation)
   - launch/attach, -break-insert/-t, -exec-run/continue/step
   - stack frames, variable evaluation (-var-* commands), watchpoints
   - memory read/write, registers, disassembly
2. Debug UI: breakpoints gutter, call stack view, variable inspector
   (lazy children, format switching), memory hex view, registers,
   disassembly pane synced to editor
3. TestRunner: Swift Testing + XCTest via `swift test` and
   `xcodebuild test-without-building`; parse results to test navigator;
   re-run failed only; coverage via profdata/llvm-cov rendered as editor
   gutter bars
4. SimulatorManager: xcrun simctl wrappers — list/boot/install/launch/
   screenshot/erase; device picker in run bar
5. DeviceManager: devicectl wrappers for physical devices; provisioning
   status display (read-only in v1)

Failure honesty: if lldb is missing or MI2 parsing fails on an output
shape, surface the raw transcript with the parse error — never silently
drop a frame. Tests use a tiny prebuilt fixture binary, no real network.
```

---

## Prompt 10: Integration Hardening + Release (Phase 6)

```
You are preparing SuperMetaApp for v1.0 release.

Read first:
- 00-MASTER-SPEC.md (Security Model, Performance Targets, Success Criteria)
- 07-INTEGRATION-PATTERNS.md (Security Boundaries, Observability)

Tasks:
1. Performance pass: measure and fix — cold launch < 2s, module activation
   < 500ms, idle memory < 150MB, first token targets from master spec.
   Profile with Instruments; record before/after in docs/PERF.md
2. Accessibility: full VoiceOver pass, keyboard navigation for every
   pane, high contrast, reduced motion, Dynamic Type
3. Observability: structured logging via os.Logger per module, opt-in
   metrics collector, crash reporting local-only by default
4. Security audit: verify every module's capability grants are minimal,
   Keychain namespacing, no secrets in logs/SwiftData, MCP server
   approval flow, sandbox entitlements minimal
5. Plugin SDK: extract Module protocol + ModuleContext + manifest schema
   into SuperMetaKit; write SDK documentation; create module-template.sh;
   build 3 example plugins (tool provider, sidebar widget, command pack)
6. Module marketplace: index JSON format, signature verification
   (Developer ID), download → verify → extract → capability prompt → load
7. Distribution: Sparkle with Ed25519, notarization script, DMG build,
   appcast generation; CI release workflow

Definition of done: all 6 success criteria from master spec measured and
passing; docs/RELEASE-CHECKLIST.md completed; signed+notarized DMG.
```

---

## Standing Rules for Every Agent Session

Append these to any agent's system context:

```
SUPERMETAAPP AGENT RULES:

1. Read the relevant spec in /Volumes/Artificial_Intelligence_Machine_Learning/
   dev/SuperMetaApp/SuperMetaApp/ before writing code. Trust the spec over
   your memory. For source-component locations, consult
   10-LAYERED-ARCHITECTURE.md (component harvest map).
2. Harvest components per the harvest map rather than porting whole apps.
   Merge overlapping implementations (e.g., four provider stacks → one).
   The engines (AxiomCore, ModelLabCore, System5 policy/audit/sandbox)
   are tested — preserve their behavior and their tests.
3. No fake capabilities. If a feature can't run, disable it and show the
   specific reason (missing key, unsupported hardware, engine not found,
   Apple Intelligence not enabled). Never pretend success.
4. Bounded everything: size caps on imports/outputs, row caps on results,
   truncation recorded, never silently streamed unbounded data.
5. Secrets: Keychain only, module-namespaced, fingerprinted in any output,
   never logged, never persisted to project files.
6. Swift 6 strict concurrency: stores are actors, UI is @MainActor,
   providers emit deltas. Process callbacks use explicit locks, not actors.
7. Swift Testing framework. Every behavior has a test. No real network in
   unit tests (URLProtocol stubs). Integration tests degrade gracefully
   and report WHY when external tools are missing.
8. Each module declares its capabilities in its manifest; requesting an
   ungranted capability fails cleanly with the missing capability named.
9. Commit small and often. Update the module's README with what changed.
10. When unsure whether a change fits the module's scope, say so and
    propose rather than assume.
```

---

## Verification Prompts (Run After Each Phase)

### Contract Verification

```
Verify Phase N exit criteria from 08-ROADMAP.md. For each criterion:
1. State the concrete verification you performed (command run, test name,
   measurement, or manual QA procedure)
2. Show the evidence (test output, timing, screenshot path)
3. Mark PASS/FAIL honestly — a criterion you cannot verify is FAIL, not
   "presumably works"
Output a table: criterion | verification | evidence | result.
```

### Integration Regression Sweep

```
Run the full test suite for every module. Then verify cross-module
integration points still work:
- AgenticConsole can invoke ModelLab training via MCP
- AgenticConsole can invoke RE analysis via MCP
- SwarmingEngine can drive DevPlatform builds
- All modules observe the same workspace and event bus events
Report any regression with the failing test and suspected cause.
```

---

## Document Version

- **Version**: 1.0
- **Date**: 2026-10-15
- **Status**: Draft for Review