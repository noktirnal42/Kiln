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
