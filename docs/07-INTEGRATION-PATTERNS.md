# Kiln — Integration Patterns & Plugin Architecture

## Overview

This document defines the integration patterns that enable seamless communication between modules, the plugin architecture for third-party extensions, and the shared services that bind everything together.

---

## Integration Patterns

### 1. Shared Service Registry Pattern

All modules access core capabilities through a central service registry:

```swift
protocol ServiceRegistry: Sendable {
    func register<T: Sendable>(_ service: T, for protocol: T.Type, name: String?)
    func resolve<T: Sendable>(_ protocol: T.Type, name: String?) -> T?
    func unregister(_ protocol: Any.Type, name: String?)
}

// Usage in ModuleContext
struct ModuleContext: Sendable {
    let serviceRegistry: ServiceRegistry
    // ... other services
}

// Module registers its services
func initialize(context: ModuleContext) async throws {
    context.serviceRegistry.register(MyService(), for: MyServiceProtocol.self)
}

// Other modules consume
let service = context.serviceRegistry.resolve(MyServiceProtocol.self)
```

### 2. Event Bus Pattern (Pub/Sub)

Async, decoupled communication between modules:

```swift
actor ModuleEventBus: Sendable {
    private var subscriptions: [String: [EventHandler]] = [:]
    
    func publish<E: ModuleEvent>(_ event: E) async {
        let topic = E.eventType
        await subscriptions[topic]?.forEach { handler in
            Task { await handler(event) }
        }
        // Also notify wildcard subscribers
        await subscriptions["*"]?.forEach { handler in
            Task { await handler(event) }
        }
    }
    
    func subscribe<E: ModuleEvent>(
        _ type: E.Type,
        handler: @escaping @Sendable (E) async -> Void
    ) async {
        subscriptions[E.eventType, default: []].append(handler)
    }
}

// Cross-module events
struct WorkspaceOpenedEvent: ModuleEvent {
    static let eventType = "workspace.opened"
    let workspaceID: UUID
    let path: String
}

struct ModelSwitchedEvent: ModuleEvent {
    static let eventType = "model.switched"
    let fromModel: String?
    let toModel: String
    let provider: String
}

struct BuildCompletedEvent: ModuleEvent {
    static let eventType = "build.completed"
    let projectID: UUID
    let success: Bool
    let artifacts: [Artifact]
}
```

### 3. Shared Workspace Pattern

All modules operate on a unified workspace model:

```swift
@Model
final class Workspace {
    @Attribute(.unique) var id: UUID
    var name: String
    var rootPath: String
    var securityScopedBookmark: Data?
    
    // Module-specific state
    var moduleStates: [String: ModuleState]
    
    // Shared data
    var conversations: [Conversation]
    var artifacts: [Artifact]
    var gitRepositories: [GitRepository]
    var mcpServers: [MCPServerConfig]
    var modelPreferences: ModelPreferences
}

@Model
final class ModuleState {
    var moduleID: String
    var isActive: Bool
    var configuration: Data?
    var windowState: WindowState?
    var lastUsed: Date
}

// Module reads/writes its state
func activate() async throws {
    let state = workspace.moduleStates[Self.identifier] ?? ModuleState(moduleID: Self.identifier)
    state.isActive = true
    state.lastUsed = Date()
    workspace.moduleStates[Self.identifier] = state
}
```

### 4. Capability Delegation Pattern

Modules declare capabilities; system routes requests to capable modules:

```swift
protocol CapabilityProvider: Sendable {
    var providedCapabilities: [Capability] { get }
    func canHandle(_ request: CapabilityRequest) -> Bool
    func handle(_ request: CapabilityRequest) async throws -> CapabilityResponse
}

struct CapabilityRequest: Sendable {
    let capability: Capability
    let parameters: [String: Any]
    let context: CapabilityContext
}

enum Capability: String, Codable, Sendable {
    // File operations
    case fileRead, fileWrite, fileSearch, fileIndex
    // Code operations
    case codeCompletion, codeGeneration, codeRefactor, codeAnalyze
    // Build operations
    case build, test, debug, deploy
    // Model operations
    case modelInference, modelTraining, modelFineTune, modelExport
    // Analysis operations
    case binaryAnalysis, cryptoScan, vulnerabilityScan
    // Agent operations
    case agentSpawn, agentCoordinate, agentMonitor
    // System operations
    case shellExec, processControl, networkRequest
}

// Capability router
actor CapabilityRouter: Sendable {
    private var providers: [Capability: [CapabilityProvider]] = [:]
    
    func register(_ provider: CapabilityProvider) async {
        for cap in provider.providedCapabilities {
            providers[cap, default: []].append(provider)
        }
    }
    
    func route(_ request: CapabilityRequest) async throws -> CapabilityResponse {
        guard let providers = providers[request.capability], !providers.isEmpty else {
            throw CapabilityError.noProvider(request.capability)
        }
        
        // Select best provider (could use load balancing, priority, etc.)
        let provider = selectProvider(providers, for: request)
        return try await provider.handle(request)
    }
}
```

### 5. Model Provider Abstraction Pattern

Unified interface for all AI model providers:

```swift
protocol ModelProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var providerType: ProviderType { get }
    var capabilities: ProviderCapabilities { get }
    
    func fetchModels() async throws -> [ModelDescriptor]
    func streamChat(
        _ request: ChatRequest,
        reasoning: ReasoningConfig?
    ) async throws -> AsyncThrowingStream<ChatChunk, Error>
    func countTokens(_ messages: [Message]) async throws -> Int
    func checkAvailability() async -> ProviderAvailability
}

// Registry manages all providers
actor ModelRegistry: Sendable {
    private var providers: [String: ModelProvider] = [:]
    
    func register(_ provider: ModelProvider) async {
        providers[provider.id] = provider
    }
    
    func resolveBestProvider(for task: ModelTask) async -> ModelProvider? {
        let available = providers.values.filter { $0.capabilities.contains(task.requiredCapabilities) }
        return selectBest(available, for: task)
    }
    
    func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        let provider = await resolveBestProvider(for: .chat(request.model))
        guard let provider else { throw ModelError.noProvider }
        return try await provider.streamChat(request, reasoning: reasoning)
    }
}
```

### 6. MCP Integration Pattern

Standardized tool/server integration via Model Context Protocol:

```swift
protocol MCPClientProtocol: Sendable {
    func discoverServers() async throws -> [MCPServerConfig]
    func connect(to server: MCPServerConfig) async throws -> MCPConnection
    func listTools() async -> [MCPTool]
    func callTool(_ name: String, arguments: [String: Any]) async throws -> MCPToolResult
    func listResources() async -> [MCPResource]
    func readResource(_ uri: String) async throws -> MCPResourceContent
    func listPrompts() async -> [MCPPrompt]
    func getPrompt(_ name: String, arguments: [String: String]) async throws -> MCPPromptResult
}

// Module contributes MCP tools
func contributeMCPTools() -> [MCPTool] {
    [
        MCPTool(
            name: "dev_build",
            description: "Build the current project",
            inputSchema: .object(["configuration": .string.optional])
        ),
        MCPTool(
            name: "dev_test",
            description: "Run tests",
            inputSchema: .object(["filter": .string.optional])
        ),
        MCPTool(
            name: "re_analyze",
            description: "Analyze a binary function",
            inputSchema: .object(["address": .string, "project_id": .string])
        ),
        MCPTool(
            name: "ml_train",
            description: "Start a training job",
            inputSchema: .object(["model": .string, "dataset": .string, "config": .object([:])])
        )
    ]
}
```

---

## Plugin Architecture

### Plugin Manifest

```json
{
  "identifier": "com.example.myplugin",
  "displayName": "My Plugin",
  "version": "1.0.0",
  "minAppVersion": "1.0.0",
  "author": "Developer Name",
  "license": "MIT",
  "description": "Plugin description",
  "category": "utility",
  "icon": "plugin-icon",
  "entryPoint": "MyPluginModule",
  "dependencies": [
    "com.kiln.core",
    "com.kiln.modelregistry"
  ],
  "requiredCapabilities": [
    "fileSystem.readWrite",
    "network.client"
  ],
  "provides": [
    "customTool",
    "customView",
    "customCommand"
  ],
  "settingsSchema": "SettingsSchema.json",
  "hooks": {
    "onWorkspaceOpen": "handleWorkspaceOpen",
    "onModelSwitch": "handleModelSwitch",
    "onBuildComplete": "handleBuildComplete"
  }
}
```

### Plugin Module Protocol

```swift
protocol PluginModule: Module {
    // Standard module lifecycle
    func initialize(context: ModuleContext) async throws
    func activate() async throws
    func deactivate() async throws
    func shutdown() async throws
    
    // Plugin-specific
    func getManifest() -> PluginManifest
    func validateSignature() async -> Bool
    func checkCompatibility() async -> CompatibilityResult
}

// Plugin manager handles loading/unloading
final class PluginManager: Sendable {
    private var loadedPlugins: [String: PluginModule] = [:]
    private let pluginDirectory: URL
    
    func loadPlugin(at url: URL) async throws -> PluginModule {
        // 1. Verify signature
        try await verifyPluginSignature(url)
        
        // 2. Load manifest
        let manifest = try await loadManifest(url)
        
        // 3. Check compatibility
        try await checkCompatibility(manifest)
        
        // 4. Check dependencies
        try await ensureDependencies(manifest.dependencies)
        
        // 5. Load dynamic library
        let module = try await loadModule(from: url, entryPoint: manifest.entryPoint)
        
        // 6. Initialize
        let context = createModuleContext(for: manifest)
        try await module.initialize(context: context)
        
        // 7. Register
        loadedPlugins[manifest.identifier] = module
        
        return module
    }
    
    func unloadPlugin(_ identifier: String) async throws {
        guard let plugin = loadedPlugins[identifier] else { return }
        
        try await plugin.deactivate()
        try await plugin.shutdown()
        
        // Unload dynamic library
        try await unloadModule(plugin)
        
        loadedPlugins.removeValue(forKey: identifier)
    }
}
```

### Plugin Sandbox

```swift
final class PluginSandbox: Sendable {
    func execute(
        _ plugin: PluginModule,
        operation: PluginOperation
    ) async throws -> PluginResult {
        // Create restricted environment
        let environment = createRestrictedEnvironment(for: plugin)
        
        // Execute with capability limits
        return try await withCapabilityLimits(plugin.manifest.requiredCapabilities) {
            try await operation.execute(in: environment)
        }
    }
    
    private func createRestrictedEnvironment(for plugin: PluginModule) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PLUGIN_ID"] = plugin.manifest.identifier
        env["PLUGIN_HOME"] = plugin.manifest.bundleURL.path
        env["PLUGIN_DATA"] = plugin.dataDirectory.path
        env["PLUGIN_PERMISSIONS"] = plugin.manifest.requiredCapabilities.map(\.rawValue).joined(separator: ",")
        return env
    }
}
```

### Plugin Marketplace

```swift
struct PluginMarketplaceIndex: Codable {
    let version: Int
    let updated: Date
    let plugins: [PluginListing]
}

struct PluginListing: Codable {
    let identifier: String
    let displayName: String
    let version: String
    let author: String
    let repository: URL
    let releaseURL: URL
    let checksum: String
    let minAppVersion: String
    let categories: [String]
    let description: String
    let screenshots: [URL]
    let license: String
    let price: Price
}

enum Price: Codable {
    case free
    case paid(amount: Decimal, currency: String)
    case subscription(monthly: Decimal, currency: String)
}

// Installation flow
final class PluginInstaller: Sendable {
    func install(from listing: PluginListing) async throws {
        // 1. Download plugin bundle
        let bundleURL = try await downloadPlugin(listing.releaseURL, expectedChecksum: listing.checksum)
        
        // 2. Verify signature
        try await verifyAppleDeveloperSignature(bundleURL)
        
        // 3. Extract to plugin directory
        let pluginDir = try await extractPlugin(bundleURL)
        
        // 4. Load and validate
        let plugin = try await PluginManager.shared.loadPlugin(at: pluginDir)
        
        // 5. Activate
        try await plugin.activate()
        
        // 6. Notify user
        await NotificationService.shared.show(.pluginInstalled(plugin.manifest.displayName))
    }
}
```

---

## Cross-Module Workflows

### Workflow 1: Code Development with AI Assistance

```
User writes code in DevPlatform
        │
        ▼
AgenticConsole provides completions via ModelRegistry
        │
        ▼
User requests refactoring → AgenticConsole spawns CoderAgent
        │
        ▼
CoderAgent uses DevPlatform's refactoring tools via CapabilityRouter
        │
        ▼
Changes applied → DevPlatform shows diff → User approves
        │
        ▼
Tests run via DevPlatform → Results shown in AgenticConsole
        │
        ▼
SwarmingEngine can coordinate multi-file refactoring
```

### Workflow 2: Reverse Engineering with AI Analysis

```
User loads binary in ReverseEngineering
        │
        ▼
User requests function analysis → ReverseEngineering publishes event
        │
        ▼
AgenticConsole receives event → Spawns ResearcherAgent
        │
        ▼
ResearcherAgent uses RE's MCP tools to gather context
        │
        ▼
ModelRegistry provides best model for analysis
        │
        ▼
Analysis result → Artifact created → Shown in both modules
        │
        ▼
SwarmingEngine can coordinate multi-function analysis
```

### Workflow 3: Model Training and Deployment

```
User creates dataset in ModelLab
        │
        ▼
User configures training → ModelLab starts training job
        │
        ▼
Training progress → Published to EventBus
        │
        ▼
AgenticConsole shows live progress → User can monitor
        │
        ▼
Training complete → Model registered in UnifiedModelStore
        │
        ▼
DevPlatform can deploy model → ReverseEngineering can analyze model
        │
        ▼
SwarmingEngine can run distributed training
```

### Workflow 4: Security Audit Pipeline

```
User initiates audit in ReverseEngineering
        │
        ▼
SwarmingEngine spawns specialized agents:
  - CryptoScannerAgent (uses RE's crypto scanner)
  - VulnerabilityAgent (uses RE's gadget finder)
  - CodeReviewAgent (uses DevPlatform's analysis)
  - ComplianceAgent (uses LegalResearch if needed)
        │
        ▼
Agents coordinate via CoordinationBus
        │
        ▼
Findings aggregated → Audit report generated as Artifact
        │
        ▼
Report available in all modules
```

---

## Data Flow Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        USER INTERACTION                         │
└────────────────────────────┬────────────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                      MODULE HOST VIEW                           │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐   │
│  │  Module A  │ │  Module B  │ │  Module C  │ │  Module D  │   │
│  └─────┬──────┘ └─────┬──────┘ └─────┬──────┘ └─────┬──────┘   │
└────────┼──────────────┼──────────────┼──────────────┼───────────┘
         │              │              │              │
         ▼              ▼              ▼              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      MODULE MANAGER                              │
│  • Lifecycle    • Dependencies   • Capabilities   • Events      │
└────────────────────────────┬────────────────────────────────────┘
                             │
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│   SERVICE        │ │   EVENT BUS      │ │   SHARED STATE   │
│   REGISTRY       │ │                  │ │   (SwiftData)    │
│                  │ │  • Workspace     │ │                  │
│  • ModelRegistry │ │  • ModelSwitch   │ │  • Workspaces    │
│  • MCPClient     │ │  • BuildDone     │ │  • Conversations │
│  • WorkspaceMgr  │ │  • FileChange    │ │  • Artifacts     │
│  • TerminalSvc   │ │  • AgentEvent    │ │  • Models        │
│  • GitService    │ │  • AuditEvent    │ │  • Settings      │
└──────────────────┘ └──────────────────┘ └──────────────────┘
         │                   │                   │
         ▼                   ▼                   ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│   PROVIDERS      │ │   MCP SERVERS    │ │   UNIVERSAL      │
│                  │ │                  │ │   MODEL STORE    │
│  • OpenCode      │ │  • Filesystem    │ │                  │
│  • NVIDIA NIM    │ │  • Git           │ │  • HF Cache      │
│  • OpenRouter    │ │  • Database      │ │  • Local Models  │
│  • Apple FM      │ │  • Browser       │ │  • Datasets      │
│  • MLX           │ │  • Custom        │ │  • Checkpoints   │
│  • Custom        │ │                  │ │                  │
└──────────────────┘ └──────────────────┘ └──────────────────┘
```

---

## Security Boundaries

### Module Isolation

| Boundary | Enforcement |
|----------|-------------|
| **Process** | Single process (performance), capability-based access control |
| **Capabilities** | Declared in manifest, granted by user, enforced at runtime |
| **File System** | Security-scoped bookmarks, workspace-rooted paths |
| **Network** | Per-module allowlist, MCP server approval |
| **Secrets** | Keychain namespaced by module identifier |
| **IPC** | Event bus with topic-based routing, no direct module-to-module calls |

### Plugin Security

```swift
struct PluginSecurityPolicy: Codable {
    let identifier: String
    let allowedCapabilities: [Capability]
    let allowedDomains: [String]  // Network
    let allowedPaths: [String]    // File system (relative to workspace)
    let maxMemoryMB: Int
    let maxCPUPercent: Int
    let executionTimeout: TimeInterval
    let requireApprovalFor: [ApprovalTrigger]
}

enum ApprovalTrigger: String, Codable {
    case fileWriteOutsideWorkspace
    case networkRequestToNewDomain
    case shellCommandExecution
    case capabilityRequest
    case settingsModification
}
```

---

## Extension Points

### 1. UI Extension Points

```swift
protocol UIExtensionPoint: Sendable {
    associatedtype ExtensionView: View
    var identifier: String { get }
    func makeView(context: ExtensionContext) -> ExtensionView
}

// Available extension points
let sidebarExtensions = UIExtensionPoint<SidebarExtensionView>()
let toolbarExtensions = UIExtensionPoint<ToolbarExtensionView>()
let inspectorExtensions = UIExtensionPoint<InspectorExtensionView>()
let statusBarExtensions = UIExtensionPoint<StatusBarExtensionView>()
let contextMenuExtensions = UIExtensionPoint<ContextMenuExtensionView>()
```

### 2. Command Extension Points

```swift
protocol CommandExtension: Sendable {
    var identifier: String { get }
    var title: String { get }
    var shortcut: KeyEquivalent? { get }
    var category: String { get }
    func execute(context: CommandContext) async throws
}
```

### 3. Model Provider Extension

```swift
protocol ModelProviderExtension: Sendable {
    var providerType: ProviderType { get }
    var supportedModels: [ModelArchitecture] { get }
    func createProvider(config: ProviderConfig) async throws -> ModelProvider
}
```

### 4. Language Server Extension

```swift
protocol LanguageServerExtension: Sendable {
    var language: String { get }
    var fileExtensions: [String] { get }
    func createClient(rootURI: URL) async throws -> LanguageServerClient
}
```

---

## Configuration Management

### Layered Configuration

```swift
final class ConfigurationManager: Sendable {
    // Layers (highest priority first)
    private let layers: [ConfigurationLayer] = [
        .commandLine,      // --flag=value
        .environment,      // ENV vars
        .userConfig,       // ~/Library/Application Support/Kiln/config.json
        .workspaceConfig,  // .kiln/config.json
        .moduleDefaults,   // Module-provided defaults
        .appDefaults       // Built-in defaults
    ]
    
    func get<T: Codable>(_ key: String) -> T? {
        for layer in layers {
            if let value = layer.get(key) {
                return value
            }
        }
        return nil
    }
}
```

### Module Configuration Schema

```json
{
  "moduleIdentifier": "com.kiln.agenticconsole",
  "version": "1.0.0",
  "settings": [
    {
      "key": "defaultProvider",
      "type": "string",
      "default": "opencode",
      "options": ["opencode", "nim", "openrouter", "custom", "apple", "mlx"],
      "title": "Default Provider"
    },
    {
      "key": "reasoningDefaults.budget",
      "type": "enum",
      "default": "medium",
      "options": ["low", "medium", "high", "unlimited"],
      "title": "Default Reasoning Budget"
    },
    {
      "key": "enableArtifacts",
      "type": "boolean",
      "default": true,
      "title": "Enable Artifacts"
    }
  ],
  "secrets": [
    "openRouterConfig.apiKey",
    "nimConfig.apiKey",
    "customEndpoints[*].apiKey"
  ]
}
```

---

## Testing Integration

### Contract Testing

```swift
// Each module defines its contracts
protocol ModelProviderContract {
    func fetchModels() async throws -> [ModelDescriptor]
    func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error>
}

// Contract tests run against all implementations
class ModelProviderContractTests: XCTestCase {
    var providers: [ModelProvider] = []
    
    override func setUp() {
        providers = [
            OpenCodeProvider(baseURL: URL(string: "http://localhost:11434")!),
            NVIDIANIMProvider(apiKey: "test"),
            OpenRouterProvider(apiKey: "test"),
            AppleFoundationProvider(),
            MLXProvider(modelRegistry: .shared)
        ]
    }
    
    func testFetchModels() async throws {
        for provider in providers {
            let models = try await provider.fetchModels()
            XCTAssertFalse(models.isEmpty, "\(provider.id) should return models")
        }
    }
    
    func testStreamChat() async throws {
        let request = ChatRequest(messages: [Message(role: .user, content: "Hello")])
        
        for provider in providers {
            let stream = try await provider.streamChat(request, reasoning: .default)
            var received = false
            for try await _ in stream {
                received = true
                break
            }
            XCTAssertTrue(received, "\(provider.id) should stream response")
        }
    }
}
```

### Integration Test Harness

```swift
final class IntegrationTestHarness: Sendable {
    let app: Kiln
    let moduleManager: ModuleManager
    let serviceRegistry: ServiceRegistry
    let eventBus: ModuleEventBus
    
    func withModules(_ identifiers: [String], test: @escaping (ModuleContext) async throws -> Void) async throws {
        // Load modules
        for id in identifiers {
            try await moduleManager.loadModule(id)
        }
        
        // Create test context
        let context = ModuleContext(
            workspace: try await createTestWorkspace(),
            serviceRegistry: serviceRegistry,
            eventBus: eventBus
            // ...
        )
        
        // Run test
        try await test(context)
        
        // Cleanup
        for id in identifiers.reversed() {
            try await moduleManager.unloadModule(id)
        }
    }
}
```

---

## Performance Optimization

### Lazy Module Loading

```swift
final class ModuleManager: Sendable {
    private var moduleFactories: [String: @Sendable () async throws -> Module] = [:]
    private var loadedModules: [String: Module] = [:]
    
    func registerFactory(_ identifier: String, factory: @escaping @Sendable () async throws -> Module) {
        moduleFactories[identifier] = factory
    }
    
    func getModule(_ identifier: String) async throws -> Module {
        if let module = loadedModules[identifier] {
            return module
        }
        
        guard let factory = moduleFactories[identifier] else {
            throw ModuleError.notFound(identifier)
        }
        
        let module = try await factory()
        loadedModules[identifier] = module
        return module
    }
}
```

### Shared Resource Pooling

```swift
actor ResourcePool: Sendable {
    private var httpClients: [String: HTTPClient] = [:]
    private var databaseConnections: [String: DatabaseConnection] = [:]
    private var processRunners: [ProcessRunner] = []
    
    func httpClient(for provider: String) -> HTTPClient {
        if let client = httpClients[provider] { return client }
        let client = HTTPClient(configuration: providerConfig(provider))
        httpClients[provider] = client
        return client
    }
    
    func acquireProcessRunner() -> ProcessRunner {
        if let runner = processRunners.popLast() { return runner }
        return ProcessRunner()
    }
    
    func releaseProcessRunner(_ runner: ProcessRunner) {
        processRunners.append(runner)
    }
}
```

---

## Migration & Versioning

### Module Version Compatibility

```swift
struct ModuleVersion: Codable, Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    
    static func < (lhs: ModuleVersion, rhs: ModuleVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct CompatibilityMatrix: Codable {
    let moduleAPIVersion: ModuleVersion
    let supportedAppVersions: ClosedRange<ModuleVersion>
    let deprecatedAppVersions: [ModuleVersion]
    let breakingChanges: [BreakingChange]
}

struct BreakingChange: Codable {
    let version: ModuleVersion
    let description: String
    let migrationGuide: URL
}
```

---

## Observability

### Structured Logging

```swift
protocol ModuleLogger: Sendable {
    func debug(_ message: String, metadata: [String: Any])
    func info(_ message: String, metadata: [String: Any])
    func warning(_ message: String, metadata: [String: Any])
    func error(_ message: String, metadata: [String: Any], error: Error?)
}

extension ModuleLogger {
    func log(level: LogLevel, _ message: String, metadata: [String: Any] = [:], error: Error? = nil) {
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            module: Self.moduleIdentifier,
            message: message,
            metadata: metadata,
            error: error?.localizedDescription
        )
        // Send to unified logging
    }
}
```

### Metrics Collection

```swift
protocol MetricsCollector: Sendable {
    func increment(_ name: String, tags: [String: String])
    func histogram(_ name: String, value: Double, tags: [String: String])
    func gauge(_ name: String, value: Double, tags: [String: String])
    func timing(_ name: String, duration: TimeInterval, tags: [String: String])
}

// Auto-instrumented metrics
extension ModelProvider {
    func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        let start = Date()
        let providerID = self.id
        
        return try await MetricsCollector.shared.withTiming("model.stream_chat.duration", tags: ["provider": providerID]) {
            try await self.streamChat(request, reasoning: reasoning)
        }
    }
}
```

---

## Document Version

- **Version**: 1.0
- **Date**: 2026-10-15
- **Status**: Draft for Review