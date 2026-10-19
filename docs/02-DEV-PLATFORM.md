# Kiln — Development Platform Module Specification

## Overview

The **Development Platform Module** provides a complete Xcode 27-class IDE experience integrated into Kiln. It leverages Swift 6, SwiftUI, and native macOS frameworks to deliver a performant, native development environment.

---

## Module Identity

```json
{
  "identifier": "com.kiln.devplatform",
  "displayName": "Development Platform",
  "version": "1.0.0",
  "category": "development",
  "icon": "hammer.fill",
  "requiredCapabilities": [
    "fileSystem.readWrite",
    "process.spawn",
    "network.client",
    "network.server",
    "debugger.attach",
    "simulator.control",
    "codeSigning"
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
    "quickHelp",
    "sourceControl",
    "deviceManager"
  ]
}
```

---

## Architecture

```
DevelopmentPlatformModule/
├── Module.swift
├── SourceEditor/
│   ├── EditorView.swift
│   ├── TextEngine/
│   │   ├── TextBuffer.swift
│   │   ├── SyntaxHighlighter.swift
│   │   ├── LanguageServer.swift
│   │   ├── CompletionEngine.swift
│   │   └── DiagnosticEngine.swift
│   ├── Minimap.swift
│   ├── CodeFolding.swift
│   └── MultiCursor.swift
├── ProjectNavigator/
│   ├── NavigatorView.swift
│   ├── ProjectTree.swift
│   ├── FileSystemWatcher.swift
│   ├── GroupManager.swift
│   └── TargetInspector.swift
├── BuildSystem/
│   ├── BuildEngine.swift
│   ├── SwiftPMIntegration/
│   │   ├── PackageGraph.swift
│   │   ├── DependencyResolver.swift
│   │   └── BuildPlan.swift
│   ├── XcodeBuildIntegration/
│   │   ├── ProjectParser.swift
│   │   ├── SchemeManager.swift
│   │   └── BuildSettingsEditor.swift
│   ├── BazelIntegration/
│   ├── BuildOutputParser.swift
│   ├── IncrementalBuilder.swift
│   └── BuildCache.swift
├── Debugger/
│   ├── LLDBBridge/
│   │   ├── LLDBController.swift
│   │   ├── MIParser.swift
│   │   ├── VariableInspector.swift
│   │   ├── MemoryView.swift
│   │   ├── RegisterView.swift
│   │   └── DisassemblyView.swift
│   ├── BreakpointManager.swift
│   ├── WatchpointManager.swift
│   ├── ThreadManager.swift
│   ├── CallStackView.swift
│   └── ConsoleView.swift
├── InterfaceBuilder/
│   ├── IBCanvas.swift
│   ├── ObjectLibrary.swift
│   ├── InspectorPanel.swift
│   ├── AutoLayoutEngine.swift
│   ├── PreviewProvider.swift
│   ├── StoryboardEditor.swift
│   └── XIBEditor.swift
├── AssetCatalog/
│   ├── AssetCatalogEditor.swift
│   ├── ImageSetEditor.swift
│   ├── ColorSetEditor.swift
│   ├── SymbolSetEditor.swift
│   ├── ARResourceEditor.swift
│   ├── AppIconEditor.swift
│   └── LaunchImageEditor.swift
├── TestRunner/
│   ├── TestNavigator.swift
│   ├── TestPlanEditor.swift
│   ├── TestExecutor.swift
│   ├── CodeCoverageView.swift
│   ├── XCTestIntegration.swift
│   ├── SwiftTestingIntegration.swift
│   └── TestReportGenerator.swift
├── Refactoring/
│   ├── RenameRefactoring.swift
│   ├── ExtractMethodRefactoring.swift
│   ├── MoveRefactoring.swift
│   ├── ProtocolConformanceRefactoring.swift
│   └── RefactoringEngine.swift
├── QuickHelp/
│   ├── DocumentationBrowser.swift
│   ├── SymbolIndexer.swift
│   ├── DocCIntegration.swift
│   └── InlineDocumentation.swift
├── SourceControl/
│   ├── GitIntegration/
│   │   ├── RepositoryView.swift
│   │   ├── CommitView.swift
│   │   ├── BranchManager.swift
│   │   ├── MergeTool.swift
│   │   ├── BlameView.swift
│   │   └── HistoryView.swift
│   ├── DiffView.swift
│   ├── ConflictResolver.swift
│   └── RemoteManager.swift
├── DeviceManager/
│   ├── SimulatorManager.swift
│   ├── DeviceDiscovery.swift
│   ├── ProvisioningProfileManager.swift
│   ├── CertificateManager.swift
│   └── AppInstaller.swift
├── Extensions/
│   ├── ExtensionHost.swift
│   ├── SourceEditorExtension.swift
│   ├── NavigatorExtension.swift
│   ├── DebuggerExtension.swift
│   └── TemplateExtension.swift
└── Templates/
    ├── FileTemplates/
    ├── ProjectTemplates/
    └── CodeSnippets/
```

---

## Source Editor

### Core Text Engine

```swift
final class TextBuffer: Sendable {
    // Gap buffer for efficient editing
    var content: String { get }
    var length: Int { get }
    var lines: [Line] { get }
    
    func insert(_ text: String, at position: Position) async
    func delete(range: Range<Position>) async
    func replace(range: Range<Position>, with text: String) async
    func transact(_ block: @escaping (inout Transaction) -> Void) async
}

struct Line: Sendable {
    let number: Int
    var text: String
    var tokens: [SyntaxToken]
    var foldingRanges: [FoldingRange]
    var diagnostics: [Diagnostic]
}

struct SyntaxToken: Sendable {
    let range: Range<Position>
    let type: TokenType
    let modifiers: Set<TokenModifier>
}

enum TokenType: String, Sendable {
    case keyword, type, function, variable, constant, string, number
    case comment, operator_, punctuation, regex, attribute
}
```

### Language Server Protocol Integration

```swift
protocol LanguageServerClient: Sendable {
    func initialize(rootURI: URL) async throws
    func shutdown() async
    
    // Text synchronization
    func didOpen(_ document: TextDocument) async
    func didChange(_ document: TextDocument, changes: [TextEdit]) async
    func didClose(_ document: TextDocument) async
    func didSave(_ document: TextDocument) async
    
    // Language features
    func completion(at position: Position, trigger: CompletionTrigger) async -> CompletionList
    func hover(at position: Position) async -> Hover?
    func definition(at position: Position) async -> [Location]
    func references(at position: Position) async -> [Location]
    func documentSymbols() async -> [DocumentSymbol]
    func workspaceSymbols(query: String) async -> [SymbolInformation]
    func codeActions(at range: Range<Position>) async -> [CodeAction]
    func formatting(range: Range<Position>?) async -> [TextEdit]
    func diagnostics() async -> [Diagnostic]
}

// Built-in servers
enum BuiltinLanguageServer: String, CaseIterable {
    case swift = "sourcekit-lsp"
    case clang = "clangd"
    case python = "pylsp"
    case javascript = "typescript-language-server"
    case rust = "rust-analyzer"
    case go = "gopls"
}
```

### Completion Engine

```swift
final class CompletionEngine: Sendable {
    func provideCompletions(
        at position: Position,
        in buffer: TextBuffer,
        context: CompletionContext
    ) async -> CompletionList {
        var items: [CompletionItem] = []
        
        // LSP completions
        items.append(contentsOf: await lspCompletion(at: position))
        
        // Local completions (keywords, snippets, recent)
        items.append(contentsOf: localCompletions(at: position))
        
        // AI-powered completions (via ModelRegistry)
        if settings.enableAICompletion {
            items.append(contentsOf: await aiCompletions(at: position))
        }
        
        // Filter and rank
        return CompletionList(items: rankAndFilter(items, context))
    }
    
    private func aiCompletions(at position: Position) async -> [CompletionItem] {
        let provider = await ModelRegistry.shared.resolveBestProvider(for: .completion)
        let request = CompletionRequest(prefix: buffer.prefix(upTo: position))
        let stream = provider.streamCompletion(request)
        
        var items: [CompletionItem] = []
        for try await chunk in stream {
            items.append(contentsOf: parseCompletionChunk(chunk))
        }
        return items
    }
}
```

---

## Project Navigator

### Project Model

```swift
@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var rootPath: String
    var projectType: ProjectType
    var targets: [Target]
    var schemes: [Scheme]
    var buildConfigurations: [BuildConfiguration]
    var packageDependencies: [PackageDependency]
    var fileGroups: [FileGroup]
}

enum ProjectType: String, Codable, Sendable {
    case swiftPackage = "swiftpm"
    case xcodeProject = "xcodeproj"
    case xcodeWorkspace = "xcworkspace"
    case bazel = "bazel"
    case cmake = "cmake"
    case make = "make"
    case custom = "custom"
}
```

### File System Watching

```swift
final class FileSystemWatcher: Sendable {
    private let stream: FSEventStreamRef
    
    func start(watching url: URL, handler: @escaping @Sendable (FileEvent) async -> Void) async
    func stop() async
}

struct FileEvent: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags
    let eventId: FSEventStreamEventId
}
```

---

## Build System

### Unified Build Engine

```swift
final class BuildEngine: Sendable {
    func build(
        project: Project,
        scheme: Scheme,
        configuration: BuildConfiguration,
        destination: BuildDestination,
        options: BuildOptions
    ) async throws -> BuildResult {
        let builder = try builderFor(project.projectType)
        return try await builder.build(
            project: project,
            scheme: scheme,
            configuration: configuration,
            destination: destination,
            options: options
        )
    }
    
    private func builderFor(_ type: ProjectType) throws -> Builder {
        switch type {
        case .swiftPackage: return SwiftPMBuilder()
        case .xcodeProject, .xcodeWorkspace: return XcodeBuilder()
        case .bazel: return BazelBuilder()
        case .cmake: return CMakeBuilder()
        case .make: return MakeBuilder()
        case .custom: return CustomBuilder()
        }
    }
}

protocol Builder: Sendable {
    func build(
        project: Project,
        scheme: Scheme,
        configuration: BuildConfiguration,
        destination: BuildDestination,
        options: BuildOptions
    ) async throws -> BuildResult
    
    func clean(project: Project) async throws
    func test(project: Project, scheme: Scheme, destination: BuildDestination) async throws -> TestResult
    func archive(project: Project, scheme: Scheme) async throws -> ArchiveResult
}
```

### SwiftPM Integration

```swift
final class SwiftPMBuilder: Builder {
    func build(...) async throws -> BuildResult {
        // 1. Resolve package graph
        let graph = try await PackageGraph.resolve(at: project.rootPath)
        
        // 2. Generate build plan
        let plan = try await BuildPlan.generate(
            graph: graph,
            scheme: scheme,
            configuration: configuration,
            destination: destination
        )
        
        // 3. Execute with swift build
        let process = ProcessRunner(
            executable: "swift",
            arguments: ["build"] + plan.arguments,
            workingDirectory: project.rootPath
        )
        
        // 4. Parse output
        return try await process.run { output in
            BuildOutputParser.parseSwiftPM(output)
        }
    }
}
```

### XcodeBuild Integration

```swift
final class XcodeBuilder: Builder {
    func build(...) async throws -> BuildResult {
        let args = [
            "xcodebuild",
            "-project", project.rootPath,
            "-scheme", scheme.name,
            "-configuration", configuration.name,
            "-destination", destination.specifier,
            "-derivedDataPath", buildPath,
            "-parallelizeTargets",
            "-quiet"
        ] + options.extraArgs
        
        let process = ProcessRunner(
            executable: "/usr/bin/xcodebuild",
            arguments: args,
            workingDirectory: project.rootPath
        )
        
        return try await process.run { output in
            BuildOutputParser.parseXcodeBuild(output)
        }
    }
}
```

---

## Debugger (LLDB Integration)

### LLDB Controller

```swift
final class LLDBController: Sendable {
    private var lldbProcess: Process
    private var miParser: MIParser
    
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        stopAtEntry: Bool
    ) async throws {
        lldbProcess = ProcessRunner(
            executable: "lldb",
            arguments: ["-b", "-o", "version", "--interpreter=mi2"],
            workingDirectory: workingDirectory.path
        )
        
        try await lldbProcess.start()
        
        // Initialize MI
        try await sendCommand("-gdb-set mi-async on")
        try await sendCommand("-file-exec-and-symbols \(executable.path)")
        
        if !arguments.isEmpty {
            try await sendCommand("-exec-arguments \(arguments.joined(separator: " "))")
        }
        
        for (key, value) in environment {
            try await sendCommand("-environment-cd \(key)=\(value)")
        }
        
        if stopAtEntry {
            try await sendCommand("-break-insert -t main")
        }
        
        try await sendCommand("-exec-run")
    }
    
    func sendCommand(_ command: String) async throws -> MIResponse {
        try await lldbProcess.write(command + "\n")
        return try await miParser.parseResponse(await lldbProcess.readUntilPrompt())
    }
    
    // Breakpoints
    func setBreakpoint(at location: BreakpointLocation) async throws -> Breakpoint
    func removeBreakpoint(_ breakpoint: Breakpoint) async throws
    func enableBreakpoint(_ breakpoint: Breakpoint) async throws
    func disableBreakpoint(_ breakpoint: Breakpoint) async throws
    
    // Variables
    func evaluateVariable(_ expression: String, frame: Int?) async throws -> Variable
    func getVariables(frame: Int, scope: VariableScope) async throws -> [Variable]
    func watchVariable(_ expression: String) async throws -> Watchpoint
    
    // Memory
    func readMemory(address: UInt64, length: Int) async throws -> Data
    func writeMemory(address: UInt64, data: Data) async throws
    
    // Registers
    func getRegisters() async throws -> [Register]
    
    // Disassembly
    func disassemble(address: UInt64, count: Int) async throws -> [Instruction]
}
```

### Variable Inspector

```swift
struct Variable: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let type: String
    let value: String
    let address: UInt64?
    let children: [Variable]?
    let isEditable: Bool
    let format: VariableFormat
}

enum VariableFormat: String, Codable, Sendable {
    case auto, hex, decimal, binary, float, vector, string, array, dict, struct
}
```

---

## Interface Builder

### Canvas

```swift
final class IBCanvas: Sendable {
    var document: IBDocument
    var selection: Set<IBObject> = []
    var zoom: CGFloat = 1.0
    var pan: CGPoint = .zero
    
    func render() -> IBView
    func hitTest(at point: CGPoint) -> IBObject?
    func dragObjects(_ objects: [IBObject], by translation: CGPoint)
    func resizeObject(_ object: IBObject, to size: CGSize)
    func addConstraint(_ constraint: IBConstraint)
    func removeConstraint(_ constraint: IBConstraint)
}
```

### Auto Layout Engine

```swift
final class AutoLayoutEngine: Sendable {
    func solveConstraints(
        for objects: [IBObject],
        in superview: IBObject
    ) -> LayoutSolution {
        // Cassowary constraint solver
        let solver = CassowarySolver()
        
        for object in objects {
            for constraint in object.constraints {
                solver.addConstraint(constraint.toCassowary())
            }
        }
        
        return try solver.solve()
    }
    
    func suggestConstraints(
        for object: IBObject,
        relativeTo others: [IBObject]
    ) -> [IBConstraint] {
        // Smart constraint suggestions
    }
}
```

---

## Test Runner

### Unified Test Execution

```swift
final class TestExecutor: Sendable {
    func run(
        project: Project,
        scheme: Scheme,
        destination: BuildDestination,
        testPlan: TestPlan?,
        filter: TestFilter?
    ) async throws -> TestRunResult {
        let builder = try BuildEngine.shared.builderFor(project.projectType)
        
        // Build for testing
        let buildResult = try await builder.build(
            project: project,
            scheme: scheme,
            configuration: .debug,
            destination: destination,
            options: BuildOptions(forTesting: true)
        )
        
        // Run tests
        switch project.projectType {
        case .swiftPackage:
            return try await runSwiftPMTests(buildResult, filter: filter)
        case .xcodeProject, .xcodeWorkspace:
            return try await runXCTests(buildResult, filter: filter)
        default:
            throw BuildError.unsupportedProjectType
        }
    }
    
    private func runSwiftPMTests(_ buildResult: BuildResult, filter: TestFilter?) async throws -> TestRunResult {
        let args = ["test"] + (filter?.arguments ?? [])
        let process = ProcessRunner(
            executable: "swift",
            arguments: args,
            workingDirectory: buildResult.buildPath
        )
        
        return try await process.run { output in
            TestOutputParser.parseSwiftPM(output)
        }
    }
    
    private func runXCTests(_ buildResult: BuildResult, filter: TestFilter?) async throws -> TestRunResult {
        let args = [
            "xcodebuild", "test-without-building",
            "-xctestrun", buildResult.testRunPath,
            "-destination", destination.specifier
        ] + (filter?.arguments ?? [])
        
        let process = ProcessRunner(
            executable: "/usr/bin/xcodebuild",
            arguments: args,
            workingDirectory: buildResult.buildPath
        )
        
        return try await process.run { output in
            TestOutputParser.parseXCTest(output)
        }
    }
}
```

### Code Coverage

```swift
struct CodeCoverage: Sendable {
    let target: String
    let files: [FileCoverage]
    let lineCoverage: Double
    let functionCoverage: Double
    let regionCoverage: Double
}

struct FileCoverage: Sendable {
    let path: String
    let lines: [LineCoverage]
    let functions: [FunctionCoverage]
    let regions: [RegionCoverage]
}

struct LineCoverage: Sendable {
    let lineNumber: Int
    let count: Int
    let covered: Bool
}
```

---

## Source Control (Git)

### Repository View

```swift
final class RepositoryView: Sendable {
    let repository: GitRepository
    
    func status() async throws -> GitStatus
    func diff(file: String, staged: Bool) async throws -> Diff
    func log(options: LogOptions) async throws -> [Commit]
    func branches() async throws -> [Branch]
    func remotes() async throws -> [Remote]
    func stashList() async throws -> [StashEntry]
}

struct GitStatus: Sendable {
    let staged: [FileChange]
    let unstaged: [FileChange]
    let untracked: [String]
    let conflicted: [String]
}

struct FileChange: Sendable {
    let path: String
    let status: ChangeStatus  // added, modified, deleted, renamed, copied
    let staged: Bool
}
```

### Commit View

```swift
final class CommitView: Sendable {
    func createCommit(message: String, files: [String], amend: Bool) async throws -> Commit
    func amendCommit(_ commit: Commit, message: String) async throws
    func cherryPick(_ commit: Commit) async throws
    func revert(_ commit: Commit) async throws
    func rebase(onto: Branch, commits: [Commit]) async throws
}
```

### Merge Tool

```swift
final class MergeTool: Sendable {
    func resolveConflicts(
        strategy: MergeStrategy,
        resolver: @escaping @Sendable (Conflict) async -> Resolution
    ) async throws
    
    func threeWayMerge(
        base: String,
        ours: String,
        theirs: String
    ) -> MergeResult
}

enum Resolution: Sendable {
    case ours, theirs, both, custom(String)
}
```

---

## Device Manager

### Simulator Management

```swift
final class SimulatorManager: Sendable {
    func listSimulators() async throws -> [Simulator]
    func createSimulator(
        name: String,
        deviceType: DeviceType,
        runtime: Runtime
    ) async throws -> Simulator
    func boot(_ simulator: Simulator) async throws
    func shutdown(_ simulator: Simulator) async throws
    func erase(_ simulator: Simulator) async throws
    func installApp(_ simulator: Simulator, app: URL) async throws
    func launchApp(_ simulator: Simulator, bundleID: String) async throws
    func takeScreenshot(_ simulator: Simulator) async throws -> NSImage
    func recordVideo(_ simulator: Simulator, duration: TimeInterval) async throws -> URL
}

struct Simulator: Identifiable, Sendable {
    let id: String  // UDID
    let name: String
    let deviceType: DeviceType
    let runtime: Runtime
    let state: SimulatorState
    let dataPath: URL
    let logPath: URL
}
```

### Physical Device Management

```swift
final class DeviceManager: Sendable {
    func connectedDevices() async throws -> [Device]
    func deviceInfo(_ device: Device) async throws -> DeviceInfo
    func installApp(_ device: Device, app: URL) async throws
    func launchApp(_ device: Device, bundleID: String) async throws
    func getLogs(_ device: Device) async throws -> String
    func takeScreenshot(_ device: Device) async throws -> NSImage
}

struct Device: Identifiable, Sendable {
    let id: String
    let name: String
    let model: String
    let systemVersion: String
    let isTrusted: Bool
    let isPaired: Bool
}
```

---

## Extensions System

### Extension Points

```swift
protocol ExtensionPoint: Sendable {
    associatedtype ExtensionType
    var identifier: String { get }
    var extensions: [ExtensionType] { get }
    func register(_ extension: ExtensionType)
    func unregister(_ extension: ExtensionType)
}

extension ExtensionPoint {
    var identifier: String { "\(ExtensionType.self)" }
}

// Concrete extension points
let sourceEditorExtensions = ExtensionPoint<SourceEditorExtension>()
let navigatorExtensions = ExtensionPoint<NavigatorExtension>()
let debuggerExtensions = ExtensionPoint<DebuggerExtension>()
let templateExtensions = ExtensionPoint<TemplateExtension>()
```

### Source Editor Extension

```swift
protocol SourceEditorExtension: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    
    func contributeCommands() -> [CommandContribution]
    func contributeKeyBindings() -> [KeyBinding]
    func contributeContextMenuItems(for context: EditorContext) -> [MenuItem]
    func provideCompletions(at position: Position, in buffer: TextBuffer) async -> [CompletionItem]
    func provideDiagnostics(for buffer: TextBuffer) async -> [Diagnostic]
    func provideCodeActions(at range: Range<Position>) async -> [CodeAction]
    func provideFormatting(for range: Range<Position>?) async -> [TextEdit]
    func onDocumentOpen(_ buffer: TextBuffer)
    func onDocumentSave(_ buffer: TextBuffer)
}
```

---

## Templates System

### Project Templates

```swift
struct ProjectTemplate: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let description: String
    let category: TemplateCategory
    let icon: String
    let options: [TemplateOption]
    let files: [TemplateFile]
    let postActions: [PostAction]
}

enum TemplateCategory: String, Codable, Sendable {
    case app, framework, library, plugin, test, server, cli, other
}

struct TemplateOption: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let type: OptionType
    let defaultValue: String
    let required: Bool
    let validation: String?  // Regex
}

struct TemplateFile: Codable, Sendable {
    let path: String
    let content: String  // With {{variables}}
    let executable: Bool
}
```

### Code Snippets

```swift
struct CodeSnippet: Identifiable, Codable, Sendable {
    let id: String
    let title: String
    let shortcut: String
    let language: String
    let code: String
    let placeholders: [SnippetPlaceholder]
}

struct SnippetPlaceholder: Codable, Sendable {
    let index: Int
    let name: String
    let defaultValue: String
    let type: String?  // Type hint for completion
}
```

---

## Integration with Kiln

### Shared Services Used

| Service | Usage |
|---------|-------|
| ModelRegistry | AI-powered completions, code generation, refactoring suggestions |
| MCPClient | Language servers, custom tools, external APIs |
| WorkspaceManager | Project files, security-scoped bookmarks |
| TerminalService | Build output, test runs, debugging console |
| GitService | Source control operations |
| SettingsService | Editor preferences, build settings |
| KeychainService | Certificates, provisioning profiles, tokens |

### Cross-Module Workflows

```
┌─────────────────┐     ┌─────────────────┐
│  DevPlatform    │────▶│  AgenticConsole │
│  (Write Code)   │     │  (Review/Refactor)│
└─────────────────┘     └─────────────────┘
        │                       │
        ▼                       ▼
┌─────────────────────────────────────────┐
│           Shared Workspace               │
│  • Project Files  • Git History          │
│  • Build Artifacts • Test Results        │
└─────────────────────────────────────────┘
        │
        ▼
┌─────────────────┐     ┌─────────────────┐
│  ModelLab       │────▶│  ReverseEng     │
│  (Train Models) │     │  (Analyze Bin)  │
└─────────────────┘     └─────────────────┘
```

---

## Performance Targets

| Operation | Target |
|-----------|--------|
| Project Open | < 1s (10k files) |
| File Open | < 100ms |
| Syntax Highlight | < 50ms |
| Completion | < 200ms |
| Build (incremental) | < 5s |
| Debug Launch | < 3s |
| Test Run (unit) | < 10s |
| Memory (large project) | < 500 MB |

---

## Accessibility

- Full VoiceOver support
- Keyboard navigation for all UI
- High contrast mode
- Dynamic Type support
- Reduced motion support

---

## Document Version

- **Version**: 1.0
- **Date**: 2026-10-15
- **Status**: Draft for Review