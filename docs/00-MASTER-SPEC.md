# SuperMetaApp — Master Specification

## Vision Statement

**SuperMetaApp** is a unified, native macOS application (Swift 6, Xcode 27) that combines:

1. **Complete Development Platform** — Xcode 27-class IDE with all associated tools
2. **Reverse Engineering Console** — Ghidra/Axiom RE-class native binary analysis
3. **AI/ML Model Laboratory** — Model creation, distillation, training, testing, auto-prompting
4. **AI Agentic Harness Console** — Claude Code/Codex Desktop-class agent interface, model-agnostic
5. **Swarming Engine** — Multi-agent collaboration (System5-class orchestration)

**All integrated as a single cohesive application**, not separate clunky building blocks.

> **Reorganization principle (v2)**: Existing projects in `/dev` are treated as **component libraries, not blueprints**. We **reuse code, not apps** — features are harvested from multiple projects, regrouped by function, and composed into a layered architecture. Every service (providers, terminal, git, approvals, audit, agent runtime) exists **once** and is shared. See **10-LAYERED-ARCHITECTURE.md** for the authoritative component harvest map and the four-activity UI model (Develop · Analyze · Lab · Orchestrate).

---

## Design Philosophy

| Principle | Implementation |
|-----------|----------------|
| **Layered, Not App-Shaped** | Kernel → Core Services → Domain Engines → Activities; no layer duplicates another |
| **Harvest Components, Not Apps** | Each component (provider, policy engine, tool loop) comes from the strongest existing implementation; duplication across old projects is deleted, not ported |
| **Unified Data Layer** | Single source of truth via SwiftData + shared model registry |
| **Model-Agnostic** | Works with Ollama, Ollama Cloud, OpenRouter, NVIDIA NIM, Apple Foundation/PCC, MLX, custom endpoints |
| **Privacy-First** | On-device by default; Private Cloud Compute opt-in; no telemetry without consent |
| **Native Performance** | Swift 6, Metal/Accelerate, App Sandbox + Hardened Runtime |
| **Extensible** | Plugin SDK for third-party modules; MCP server integration built-in |

---

## Feature Regrouping (Function, Not Origin)

Existing projects solved overlapping problems independently. SuperMetaApp keeps the **best implementation of each component** and regroups by function:

| Unified Feature | Harvested from | Merged because |
|-----------------|----------------|----------------|
| **One model layer** | OpenClaudeCodexDesktop + AppleHarness + System5 + AILab | All four built providers; each is strongest for different providers |
| **One agent runtime** | AppleHarness (dual-gate loop) + System5 (policy rules) | Chat and swarm both need the same tool-call loop |
| **One policy/approval system** | System5 (persistence, revocation) + AppleHarness (UI gates) | Both halves required; neither is complete alone |
| **One audit trail** | System5 (hash-chained, tested) | RE, training, builds, and agents all write to it |
| **One terminal** | OpenClaudeCodexDesktop (SwiftTerm PTY) | Editor dock, agent tools, and swarm sandboxes share it |
| **One MCP service** | OpenClaudeCodexDesktop + ghidraclone axiom server | Tools served by the app, not separate servers |
| **One model store** | Axiom RE universal store + AppleHarness fix doc | HF_HUB_CACHE layout shared by everything |
| **One file index** | OpenClaudeCodexDesktop + RealNexus FTS5 patterns | @-mentions, IDE search, agent search all use it |
| **RE engine** | Axiom RE (ghidraclone) — tested core + ToolBelt | Ported as an engine, surfaced only in Analyze activity |
| **Training engines** | AILab — verified CreateML/MLX/distillation/scratch | Ported as engines, surfaced only in Lab activity |

The four **activities** (Develop, Analyze, Lab, Orchestrate) are UI arrangements over shared services — not five apps glued together. See **10-LAYERED-ARCHITECTURE.md**.

---

## Unified Architecture

```
SuperMetaApp/
├── App/                          # SwiftUI App Entry (@main)
│   ├── App.swift
│   ├── AppDelegate.swift
│   ├── Entitlements.plist
│   └── ModuleRegistry.swift      # Dynamic module loading
│
├── Core/                         # Shared Infrastructure
│   ├── Models/                   # SwiftData models (unified)
│   │   ├── Workspace.swift
│   │   ├── Project.swift
│   │   ├── Conversation.swift
│   │   ├── ModuleManifest.swift
│   │   └── ModelRegistry.swift
│   ├── Services/                 # Core services (singletons)
│   │   ├── ModuleManager.swift
│   │   ├── SettingsService.swift
│   │   ├── KeychainService.swift
│   │   ├── NotificationService.swift
│   │   └── TelemetryService.swift (opt-in)
│   ├── Contracts/                # Module protocols
│   │   ├── ModuleProtocol.swift
│   │   ├── ToolProtocol.swift
│   │   ├── ProviderProtocol.swift
│   │   └── AgentProtocol.swift
│   ├── Providers/                # Model provider abstractions
│   │   ├── ModelProviderProtocol.swift
│   │   ├── OpenCodeProvider.swift
│   │   ├── NVIDIANIMProvider.swift
│   │   ├── OpenRouterProvider.swift
│   │   ├── CustomEndpointProvider.swift
│   │   ├── AppleFoundationProvider.swift
│   │   └── MLXProvider.swift
│   ├── Reasoning/                # Reasoning controls
│   │   ├── ReasoningConfig.swift
│   │   └── ReasoningEngine.swift
│   ├── MCP/                      # MCP client/server
│   │   ├── MCPClientService.swift
│   │   ├── MCPServerRegistry.swift
│   │   └── MCPProtocol.swift
│   └── UniversalStore/           # Shared model/data store
│       ├── UniversalModelStore.swift
│       ├── ModelCacheManager.swift
│       └── DatasetManager.swift
│
├── Modules/                      # Loadable Modules (Plug-ins)
│   ├── DevelopmentPlatform/      # Xcode-class IDE
│   │   ├── Module.swift
│   │   ├── SourceEditor/         # Code editor (Swift/ObjC/C++/Python/JS/TS/Rust)
│   │   ├── ProjectNavigator/
│   │   ├── BuildSystem/          # SwiftPM + xcodebuild + Bazel
│   │   ├── Debugger/             # LLDB integration
│   │   ├── SimulatorManager/
│   │   ├── InterfaceBuilder/
│   │   ├── AssetCatalog/
│   │   ├── TestNavigator/
│   │   ├── SourceControl/
│   │   ├── Refactoring/
│   │   └── QuickHelp/
│   │
│   ├── ReverseEngineering/       # Ghidra/Axiom RE Console
│   │   ├── Module.swift
│   │   ├── BinaryInspector/
│   │   ├── Disassembler/         # Ghidra headless + radare2
│   │   ├── Decompiler/
│   │   ├── FunctionAnalyzer/
│   │   ├── StringAnalyzer/
│   │   ├── CryptoScanner/
│   │   ├── EntropyAnalyzer/
│   │   ├── FormatCarver/
│   │   ├── AutoDecryptor/
│   │   ├── RuleScanner/          # YARA-syntax
│   │   ├── GadgetFinder/         # ROP/JOP
│   │   ├── DumpForensics/
│   │   ├── FirmwareAnalyzer/
│   │   ├── DeviceConsole/
│   │   ├── ScriptingConsole/     # JavaScriptCore with axiom API
│   │   └── ProjectStore/         # Analysis persistence
│   │
│   ├── ModelLab/                 # AI/ML Model Laboratory
│   │   ├── Module.swift
│   │   ├── ModelRegistry/        # Unified model catalog
│   │   ├── Training/
│   │   │   ├── CreateMLProvider.swift    # Text/Tabular/Image classifiers
│   │   │   ├── MLXFineTuningProvider.swift  # LoRA/QLoRA/Full
│   │   │   ├── DistillationProvider.swift   # Synthetic data distillation
│   │   │   ├── FromScratchProvider.swift    # Char-level transformers
│   │   │   └── ReinforcementProvider.swift  # RFT/DPO/GRPO
│   │   ├── Inference/
│   │   │   ├── MLXInferenceProvider.swift
│   │   │   ├── CoreMLInferenceProvider.swift
│   │   │   ├── AppleFoundationProvider.swift
│   │   │   └── BenchmarkRunner.swift
│   │   ├── Data/
│   │   │   ├── DatasetImporter.swift
│   │   │   ├── HuggingFaceDatasetProvider.swift
│   │   │   ├── DataAugmentation.swift
│   │   │   └── TokenizerManager.swift
│   │   ├── Evaluation/
│   │   │   ├── AutoPromptEngine.swift
│   │   │   ├── MetricCalculator.swift
│   │   │   ├── ComparisonDashboard.swift
│   │   │   └── RedTeamHarness.swift
│   │   └── Deployment/
│   │       ├── CoreMLExporter.swift
│   │       ├── ONNXExporter.swift
│   │       ├── GGUFExporter.swift
│   │       └── MLXPackageExporter.swift
│   │
│   ├── AgenticConsole/           # AI Agentic Harness
│   │   ├── Module.swift
│   │   ├── ChatInterface/
│   │   │   ├── ConversationView.swift
│   │   │   ├── ComposerView.swift
│   │   │   ├── MessageBubble.swift
│   │   │   └── ReasoningView.swift
│   │   ├── ModelPicker/
│   │   │   ├── ModelPickerView.swift
│   │   │   ├── ReasoningPanel.swift
│   │   │   └── ProviderSection.swift
│   │   ├── Artifacts/
│   │   │   ├── ArtifactView.swift
│   │   │   ├── CodeArtifactView.swift
│   │   │   ├── MarkdownArtifactView.swift
│   │   │   ├── HTMLArtifactView.swift
│   │   │   └── DataArtifactView.swift
│   │   ├── Terminal/
│   │   │   ├── TerminalView.swift
│   │   │   ├── PTYManager.swift
│   │   │   └── SessionManager.swift
│   │   ├── Sidebar/
│   │   │   ├── ConversationList.swift
│   │   │   ├── MCPServersView.swift
│   │   │   ├── SkillsView.swift
│   │   │   └── AgentsView.swift
│   │   ├── AgentRuntime/
│   │   │   ├── AgentOrchestrator.swift
│   │   │   ├── AgentProfile.swift
│   │   │   ├── ExecutionPolicy.swift
│   │   │   ├── ToolRegistry.swift
│   │   │   └── ApprovalCenter.swift
│   │   └── BrowserAutomation/
│   │       ├── WebKitCDPBridge.swift
│   │       ├── PlaywrightBridge.swift
│   │       ├── ComputerUseAgent.swift
│   │       └── AccessibilityBridge.swift
│   │
│   ├── SwarmingEngine/           # Multi-Agent Orchestration
│   │   ├── Module.swift
│   │   ├── Orchestrator/
│   │   │   ├── SwarmOrchestrator.swift
│   │   │   ├── TaskDecomposer.swift
│   │   │   ├── AgentPool.swift
│   │   │   ├── CoordinationBus.swift
│   │   │   └── ConsensusEngine.swift
│   │   ├── Agents/
│   │   │   ├── PlannerAgent.swift
│   │   │   ├── ImplementerAgent.swift
│   │   │   ├── ReviewerAgent.swift
│   │   │   ├── ResearcherAgent.swift
│   │   │   ├── CoderAgent.swift
│   │   │   └── CustomAgentFactory.swift
│   │   ├── Policies/
│   │   │   ├── SandboxPolicy.swift
│   │   │   ├── NetworkPolicy.swift
│   │   │   ├── ApprovalPolicy.swift
│   │   │   └── ResourcePolicy.swift
│   │   ├── Sandbox/
│   │   │   ├── DockerBackend.swift
│   │   │   ├── SeatbeltBackend.swift
│   │   │   └── SubprocessBackend.swift
│   │   ├── Monitoring/
│   │   │   ├── BehaviorMonitor.swift
│   │   │   ├── AuditLog.swift
│   │   │   ├── TripwireEngine.swift
│   │   │   └── LLMRubric.swift
│   │   └── Approvals/
│   │       ├── ApprovalQueue.swift
│   │       ├── ApprovalUI.swift
│   │       └── EscalationEngine.swift
│   │
│   ├── LegalResearch/            # RealNexus Integration
│   │   ├── Module.swift
│   │   ├── Search/
│   │   │   ├── UnifiedSearchEngine.swift
│   │   │   ├── SourceAdapterProtocol.swift
│   │   │   ├── CourtOpinionAdapter.swift
│   │   │   ├── FederalRegisterAdapter.swift
│   │   │   ├── CongressionalAdapter.swift
│   │   │   ├── SECAdapter.swift
│   │   │   ├── StateLawAdapter.swift
│   │   │   ├── OpenDataPortalAdapter.swift
│   │   │   └── NewsAdapter.swift
│   │   ├── Analysis/
│   │   │   ├── CitationGraph.swift
│   │   │   ├── EntityResolver.swift
│   │   │   ├── AuthorityChecker.swift
│   │   │   └── TimelineBuilder.swift
│   │   ├── Writing/
│   │   │   ├── WritingStudio.swift
│   │   │   ├── TemplateLibrary.swift
│   │   │   ├── QuoteVerifier.swift
│   │   │   └── DraftPackager.swift
│   │   └── Monitoring/
│   │       ├── AlertEngine.swift
│   │       ├── WatchlistManager.swift
│   │       └── ReportScheduler.swift
│   │
│   └── Extensions/               # Extension Points
│       ├── Module.swift
│       ├── PluginSDK/
│       ├── Marketplace/
│       └── Community/
│
├── UI/                           # Shared UI Components
│   ├── DesignSystem/
│   │   ├── Colors.swift
│   │   ├── Typography.swift
│   │   ├── Spacing.swift
│   │   ├── Icons.swift
│   │   └── Animation.swift
│   ├── Components/
│   │   ├── StreamingTextView.swift
│   │   ├── CodeBlockView.swift
│   │   ├── DataTableView.swift
│   │   ├── GraphView.swift
│   │   ├── TimelineView.swift
│   │   ├── DiffView.swift
│   │   ├── HexView.swift
│   │   └── SearchField.swift
│   ├── Layout/
│   │   ├── MainWindow.swift
│   │   ├── ModuleHostView.swift
│   │   ├── SplitViewController.swift
│   │   ├── TabBarController.swift
│   │   └── InspectorPanel.swift
│   └── Themes/
│       ├── ThemeManager.swift
│       ├── LightTheme.swift
│       ├── DarkTheme.swift
│       └── HighContrastTheme.swift
│
├── Native/                       # C/C++/Rust Bridges
│   ├── PTYBridge/
│   ├── LLDBBridge/
│   ├── GhidraBridge/
│   ├── MLXMetalBridge/
│   ├── SQLiteBridge/
│   ├── GitBridge/
│   └── CoreMLBridge/
│
├── Resources/
│   ├── Assets.xcassets/
│   ├── Localizations/
│   ├── Sparkle/
│   └── ModuleManifests/
│
├── Tests/
│   ├── UnitTests/
│   ├── IntegrationTests/
│   ├── UITests/
│   └── ModuleTests/
│
└── Scripts/
    ├── build.sh
    ├── sign.sh
    ├── notarize.sh
    ├── release.sh
    └── module-template.sh
```

---

## Key Integration Patterns

### 1. Module Protocol (All Modules Implement)

```swift
protocol Module: Sendable {
    static var identifier: String { get }
    static var displayName: String { get }
    static var version: String { get }
    static var dependencies: [String] { get }
    static var requiredCapabilities: ModuleCapabilities { get }
    
    func initialize(context: ModuleContext) async throws
    func activate() async throws
    func deactivate() async throws
    func shutdown() async throws
    func handleURL(_ url: URL) async -> Bool
    func contributeMenus() -> [MenuContribution]
    func contributeCommands() -> [CommandContribution]
    func contributeSettings() -> SettingsPane?
}

struct ModuleContext {
    let workspace: Workspace
    let modelRegistry: ModelRegistry
    let mcpClient: MCPClientService
    let settings: SettingsService
    let keychain: KeychainService
    let notificationCenter: NotificationCenter
    let fileManager: FileManager
}
```

### 2. Unified Model Registry

```swift
@Observable
final class ModelRegistry: Sendable {
    static let shared = ModelRegistry()
    
    private var providers: [String: ModelProvider] = [:]
    private var models: [String: ModelDescriptor] = [:]
    private var capabilities: [String: ProviderCapabilities] = [:]
    
    func register(_ provider: ModelProvider) async throws
    func unregister(_ providerID: String) async
    func resolveBestProvider(for task: ModelTask) async -> ModelProvider?
    func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) -> AsyncThrowingStream<ChatChunk, Error>
    func getAvailableModels() async -> [ModelDescriptor]
}
```

### 3. Shared Workspace Model

```swift
@Model
final class Workspace {
    @Attribute(.unique) var id: UUID
    var name: String
    var rootPath: String
    var securityScopedBookmark: Data?
    var modules: [ModuleState]
    var conversations: [Conversation]
    var agents: [AgentProfile]
    var settings: WorkspaceSettings
    var createdAt: Date
    var updatedAt: Date
}

@Model
final class ModuleState {
    var moduleID: String
    var isActive: Bool
    var configuration: Data?  // JSON-serialized module config
    var lastUsed: Date
}
```

---

## Data Flow Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        User Interaction                         │
└────────────────────────────┬────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                    ModuleHostView (UI)                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │   Module A  │  │   Module B  │  │   Module C  │  ...        │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘             │
└─────────┼────────────────┼────────────────┼────────────────────┘
          │                │                │
          ▼                ▼                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Module Manager                                │
│  • Load/Unload  • Dependency Resolution  • Lifecycle            │
└────────────────────────────┬────────────────────────────────────┘
                             │
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│  Model        │   │  MCP          │   │  Universal    │
│  Registry     │   │  Client       │   │  Store        │
└───────┬───────┘   └───────┬───────┘   └───────┬───────┘
        │                   │                   │
        ▼                   ▼                   ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│ Providers:    │   │  Servers:     │   │  Models:      │
│ • OpenCode    │   │  • Filesystem │   │  • LLMs       │
│ • NVIDIA NIM  │   │  • Git        │   │  • Embeddings │
│ • OpenRouter  │   │  • Database   │   │  • Datasets   │
│ • Apple FM    │   │  • Browser    │   │  • Artifacts  │
│ • MLX         │   │  • Custom     │   │  • Checkpoints│
│ • Custom      │   │               │   │               │
└───────────────┘   └───────────────┘   └───────────────┘
```

---

## Security Model

| Layer | Implementation |
|-------|----------------|
| **App Sandbox** | Full sandbox with minimal entitlements |
| **Hardened Runtime** | JIT allowed only for WebView; library validation |
| **Module Isolation** | Each module runs in same process but with capability-based access control |
| **Network** | Per-module network policies; MCP servers user-approved |
| **File Access** | Security-scoped bookmarks; user-selected directories only |
| **Secrets** | Keychain-only storage; never in logs or SwiftData |
| **Code Signing** | Developer ID + Notarization; Sparkle updates with Ed25519 |
| **Module Signing** | Modules signed with same team ID; validation on load |

---

## Configuration & Persistence

```swift
@Observable
final class AppSettings: Codable {
    // Core
    var theme: Theme = .system
    var language: String = Locale.current.languageCode ?? "en"
    var startupModule: String = "AgenticConsole"
    
    // Models
    var defaultProvider: String = "opencode"
    var defaultModel: String = ""
    var reasoningDefaults: ReasoningConfig = .default
    var providerConfigs: [String: ProviderConfig] = [:]
    
    // Modules
    var enabledModules: [String] = Module.allIdentifiers
    var moduleSettings: [String: ModuleConfig] = [:]
    
    // MCP
    var mcpServers: [MCPServerConfig] = []
    var autoDiscoverMCP: Bool = true
    
    // Features
    var enableSwarming: Bool = true
    var enableTelemetry: Bool = false
    var maxConcurrentAgents: Int = 5
    
    // Advanced
    var logLevel: LogLevel = .info
    var crashReporting: Bool = true
}
```

---

## Module Communication Patterns

### 1. Event Bus (Async)
```swift
actor ModuleEventBus {
    static let shared = ModuleEventBus()
    
    func publish<T: ModuleEvent>(_ event: T) async
    func subscribe<T: ModuleEvent>(_ type: T.Type, handler: @escaping @Sendable (T) async -> Void) async
}
```

### 2. Direct Service Access (Sync)
```swift
// Via ModuleContext
context.modelRegistry.streamChat(...)
context.mcpClient.callTool(...)
context.workspaceManager.readFile(...)
```

### 3. Shared State (SwiftData)
```swift
// All modules share the same SwiftData container
@Query var conversations: [Conversation]
@Query var artifacts: [Artifact]
```

---

## Performance Targets

| Metric | Target |
|--------|--------|
| Cold Launch | < 2 seconds |
| Module Activation | < 500ms |
| Memory (idle) | < 150 MB |
| Memory (full load) | < 1 GB |
| Stream First Token (local) | < 500ms |
| Stream First Token (cloud) | < 2s |
| Binary Size | < 200 MB |
| CPU (streaming) | < 15% single core |

---

## Dependencies (Swift Package Manager)

```swift
// Package.swift
dependencies: [
    // Core
    .package(url: "https://github.com/apple/swift-data.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
    
    // UI
    .package(url: "https://github.com/swiftui-charts/swiftui-charts.git", from: "1.0.0"),
    .package(url: "https://github.com/markiv/SwiftUI-Introspect.git", from: "1.0.0"),
    
    // Terminal
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0"),
    
    // Git
    .package(url: "https://github.com/swift-server/swift-libgit2.git", from: "1.0.0"),
    
    // SQLite
    .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.14.0"),
    
    // Networking
    .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.9.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.20.0"),
    
    // WebView
    .package(url: "https://github.com/swift-webui/webui.git", from: "1.0.0"),
    
    // ML/AI
    .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.20.0"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "0.20.0"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", from: "0.1.0"),
    .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.1.0"),
    
    // Crypto/Keychain
    .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.0"),
    .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.0"),
    
    // Yjs (collaboration)
    .package(url: "https://github.com/yjs/yjs-swift.git", from: "0.1.0"),
    
    // Reverse Engineering
    .package(url: "https://github.com/radareorg/radare2-swift.git", from: "1.0.0"),
    
    // Testing
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.15.0"),
]
```

---

## Build & Distribution

```yaml
# CI/CD (GitHub Actions)
- Build: xcodebuild (macOS runners, Xcode 27)
- Test: xcodebuild test + Swift Testing
- Module Tests: Per-module test suites
- Sign: codesign --hardened-runtime + notarytool
- Package: create-dmg / pkgbuild
- Release: GitHub Releases + Sparkle appcast
- Module Index: JSON manifest for plugin marketplace
```

---

## Success Criteria

1. **Single binary** containing all five major capabilities
2. **< 200 MB** download size (with on-demand module loading)
3. **< 2 second** cold launch
4. **Seamless switching** between modules (shared workspace, model, MCP)
5. **Plugin SDK** enabling third-party modules within 6 months
6. **Apple Silicon native** with Intel Rosetta fallback
7. **macOS 14+** (Sonoma) minimum; macOS 15+ (Sequoia) for Apple Intelligence

---

## Document Version

- **Version**: 1.0
- **Date**: 2026-10-15
- **Author**: SuperMetaApp Architecture Team
- **Status**: Draft for Review