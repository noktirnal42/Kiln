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
