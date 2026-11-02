# Kiln

![Kiln](Branding/export/kiln-banner-1600x640.png)

A unified native macOS application (Swift 6, Xcode 27, SwiftUI) combining a
development platform (IDE), a reverse engineering console, an AI/ML model lab,
an AI agentic harness console, and a multi-agent swarming engine — all as
loadable modules in one app.

**Specifications live in [`docs/`](docs/).** `00-MASTER-SPEC.md` is the
authority; `10-LAYERED-ARCHITECTURE.md` supersedes the per-app module framing
(components are harvested, not apps ported); `09-AGENT-PROMPTS.md` drives
incremental agent sessions.

## Status

> **Current state (2026-11-01): see [`docs/11-CURRENT-STATE.md`](docs/11-CURRENT-STATE.md)** — what exists, how it was
> verified, how to build/sign/notarize, and what is still open. The app builds with no warnings of its own, 466 tests
> pass, and a notarized build runs. The sections below record how each phase was built.

### Phase 1d — Agent Runtime + Tools (complete)

Implemented per `09-AGENT-PROMPTS.md` Prompt 4 / `08-ROADMAP.md` items 1.17–1.19, ported from AppleHarness `AgentRuntime`/`ToolRuntime` and System5 `policy.py`:

| Area | What exists |
|------|-------------|
| Orchestrator | `AgentOrchestrator`: the tool-call loop — stream model → parse tool calls → policy check → approval gate → execute → feed results back (`role: .tool` + `tool_call_id`, matching the OpenAI-compatible transport) → repeat until no calls. **Two independent gates, both always on**: Gate A (`ExecutionPolicy.offeredTools`) filters the tool list before the model ever sees it; Gate B re-checks every arriving call (even one the model hallucinated that was never offered) and denies with the policy rule fed back to the model. Round cap (40), per-run wall-clock timeout from the profile, tool execution capped at the remaining run budget |
| Execution policy | System5's declarative policy ported to Swift: `PolicyDecision(verdict, rule, reason)` with allow/require-approval/deny; workspace write-scope + deny-paths (fnmatch-style globs); shell block patterns (mkfs, disk erase, dd, shutdown, fork bombs — denied outright, no approval possible) and approval-gated patterns (sudo, force-push, `rm -rf`, `curl \| sh`, npm publish); egress allow/deny lists with the **SSRF backstop that parses addresses instead of matching spelling** (`127.1`, `2130706433`, `0`, `::ffff:127.0.0.1`, `.local`, cloud metadata hosts); budget caps (USD/tokens/wall-clock, 0 disables) |
| Retry/backoff | System5's `_turn_with_retry` ported: 429/5xx/transport errors (typed `ProviderError`/`URLError` classification plus message regex) retried 5× at 1s→2s→4s→8s; non-retryable errors (bad key, no credit, missing model) fail immediately; backoff sleeps in **1-second slices so an operator Stop lands within a second, never after the schedule** |
| Approval center | Gate B's human gate (`@MainActor`, UI-bindable): queue with the tool call's consequences spelled out (`CommandSafety` reasons: "Recursively deletes files without confirmation", etc.), per-conversation "ask once", and **persistable, revocable "always allow this host/command/tool" grants** (`GrantStore`, JSON in Application Support — host-scoped for `web_fetch`, command-scoped for shell tools) merged at policy-check time like System5's allowances. JSONL audit log of every decision. **`ApprovalQueueView`**: app-level sheet that auto-opens when a request lands (the one thing that should interrupt), showing the permission tier, destructive warnings, expandable call preview, and Deny / Approve Once / Always Allow; a "Standing grants" manager lists every grant with per-row and bulk revoke. Toolbar shield button shows the pending count |
| Services wiring | `AgentOrchestrator` accepts the app's real `ToolServices` (shared `GitService`, shared `FileIndexService`, web-search key from the Keychain at `com.kiln.tools`/`web-search-key`); tools fall back to their own implementations when a service is absent — services remove duplication, they never widen what tools may do. Verified by an e2e test proving an injected index is actually used |
| Agent profiles | `AgentProfile`: name, system prompt, model preferences, tool permissions, **`maxConcurrentTasks`** (enforced by `AgentRunLimiter` — same-profile runs queue, different profiles never block each other), run timeout. 3 built-ins (General Chat / Research Assistant / Coding Agent); JSON-backed `AgentProfileStore` |
| Secrets | `SecretRedactor` strips known key shapes (AWS/GitHub/OpenAI/Anthropic/Slack/JWT/bearer/assignments) from prompts **and tool results** before any provider sees them; sensitive filenames (`.env`, `id_rsa`, `*.pem`…) are never read by file tools |
| Built-in tools | 19 tools at read/write/execute/admin levels, all workspace-contained via `WorkspacePathResolver` (traversal refused with the specific reason, absolute paths inside the root accepted): file (read/write/edit/delete/list/glob/grep), shell (run 120s / stream 600s / background with job store + output reader, zsh in workspace cwd), git (status/diff/commit/branch/log over `GitService`), web (fetch with size caps; **search errors with the specific reason when no backend key is configured — no fake capabilities**), workspace search (FileIndexService-backed, honest: the FTS index is over names/paths, so the tool points content searches at `grep_files`; filename-scan fallback). 24 KiB middle-drop output cap preserves head and tail |

Honest notes: redaction is heuristic, not cryptographic (the UI must say so); shell tools run unsandboxed on the host (sandbox backends are Phase 4 — the policy patterns and approval gate are the containment today); `web_search` works once a Tavily key is stored at Keychain module `com.kiln.tools`, key `web-search-key` (wired through `ToolServices.webSearchKey`); Gate B's write-path check trusts the `path` argument when JSON parses — unparseable arguments fail the tool with a specific error rather than bypassing the check; the chat module does not yet drive the orchestrator (agent-mode chat UI is later-phase work — Prompt 7's swarming builds on this runtime).

### Phase 2 — Model Lab Module (Prompt 5)

Implemented per `09-AGENT-PROMPTS.md` Prompt 5 (`docs/04-MODEL-LAB.md`), porting the verified ModelLabCore engine verbatim into `Packages/ModelLabCore` (CreateML text/tabular/image classifier training, MLX LoRA fine-tuning via `LoRATrain`, from-scratch char-level transformer, automated distillation, Hugging Face model/dataset discovery) plus new Kiln-side components in `Core/ModelLab/` and `Modules/ModelLab/`:

| Area | What exists |
|------|-------------|
| Engine port | ModelLabCore's verified sources copied as-is into `Packages/ModelLabCore` (`Sources`, `Tests`, `Package.swift`, `ModelLabSmoke`) and linked via `project.yml` (`mlx-swift-lm`, `mlx-swift`, `swift-huggingface`, `swift-transformers` resolve through SPM; `MLX` is also declared at root so the process-wide `MLX.compile(enable: false)` workaround from CAPABILITIES.md runs once before any MLX work). |
| Module | `com.kiln.modellab` manifest + `ModelLabModule`: lifecycle, sandboxed `ModelLabSchema` SwiftData store under `Application Support/ModelLab`, demo-data seeding, capability enforcement (`fileSystem.readWrite`, `network.client`, `metal.compute`, `neuralEngine`), training entry points wired to the engine coordinators, memory-aware compatibility verdicts from `HardwareProfile.current()`. |
| Training | Create ML text/tabular/image classification, MLX LoRA fine-tune (repo + plain-text examples → adapter), from-scratch small LM pretraining, automated distillation (Apple Intelligence teacher → jsonl → student LoRA). Run lifecycle via `TrainingCoordinator`/`MLXFineTuningCoordinator`/etc.: start → record start/progress/completion/failure in the experiment store → register artifact. Each run gated on its declared capabilities (write + neural engine / metal). |
| Experiment tracking (item 7) | SwiftData `ExperimentRecord`/`ExperimentStore` runs with hyperparameters, metric history, produced artifacts; `ExperimentComparison` for side-by-side run comparison with direction-aware best-per-metric (loss/perplexity lower-is-better). Experiments tab + Compare sheet UI. |
| Evaluation (item 8) | `LabMetric` protocol + `AccuracyMetric`, `F1Metric` (macro), `BLEUMetric`, `ROUGEMetric` (1/2/L), `PerplexityMetric` (exp(mean NLL)); `EvaluationRunner` collects `MetricOutcome[]`; offline prompt-eval demo in the Evaluation tab. 24 unit tests with known-answer vectors (BLEU 0.5 two-gram case, macro-F1 0.7333, ROUGE-1/2/L 2/3/0.5, perplexity 2.0). |
| Auto-prompt engine (item 9) | `AutoPromptEngine`: template + mutation + optional LLM prompt generation (deterministic seeded `SeededRandom`, hill-climb optimization against a caller-supplied evaluator, keeps best-so-far). |
| Red team harness (item 10) | `RedTeamHarness`: 6 shipped attack cases (jailbreak, prompt injection, system-prompt extraction, PII leakage, harmful content), scriptable target/judge, `Verdict`-per-finding with reason + raw transcript, `Report` with robustness score (inconclusive = half credit, never a pass), JSON export. |
| Export (item 11) | `ModelExporters`: CoreML copy (real `.mlmodel`/`.mlpackage` artifacts), MLX package (artifact directory + `modellab-package.json` manifest), GGUF — **honest unavailability**: requires llama.cpp's `convert_hf_to_gguf`, absent from standard locations and unreachable from inside the App Sandbox; failure names the exact missing tool, never fabricates a GGUF. |
| Playground | Streaming chat backends: Apple Intelligence (`SystemLanguageModel`), MLX local repo (with optional LoRA adapter), trained small LM; Core ML classifier panel. Each backend reports its own capability status live. |

Honest notes: `swift test` cannot exercise MLX paths on this machine — MLX's default Metal library isn't found via the `.xctest` bundle layout (`Failed to load the default metallib`), a SwiftPM-test-target packaging issue, not a code defect. Verify MLX paths with `swift run --package-path Packages/ModelLabCore ModelLabSmoke smalllm` (verified: 150-iteration run, loss ↓, artifact saved, greedy/sampled generation) or the Playground/Training UI; status can vary run to run on this machine until mlx-swift's scheduler issue is fixed upstream — never cache a stale "working" claim. GGUF export needs llama.cpp tooling outside the sandbox. Hugging Face discovery/downloads need network access (the `network.client` entitlement was added to `Config/Entitlements.plist`; `files.user-selected.read-write` for local dataset/model import).

### Phase 1c — Terminal + MCP + Git + File Index (complete)

Implemented per `09-AGENT-PROMPTS.md` Prompt 3 / `08-ROADMAP.md` items 1.13–1.16:

| Area | What exists |
|------|-------------|
| Terminal | Real PTY (`posix_openpt`/`grantpt`/`unlockpt` + Foundation `Process` — no manual fork), bounded 1 MiB output buffer, `ioctl(TIOCSWINSZ)` resize, per-callback explicit locks. `PTYManager` actor: shell detection (zsh/bash/fish with PATH scan), cwd constrained to an existing workspace root (specific error when invalid), **input-line command history persisted per workspace** (500-entry cap, JSON in Application Support). `TerminalDockView`: SwiftTerm tabbed terminal wired to the PTY (feed/send/resize), theme-synced to native colors, history sheet |
| MCP client | JSON-RPC 2.0 over **stdio** (subprocess + pipes, id-correlated, bounded stderr capture), **HTTP** (POST + SSE response decode), **WebSocket** (URLSessionWebSocketTask). Discovery from `~/.config/mcp/servers.json`, `~/.cursor`, and project `.mcp.json` (both `{mcpServers:{}}` and bare shapes). **Every connect requires explicit user approval**, persisted bound to a command fingerprint (changing a server's command invalidates the grant; revocable). Tool/resource/prompt registries aggregated across servers; tool palette UI with call panel. Fixed a real protocol bug: JSONEncoder escapes `/` as `\/`, which breaks line-based servers — client payloads are normalized |
| Git | `GitService` actor over the **git CLI** (spec named libgit2, but no production Swift binding exists and the reference implementation also shells out — documented deviation). Status (porcelain `-z` incl. renames), staged/unstaged diff (512 KiB cap), stage/unstage/commit, branches/checkout, log (500 cap), blame (porcelain). **Push deliberately not implemented.** Auto-resolves a sandbox-safe git binary (`/usr/bin/git` is an xcrun shim that refuses to run under App Sandbox). `GitPanelView`: status/diff/history tabs, stage buttons, commit box, open-repo picker |
| File index | `FileIndexService` actor: SQLite **FTS5** index over a bounded walk (20k files, standard ignore dirs), **Spotlight** (NSMetadataQuery, 3 s budget) merged into one ranked unified search (same-path collation, source-count → score → path), **FSEvents** watcher with debounced reindex. `SearchPanelView` with source badges |
| Wiring | All four services registered once in the shared `ServiceRegistry`; chat module toolbar gains Terminal / MCP / Git / Search buttons with sheets |
| Tests | Swift Testing: **125 tests / 22 suites green** — PTY echo/resize/termination + history persistence + rejection reasons; MCP stdio handshake against a deterministic shell fixture server (approval gate, unknown tool, disconnected tool, discovery shapes, JSON-RPC round-trip); git lifecycle against real temp repos (init→status→stage→commit→log→branches→blame, nothing-to-commit, empty-message refusal); FTS5 indexing/search/ranking + invalid-root refusals |

Honest notes: PTY cwd constraint pins the starting directory but is not a security boundary (sandbox backends are Phase 4); Spotlight merge degrades silently to FTS5-only where the query engine is unavailable; git blame/log caps bound output; no git push by design.

### Phase 1b — Chat UI + Artifacts (complete)

Implemented per `09-AGENT-PROMPTS.md` Prompt 2 / `08-ROADMAP.md` items 1.9–1.12:

| Area | What exists |
|------|-------------|
| Conversation persistence | `ConversationStore` actor over the shared SwiftData container (background `ModelContext`, actor-isolated): create/rename/delete, ordered messages (`order` field), `MessagePage` with truncation records, **fork-from-message** (copies the prefix into a new conversation), bulk `appendMessages` (one save for N messages) |
| Chat streaming | `ChatSession` (@MainActor @Observable): drives `ModelRegistry.streamChat`, accumulates **deltas** into a live `streamingText` (bubbles never re-diff the whole list while streaming), `ToolCallAccumulator` joins indexed fragments, Stop persists the partial response, regenerate re-runs from the last user message, model-guard errors are specific ("No model selected") |
| Chat UI | `ChatRootView` (NavigationSplitView-compatible): streaming `LazyVStack` with ScrollViewReader auto-scroll, copy/regenerate/fork/delete on every bubble (+ context menu), `ComposerView` with ⌘⏎ send, collapsible conversation list, error strip |
| Message rendering | `MarkdownBlockView` over the bounded GFM-subset `MarkdownRenderer` (headings, paragraphs with inline markdown via AttributedString, fences, lists, blockquotes, tables, dividers); role indicators, reasoning disclosure, tool-call chips, token usage |
| Model picker | Provider-grouped sections with per-provider availability warnings (hover = the specific unavailability reason), search, recents (persisted), expandable `ReasoningPanel` (enabled/budget/depth/temperature/topP/maxTokens/stop sequences) |
| Artifacts | `ArtifactStore` actor (4 MiB content cap, version history capped at 50, content by version) + browser UI with per-kind renderers: code (bounded `CodeHighlighter` spans), markdown (same renderer as chat), HTML (`WKWebView` `loadHTMLString`, no network base), mermaid (**honest**: shows source with an explanation instead of a broken engine), data (CSV/JSON → table). Export via NSSavePanel |
| Module | `com.kiln.chat` loads from its manifest; resolves `ModelRegistry`/`ConversationStore`/`ArtifactStore` from the **shared** `ServiceRegistry` (ModuleManager now injects the app-level registry — services exist once per the layered architecture) |
| Tests | Swift Testing: **104 tests / 18 suites green** — store round-trips, fork semantics, truncation, artifact versioning + caps, highlighter/markdown/CSV-JSON parser units, streaming end-to-end (deltas → persisted messages, tool-call fragment joining, deterministic mid-stream stop, fork via session, 10k-message synthetic conversation load) |

Honest notes: @-mention file references in the composer are placeholder UI (FileIndexService arrives with Prompt 3); mermaid and react artifact kinds render source rather than pretending to run an engine; per-frame render timing is not yet instrumented (Phase 6 perf pass measures it; the 10k-message load test bounds the data layer).

### Phase 1a — Model Provider Layer (complete)

Implemented per `09-AGENT-PROMPTS.md` Prompt 1 / `08-ROADMAP.md` items 1.1–1.8:

| Area | What exists |
|------|-------------|
| Provider protocol | `ModelProvider`: id / name / providerType / capabilities, `fetchModels()`, `streamChat(_:reasoning:)`, `countTokens(_:)`, `checkAvailability()` (`Core/Providers/`) |
| Providers | OpenCode (Ollama `/api/tags` + `/api/chat` with OpenAI-compatible fallback for LM Studio/vLLM), Ollama Cloud (same class, cloud scope, Keychain bearer), OpenRouter, NVIDIA NIM (non-chat endpoint filtering, GLM-5.3 `reasoning_effort` special-casing), Custom Endpoint (OpenAI-compatible + custom headers), Apple Foundation Models (FoundationModels availability-gated: deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady each reported specifically), MLX (honest: runtime not yet linked — reports the exact reason and the Phase 2 plan; model catalog still works from the shared HF cache) |
| Streaming | Shared `OpenAICompatibleTransport`: SSE, **deltas only — never cumulative snapshots**, bounded 64 KiB error-body reads, status→error mapping (401/402/429/5xx), bounded retries (408/409/425/429/5xx with Retry-After); Apple provider prefix-diffs cumulative snapshots into deltas |
| Reasoning | `ReasoningConfig` (enabled/budget/depth/temperature/topP/maxTokens/stop/systemPrompt) with per-provider mappings: `toOllamaOptions()`, `toNIMEffort()`, `toAppleEffort()`, OpenAI `reasoning` fields (`Core/Reasoning/`) |
| Registry | `ModelRegistry` actor: register/unregister, 300 s model cache TTL, capability-based selection skipping unavailable/weaker providers, prefix-based model→provider resolution, emits `ModelSwitchedEvent` on the module event bus (`Core/Providers/ModelProvider.swift`) |
| Secrets | API keys read lazily through `KeychainService.secretProvider` (module `com.kiln.providers`), never stored in provider state, never logged, never persisted |
| Universal store | `UniversalModelStore`: `HF_HUB_CACHE` → `HF_HOME/hub` → `~/.cache/huggingface/hub` walk (ports AxiomCore ModelStore query; shared with `hf`/`mlx_lm`) — closes roadmap item 0.10 |
| Tests | Swift Testing: 81 tests / 14 suites, all green. All providers contract-tested through the registry against `URLProtocol` stubs (no real network); delta-only streaming asserted; per-provider unavailability reasons asserted |

### Phase 0 — Foundation & Core Shell (complete)

Implemented per `09-AGENT-PROMPTS.md` Prompt 0 / `08-ROADMAP.md` Phase 0:

| Area | What exists |
|------|-------------|
| Project | XcodeGen `project.yml`, Swift 6 strict concurrency, macOS 15+, App Sandbox (`Config/Entitlements.plist`), Hardened Runtime setting |
| SwiftData schema | `Workspace`, `ModuleState`, `Conversation`, `Message`, `Artifact`, `SettingsEntry` (`Core/Models/SwiftDataModels.swift`) |
| Module protocol | `Module` / `ModuleDefinition` / `ModuleUI` with initialize / activate / deactivate / shutdown lifecycle (`Core/Contracts/`) |
| ModuleManager | Manifest discovery (`*.modulemanifest.json` or `ModuleManifest.json`, bounded scan), topological dependency resolution, load/unload/activate/deactivate, semantic-version compatibility check, lifecycle events on the bus |
| Capability system | `ModuleCapabilities` OptionSet (31 capabilities, string names per `01-MODULAR-ARCHITECTURE.md`), manifest declaration, grant = required ∩ allowed, **runtime enforcement via `ModuleContext.requireCapability`** — denial fails cleanly naming the missing capability |
| ModuleContext | Per-module granted capabilities, workspace snapshot, event bus, service registry, settings, keychain, `os.Logger` namespacing |
| Event bus | `ModuleEventBus` actor: typed publish/subscribe, unsubscribe, catch-all observation, 256-entry bounded history with JSON payloads |
| Service registry | `ServiceRegistry` actor: typed + named register/resolve/unregister |
| Settings | `SettingsService` actor with the layered order **env vars → user config → workspace → defaults**; JSON persistence, key observation |
| Keychain | `KeychainService`, module-namespaced generic passwords, SHA-256 fingerprinting (CryptoKit) — secrets never logged or persisted |
| Design system | `ThemeManager` (system/light/dark/high-contrast, persisted), typography, spacing, corner radius, semantic colors (`UI/DesignSystem/`) |
| Shell | `MainWindow` = NavigationSplitView; sidebar lists modules with live phase badges + a live event-bus feed; `ModuleHostView` renders the active module's root view |
| Demo module | `com.kiln.hello` loads from its bundled manifest, publishes/receives cross-module events, reads system info behind a `systemInfo` capability grant, and shows the exact denial reason when the grant is missing |
| Tests | Swift Testing, 49 tests / 8 suites, all green (bus, registry, settings, keychain, capabilities, manifests, manager lifecycle + denials, Hello module). No network in unit tests. |

Build & test:

```bash
xcodegen generate
xcodebuild build  -project Kiln.xcodeproj -scheme Kiln -destination 'platform=macOS'
xcodebuild test   -project Kiln.xcodeproj -scheme Kiln -destination 'platform=macOS'
```

Honest scope notes (no fake capabilities):

- Phase 0 modules are **statically linked** with manifest-driven load/unload.
  The manager discovers manifests, validates, grants capabilities, and runs the
  full lifecycle; `dlopen`-style bundle loading and the marketplace install
  flow arrive in later phases (`01-MODULAR-ARCHITECTURE.md`).
- The default app policy grants all known capabilities; the
  `ModuleManager.allowedCapabilities` parameter is the enforcement point and is
  exercised by tests (denial path). Settings → Security policy UI is a later item.
- Cold launch measured informally (process alive well under 2 s on this
  machine); formal Instruments-based measurement lands with the Phase 6 pass.

## Layout

```
App/                  @main entry, AppDelegate, AppModel (bootstrap + UI state)
Config/               Entitlements.plist (App Sandbox)
Core/Contracts/       Module, ModuleUI, capabilities, manifest, context, bus, registry
Core/Services/        ModuleManager, SettingsService, KeychainService
Core/Models/          SwiftData schema
Modules/Hello/        Demo module (UI + engine)
ModuleManifests/      Bundled *.modulemanifest.json files
UI/                   MainWindow, sidebar, module host, design system
Tests/CoreTests/      Swift Testing suite
docs/                 Specifications (00–10)
```

## Conventions for every session

See the standing agent rules in `docs/09-AGENT-PROMPTS.md`: trust the specs,
no fake capabilities, bounded everything, Keychain-only secrets, Swift 6 strict
concurrency, Swift Testing with a test per behavior, commit small and often.
