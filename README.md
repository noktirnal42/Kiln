# SuperMetaApp

A unified native macOS application (Swift 6, Xcode 27, SwiftUI) combining a
development platform (IDE), a reverse engineering console, an AI/ML model lab,
an AI agentic harness console, and a multi-agent swarming engine — all as
loadable modules in one app.

**Specifications live in [`docs/`](docs/).** `00-MASTER-SPEC.md` is the
authority; `10-LAYERED-ARCHITECTURE.md` supersedes the per-app module framing
(components are harvested, not apps ported); `09-AGENT-PROMPTS.md` drives
incremental agent sessions.

## Status

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
| Module | `com.supermeta.chat` loads from its manifest; resolves `ModelRegistry`/`ConversationStore`/`ArtifactStore` from the **shared** `ServiceRegistry` (ModuleManager now injects the app-level registry — services exist once per the layered architecture) |
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
| Secrets | API keys read lazily through `KeychainService.secretProvider` (module `com.supermeta.providers`), never stored in provider state, never logged, never persisted |
| Universal store | `UniversalModelStore`: `HF_HUB_CACHE` → `HF_HOME/hub` → `~/.cache/huggingface/hub` walk (ports AxiomCore ModelStore query; shared with `hf`/`mlx_lm`) — closes roadmap item 0.10 |
| Tests | Swift Testing: 81 tests / 14 suites, all green. All providers contract-tested through the registry against `URLProtocol` stubs (no real network); delta-only streaming asserted; per-provider unavailability reasons asserted |

### Phase 0 — Foundation & Core Shell (complete)

Implemented per `09-AGENT-PROMPTS.md` Prompt 0 / `08-ROADMAP.md` Phase 0:

| Area | What exists |
|------|-------------|
| Project | XcodeGen `project.yml`, Swift 6 strict concurrency, macOS 15+, App Sandbox (`Config/Entitlements.plist`), Hardened Runtime setting |
| SwiftData schema | `Workspace`, `ModuleState`, `Conversation`, `Message`, `Artifact`, `SettingsEntry` (`Core/Models/SwiftDataModels.swift`) |
| Module protocol | `Module` / `ModuleDefinition` / `ModuleUI` with initialize / activate / deactivate / shutdown lifecycle (`Core/Contracts/`) |
| ModuleManager | Manifest discovery (`ModuleManifest.json` + `*.modulemanifest.json`, bounded scan), topological dependency resolution, load/unload/activate/deactivate, semantic-version compatibility check, lifecycle events on the bus |
| Capability system | `ModuleCapabilities` OptionSet (31 capabilities, string names per `01-MODULAR-ARCHITECTURE.md`), manifest declaration, grant = required ∩ allowed, **runtime enforcement via `ModuleContext.requireCapability`** — denial fails cleanly naming the missing capability |
| ModuleContext | Per-module granted capabilities, workspace snapshot, event bus, service registry, settings, keychain, `os.Logger` namespacing |
| Event bus | `ModuleEventBus` actor: typed publish/subscribe, unsubscribe, catch-all observation, 256-entry bounded history with JSON payloads |
| Service registry | `ServiceRegistry` actor: typed + named register/resolve/unregister |
| Settings | `SettingsService` actor with the layered order **env vars → user config → workspace → defaults**; JSON persistence, key observation |
| Keychain | `KeychainService`, module-namespaced generic passwords, SHA-256 fingerprinting (CryptoKit) — secrets never logged or persisted |
| Design system | `ThemeManager` (system/light/dark/high-contrast, persisted), typography, spacing, corner radius, semantic colors (`UI/DesignSystem/`) |
| Shell | `MainWindow` = NavigationSplitView; sidebar lists modules with live phase badges + a live event-bus feed; `ModuleHostView` renders the active module's root view |
| Demo module | `com.supermeta.hello` loads from its bundled manifest, publishes/receives cross-module events, reads system info behind a `systemInfo` capability grant, and shows the exact denial reason when the grant is missing |
| Tests | Swift Testing, 49 tests / 8 suites, all green (bus, registry, settings, keychain, capabilities, manifests, manager lifecycle + denials, Hello module). No network in unit tests. |

Build & test:

```bash
xcodegen generate
xcodebuild build  -project SuperMetaApp.xcodeproj -scheme SuperMetaApp -destination 'platform=macOS'
xcodebuild test   -project SuperMetaApp.xcodeproj -scheme SuperMetaApp -destination 'platform=macOS'
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
ModuleManifests/      Bundled ModuleManifest.json files
UI/                   MainWindow, sidebar, module host, design system
Tests/CoreTests/      Swift Testing suite
docs/                 Specifications (00–10)
```

## Conventions for every session

See the standing agent rules in `docs/09-AGENT-PROMPTS.md`: trust the specs,
no fake capabilities, bounded everything, Keychain-only secrets, Swift 6 strict
concurrency, Swift Testing with a test per behavior, commit small and often.
