# SuperMetaApp — Modular Architecture Specification

## Overview

This document defines the plug-in architecture that allows SuperMetaApp to be extensible, maintainable, and capable of integrating diverse capabilities as loadable modules.

---

## Module System Design

### Core Principles

1. **Explicit Contracts** — Every module declares its capabilities, dependencies, and requirements
2. **Capability-Based Access** — Modules request permissions; system grants based on policy
3. **Isolation by Default** — Modules cannot access each other's internals without explicit APIs
4. **Lifecycle Management** — Deterministic initialization, activation, deactivation, shutdown
5. **Versioned Compatibility** — Semantic versioning with compatibility matrix

### Module Manifest

Each module includes a `ModuleManifest.json`:

```json
{
  "identifier": "com.supermeta.devplatform",
  "displayName": "Development Platform",
  "version": "1.0.0",
  "minAppVersion": "1.0.0",
  "maxAppVersion": "2.0.0",
  "author": "SuperMetaApp Team",
  "license": "Proprietary",
  "description": "Xcode-class IDE with build, debug, test, and deploy",
  "category": "development",
  "icon": "hammer.fill",
  "dependencies": [
    "com.supermeta.core",
    "com.supermeta.modelregistry",
    "com.supermeta.mcp",
    "com.supermeta.workspace"
  ],
  "requiredCapabilities": [
    "fileSystem.readWrite",
    "process.spawn",
    "network.client",
    "network.server",
    "debugger.attach",
    "simulator.control"
  ],
  "optionalCapabilities": [
    "cloudKit.sync",
    "metal.compute"
  ],
  "provides": [
    "sourceEditor",
    "projectNavigator",
    "buildSystem",
    "debugger",
    "interfaceBuilder",
    "assetCatalog",
    "testRunner",
    "refactoringTools",
    "quickHelp"
  ],
  "entryPoint": "DevelopmentPlatformModule",
  "resources": [
    "Assets.xcassets",
    "Localizations",
    "Templates"
  ],
  "settingsSchema": "SettingsSchema.json",
  "commands": [
    {
      "identifier": "build",
      "title": "Build Project",
      "shortcut": "⌘B",
      "category": "Build"
    },
    {
      "identifier": "run",
      "title": "Run",
      "shortcut": "⌘R",
      "category": "Run"
    },
    {
      "identifier": "test",
      "title": "Test",
      "shortcut": "⌘U",
      "category": "Test"
    }
  ],
  "menus": [
    {
      "title": "Product",
      "items": ["build", "run", "test", "archive", "profile"]
    },
    {
      "title": "Debug",
      "items": ["pause", "continue", "stepOver", "stepInto", "stepOut"]
    }
  ]
}
```

---

## Module Lifecycle

```
┌─────────────┐
│  Discovered │  ← ModuleManager scans ModuleManifests
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  Validated  │  ← Dependency resolution, capability check, signature verify
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  Loaded     │  ← Dynamic library loaded; ModuleProtocol conformance checked
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ Initialized │  ← Module.initialize(context) called
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  Activated  │  ← Module.activate() called; UI contributed, services registered
└──────┬──────┘
       │
       ▼
┌─────────────┐     ┌─────────────┐
│  Running    │────▶│ Deactivated │  ← Module.deactivate() called on switch/unload
└─────────────┘     └──────┬──────┘
                            │
                            ▼
                     ┌─────────────┐
                     │  Shutdown   │  ← Module.shutdown() called on app quit
                     └─────────────┘
```

### Lifecycle Methods

```swift
protocol Module: Sendable {
    // Called once after loading, before activation
    func initialize(context: ModuleContext) async throws
    
    // Called when module becomes active (UI shown, services started)
    func activate() async throws
    
    // Called when module becomes inactive (UI hidden, services paused)
    func deactivate() async throws
    
    // Called once before unloading (cleanup, save state)
    func shutdown() async throws
    
    // Handle custom URL schemes
    func handleURL(_ url: URL) async -> Bool
    
    // Contribute to main menu
    func contributeMenus() -> [MenuContribution]
    
    // Contribute command palette commands
    func contributeCommands() -> [CommandContribution]
    
    // Provide settings pane
    func contributeSettings() -> SettingsPane?
}
```

---

## Module Context

The `ModuleContext` provides controlled access to system services:

```swift
struct ModuleContext: Sendable {
    // Workspace
    let workspace: Workspace
    let workspaceManager: WorkspaceManagerProtocol
    
    // Models
    let modelRegistry: ModelRegistryProtocol
    
    // MCP
    let mcpClient: MCPClientProtocol
    let mcpServerRegistry: MCPServerRegistryProtocol
    
    // Settings & Secrets
    let settings: SettingsServiceProtocol
    let keychain: KeychainServiceProtocol
    
    // System
    let notificationCenter: NotificationCenter
    let fileManager: FileManager
    let processRunner: ProcessRunnerProtocol
    
    // UI
    let mainWindow: MainWindowProtocol?
    let moduleHost: ModuleHostProtocol
    
    // Logging
    let logger: ModuleLogger
    
    // Module-to-Module Communication
    let eventBus: ModuleEventBus
    let serviceRegistry: ServiceRegistry
}
```

### Capability-Based Access Control

```swift
struct ModuleCapabilities: OptionSet, Codable, Sendable {
    let rawValue: UInt64
    
    // File System
    static let fileSystemRead       = ModuleCapabilities(rawValue: 1 << 0)
    static let fileSystemWrite      = ModuleCapabilities(rawValue: 1 << 1)
    static let fileSystemExecute    = ModuleCapabilities(rawValue: 1 << 2)
    static let fileSystemAdmin      = ModuleCapabilities(rawValue: 1 << 3)
    
    // Process
    static let processSpawn         = ModuleCapabilities(rawValue: 1 << 4)
    static let processAttach        = ModuleCapabilities(rawValue: 1 << 5)
    static let processDebug         = ModuleCapabilities(rawValue: 1 << 6)
    static let processControl       = ModuleCapabilities(rawValue: 1 << 7)
    
    // Network
    static let networkClient        = ModuleCapabilities(rawValue: 1 << 8)
    static let networkServer        = ModuleCapabilities(rawValue: 1 << 9)
    static let networkRaw           = ModuleCapabilities(rawValue: 1 << 10)
    static let networkVPN           = ModuleCapabilities(rawValue: 1 << 11)
    
    // System
    static let systemInfo           = ModuleCapabilities(rawValue: 1 << 12)
    static let systemAdmin          = ModuleCapabilities(rawValue: 1 << 13)
    static let kernelExtension      = ModuleCapabilities(rawValue: 1 << 14)
    
    // Hardware
    static let metalCompute         = ModuleCapabilities(rawValue: 1 << 15)
    static let neuralEngine         = ModuleCapabilities(rawValue: 1 << 16)
    static let cameraAccess         = ModuleCapabilities(rawValue: 1 << 17)
    static let microphoneAccess     = ModuleCapabilities(rawValue: 1 << 18)
    static let usbAccess            = ModuleCapabilities(rawValue: 1 << 19)
    static let bluetoothAccess      = ModuleCapabilities(rawValue: 1 << 20)
    
    // Data
    static let keychainRead         = ModuleCapabilities(rawValue: 1 << 21)
    static let keychainWrite        = ModuleCapabilities(rawValue: 1 << 22)
    static let cloudKitSync         = ModuleCapabilities(rawValue: 1 << 23)
    static let iCloudDrive          = ModuleCapabilities(rawValue: 1 << 24)
    
    // Special
    static let debuggerAttach       = ModuleCapabilities(rawValue: 1 << 25)
    static let simulatorControl     = ModuleCapabilities(rawValue: 1 << 26)
    static let kernelDebug          = ModuleCapabilities(rawValue: 1 << 27)
    static let memoryInspection     = ModuleCapabilities(rawValue: 1 << 28)
    static let codeSigning          = ModuleCapabilities(rawValue: 1 << 29)
    static let entitlementManagement = ModuleCapabilities(rawValue: 1 << 30)
}
```

### Capability Granting Flow

```
Module Manifest declares requiredCapabilities
        │
        ▼
ModuleManager validates against:
  • App Entitlements
  • User Policy (Settings → Security → Module Permissions)
  • System Policy (Sandbox, Hardened Runtime)
        │
        ▼
GrantedCapabilities = Required ∩ Allowed
        │
        ▼
If Required ⊈ Allowed:
  → Module load fails with specific missing capabilities
  → User prompted to grant in Settings
        │
        ▼
Module.initialize() receives granted capabilities in context
```

---

## Service Registry

Modules can expose and consume services:

```swift
protocol ServiceRegistry: Sendable {
    func register<T: Sendable>(_ service: T, for protocol: T.Type, name: String?)
    func resolve<T: Sendable>(_ protocol: T.Type, name: String?) -> T?
    func unregister(_ protocol: Any.Type, name: String?)
}

// Usage
// Provider module registers
serviceRegistry.register(MLXInferenceProvider(), for: ModelProviderProtocol.self, name: "mlx")

// Consumer module resolves
if let provider = serviceRegistry.resolve(ModelProviderProtocol.self, name: "mlx") {
    // Use provider
}
```

---

## Event Bus

Async module-to-module communication:

```swift
protocol ModuleEvent: Sendable {
    var eventType: String { get }
    var sourceModule: String { get }
    var timestamp: Date { get }
    var payload: Data { get }  // JSON-encoded
}

actor ModuleEventBus {
    static let shared = ModuleEventBus()
    
    func publish<E: ModuleEvent>(_ event: E) async
    func subscribe<E: ModuleEvent>(
        _ type: E.Type,
        handler: @escaping @Sendable (E) async -> Void
    ) async
    func unsubscribe<E: ModuleEvent>(_ type: E.Type) async
}

// Example Events
struct WorkspaceChangedEvent: ModuleEvent {
    let eventType = "workspace.changed"
    let sourceModule: String
    let timestamp = Date()
    let workspaceID: UUID
    let changeType: ChangeType  // created, modified, deleted, switched
    var payload: Data { try! JSONEncoder().encode(self) }
}

struct ModelSwitchedEvent: ModuleEvent {
    let eventType = "model.switched"
    let sourceModule: String
    let timestamp = Date()
    let fromModel: String?
    let toModel: String
    var payload: Data { try! JSONEncoder().encode(self) }
}

struct AgentTaskCompletedEvent: ModuleEvent {
    let eventType = "agent.task.completed"
    let sourceModule: String
    let timestamp = Date()
    let taskID: UUID
    let agentID: String
    let result: TaskResult
    var payload: Data { try! JSONEncoder().encode(self) }
}
```

---

## Workspace Integration

Modules share a unified workspace:

```swift
@Model
final class Workspace {
    @Attribute(.unique) var id: UUID
    var name: String
    var rootPath: String
    var securityScopedBookmark: Data?
    var moduleStates: [ModuleState]
    var conversations: [Conversation]
    var agents: [AgentProfile]
    var artifacts: [Artifact]
    var settings: WorkspaceSettings
    var createdAt: Date
    var updatedAt: Date
}

@Model
final class ModuleState {
    var moduleID: String
    var isActive: Bool
    var configuration: Data?  // JSON
    var lastUsed: Date
    var windowState: WindowState?
}

struct WindowState: Codable {
    var frame: CGRect
    var splitViewPositions: [CGFloat]
    var activeTab: String?
    var inspectorVisible: Bool
    var sidebarVisible: Bool
}
```

### Workspace Manager Protocol

```swift
protocol WorkspaceManagerProtocol: Sendable {
    var currentWorkspace: Workspace? { get async }
    var workspaces: [Workspace] { get async }
    
    func createWorkspace(name: String, rootPath: String) async throws -> Workspace
    func openWorkspace(_ workspace: Workspace) async throws
    func closeWorkspace(_ workspace: Workspace) async throws
    func deleteWorkspace(_ workspace: Workspace) async throws
    
    func resolveBookmark(_ bookmark: Data) async throws -> URL
    func createBookmark(for url: URL) async throws -> Data
    
    func watchPath(_ path: String, handler: @escaping @Sendable (FileEvent) async -> Void) async throws
    func unwatchPath(_ path: String) async
}
```

---

## Settings System

### Global Settings

```swift
@Observable
final class SettingsService: Sendable {
    // App-level
    var theme: Theme
    var language: String
    var startupModule: String
    var enableTelemetry: Bool
    
    // Per-module
    var moduleConfigs: [String: ModuleConfig]
    
    // Providers
    var providerConfigs: [String: ProviderConfig]
    
    // MCP
    var mcpServers: [MCPServerConfig]
    
    // Features
    var featureFlags: [String: Bool]
    
    func get<T: Codable>(_ key: String, default: T) -> T
    func set<T: Codable>(_ key: String, value: T)
    func observe<T: Codable>(_ key: String) -> AsyncStream<T>
}
```

### Module Settings Schema

```json
{
  "moduleIdentifier": "com.supermeta.devplatform",
  "version": "1.0.0",
  "settings": [
    {
      "key": "editor.fontSize",
      "type": "number",
      "default": 13,
      "min": 8,
      "max": 24,
      "title": "Font Size",
      "description": "Editor font size in points"
    },
    {
      "key": "editor.tabWidth",
      "type": "number",
      "default": 4,
      "min": 2,
      "max": 8,
      "title": "Tab Width",
      "description": "Spaces per tab"
    },
    {
      "key": "build.parallelJobs",
      "type": "number",
      "default": 0,
      "min": 1,
      "max": 32,
      "title": "Parallel Build Jobs",
      "description": "0 = automatic (CPU cores)"
    },
    {
      "key": "debugger.lldbPath",
      "type": "string",
      "default": "",
      "title": "LLDB Path",
      "description": "Custom LLDB path (empty = Xcode default)"
    }
  ]
}
```

---

## Module Development SDK

### Creating a New Module

```bash
# Generate module template
./Scripts/module-template.sh \
  --identifier com.example.mymodule \
  --name "My Module" \
  --category development \
  --capabilities fileSystem.readWrite,process.spawn,network.client
```

### Template Structure

```
MyModule/
├── Package.swift
├── Sources/
│   ├── MyModule/
│   │   ├── Module.swift          # Module protocol conformance
│   │   ├── ModuleManifest.json   # Manifest
│   │   ├── SettingsSchema.json   # Settings schema
│   │   ├── Services/
│   │   │   └── MyService.swift
│   │   ├── UI/
│   │   │   ├── MyView.swift
│   │   │   └── MyViewModel.swift
│   │   └── Commands/
│   │       └── MyCommands.swift
│   └── MyModuleC/                # Optional C/C++ bridge
│       ├── bridge.h
│       └── bridge.mm
├── Resources/
│   ├── Assets.xcassets
│   └── Localizations/
├── Tests/
│   └── MyModuleTests/
└── Scripts/
    └── build.sh
```

### Module.swift Template

```swift
import Foundation
import SuperMetaCore

public final class MyModule: Module {
    public static let identifier = "com.example.mymodule"
    public static let displayName = "My Module"
    public static let version = "1.0.0"
    public static let dependencies = ["com.supermeta.core"]
    public static let requiredCapabilities: ModuleCapabilities = [
        .fileSystemRead, .fileSystemWrite, .processSpawn
    ]
    
    private var service: MyService?
    
    public func initialize(context: ModuleContext) async throws {
        self.service = MyService(context: context)
        try await service?.initialize()
        
        // Register services
        context.serviceRegistry.register(service!, for: MyServiceProtocol.self)
        
        // Subscribe to events
        await ModuleEventBus.shared.subscribe(WorkspaceChangedEvent.self) { [weak self] event in
            await self?.handleWorkspaceChange(event)
        }
    }
    
    public func activate() async throws {
        // Contribute UI
        context.moduleHost.addTab(
            identifier: "myModule",
            title: "My Module",
            view: MyView(viewModel: MyViewModel(service: service!))
        )
    }
    
    public func deactivate() async throws {
        context.moduleHost.removeTab(identifier: "myModule")
    }
    
    public func shutdown() async throws {
        await service?.shutdown()
    }
    
    public func contributeMenus() -> [MenuContribution] {
        [
            MenuContribution(
                menu: "MyModule",
                items: [
                    MenuItem(title: "Do Something", action: "doSomething", shortcut: "⌘⇧M"),
                    MenuItem(title: "Settings...", action: "showSettings")
                ]
            )
        ]
    }
    
    public func contributeCommands() -> [CommandContribution] {
        [
            CommandContribution(
                identifier: "doSomething",
                title: "Do Something",
                shortcut: "⌘⇧M",
                category: "MyModule",
                handler: { [weak self] in await self?.service?.doSomething() }
            )
        ]
    }
    
    private func handleWorkspaceChange(_ event: WorkspaceChangedEvent) async {
        // React to workspace changes
    }
}
```

---

## Module Marketplace

### Index Format

```json
{
  "version": 1,
  "updated": "2026-10-15T00:00:00Z",
  "modules": [
    {
      "identifier": "com.supermeta.devplatform",
      "displayName": "Development Platform",
      "version": "1.0.0",
      "author": "SuperMetaApp Team",
      "repository": "https://github.com/supermeta/devplatform",
      "releaseURL": "https://github.com/supermeta/devplatform/releases/latest",
      "checksum": "sha256:...",
      "minAppVersion": "1.0.0",
      "categories": ["development", "ide"],
      "description": "Xcode-class IDE...",
      "screenshots": ["url1", "url2"],
      "license": "Proprietary",
      "price": 0
    }
  ]
}
```

### Installation Flow

```
User clicks "Install" in Marketplace
        │
        ▼
Download module bundle (.supermodule)
        │
        ▼
Verify signature (Apple Developer ID + SuperMetaApp Team ID)
        │
        ▼
Verify checksum matches index
        │
        ▼
Extract to ~/Library/Application Support/SuperMetaApp/Modules/
        │
        ▼
ModuleManager discovers new manifest
        │
        ▼
Validate dependencies, capabilities, compatibility
        │
        ▼
Prompt user for capability grants
        │
        ▼
Load and activate module
        │
        ▼
Notify user of successful installation
```

---

## Compatibility Matrix

| App Version | Module API Version | Swift Version | macOS Min |
|-------------|-------------------|---------------|-----------|
| 1.0.x       | 1.0               | 6.0           | 14.0      |
| 1.1.x       | 1.1               | 6.0           | 14.0      |
| 2.0.x       | 2.0               | 6.1           | 15.0      |

### Breaking Change Policy

- Major module API version = breaking changes
- Minor = additive only
- Patch = bug fixes only
- Deprecation cycle: 2 minor versions before removal

---

## Testing Strategy

### Module Testing

```swift
// Unit tests link against module directly
class MyModuleTests: XCTestCase {
    var module: MyModule!
    var mockContext: MockModuleContext!
    
    override func setUp() {
        mockContext = MockModuleContext()
        module = MyModule()
    }
    
    func testInitialize() async throws {
        try await module.initialize(context: mockContext)
        XCTAssertNotNil(mockContext.registeredServices[MyServiceProtocol.self])
    }
}

// Integration tests use real ModuleManager
class ModuleIntegrationTests: XCTestCase {
    func testModuleLoadUnload() async throws {
        let manager = ModuleManager.shared
        try await manager.loadModule("com.example.mymodule")
        XCTAssertTrue(manager.isLoaded("com.example.mymodule"))
        try await manager.unloadModule("com.example.mymodule")
        XCTAssertFalse(manager.isLoaded("com.example.mymodule"))
    }
}
```

### Test Categories

| Category | Scope | Tools |
|----------|-------|-------|
| Unit | Single module, mocked context | XCTest, Swift Testing |
| Integration | Multiple modules, real services | XCTest, TestContainers |
| Contract | Protocol conformance | Swift Testing, Property-based |
| UI | Module UI components | XCUITest, Snapshot Testing |
| Performance | Load time, memory, CPU | Instruments, XCTest Metrics |

---

## Migration Guide

### From Monolithic to Modular

1. **Identify Boundaries** — Group related functionality
2. **Define Protocols** — Extract interfaces for cross-module communication
3. **Create Manifest** — Declare dependencies and capabilities
4. **Extract Code** — Move to module structure
5. **Add Tests** — Unit + integration
6. **Register** — Add to ModuleManager
7. **Validate** — Load in isolation

### Version Migration

```swift
// ModuleManager handles version migration
struct ModuleMigration {
    let fromVersion: String
    let toVersion: String
    let migrate: @Sendable (inout ModuleState) async throws -> Void
}

let migrations: [ModuleMigration] = [
    ModuleMigration(fromVersion: "0.9", toVersion: "1.0") { state in
        // Migrate configuration format
        if let oldConfig = state.configuration {
            let newConfig = try migrateConfig(oldConfig)
            state.configuration = try JSONEncoder().encode(newConfig)
        }
    }
]
```

---

## Troubleshooting

### Common Issues

| Issue | Cause | Resolution |
|-------|-------|------------|
| Module fails to load | Missing dependency | Install dependency module first |
| Capability denied | User policy / sandbox | Grant in Settings → Security |
| Version conflict | Incompatible module API | Update module or app |
| Crash on activate | UI on background thread | Ensure @MainActor for UI code |
| Memory leak | Retained references | Use weak references in closures |

### Debugging

```bash
# Enable module debug logging
defaults write com.supermeta.app ModuleDebugLogging -bool YES

# List loaded modules
supermeta modules list

# Inspect module state
supermeta modules inspect com.example.mymodule

# Force reload module
supermeta modules reload com.example.mymodule
```

---

## Future Extensions

### Planned Module Types

1. **Remote Modules** — Loaded from network (WebAssembly/WASI)
2. **Ephemeral Modules** — Temporary modules for specific tasks
3. **Composite Modules** — Modules that aggregate other modules
4. **System Modules** — Core modules that cannot be unloaded

### Advanced Features

- **Hot Reload** — Reload module code without app restart (SwiftPM + dlopen)
- **Module Profiles** — Predefined module sets for workflows
- **Dependency Injection** — Automatic service wiring
- **Module Sandbox** — WASI-based isolation for untrusted modules

---

## Document Version

- **Version**: 1.0
- **Date**: 2026-10-15
- **Status**: Draft for Review