# Kiln — AI Agentic Harness Console Module Specification

## Overview

The **Agentic Console Module** provides a unified, model-agnostic AI agent interface combining the best of Claude Desktop, ChatGPT/Codex Desktop, and AppleHarness/LumenDeck. It supports any model provider (Ollama, Ollama Cloud, OpenRouter, NVIDIA NIM, Apple Foundation/PCC, MLX, custom endpoints) with full reasoning control.

---

## Module Identity

```json
{
  "identifier": "com.kiln.agenticconsole",
  "displayName": "AI Agentic Console",
  "version": "1.0.0",
  "category": "ai",
  "icon": "sparkles.rectangle.stack.fill",
  "requiredCapabilities": [
    "fileSystem.readWrite",
    "process.spawn",
    "network.client",
    "network.server"
  ],
  "provides": [
    "chatInterface",
    "modelPicker",
    "artifacts",
    "terminal",
    "mcpClient",
    "browserAutomation",
    "gitIntegration",
    "fileIndexing",
    "skillsSystem",
    "agentRuntime"
  ]
}
```

---

## Architecture

```
AgenticConsoleModule/
├── Module.swift
├── ChatInterface/
│   ├── ConversationView.swift
│   ├── MessageBubble.swift
│   ├── ComposerView.swift
│   ├── ReasoningView.swift
│   ├── MessageActions.swift
│   └── BranchManager.swift
├── ModelPicker/
│   ├── ModelPickerView.swift
│   ├── ReasoningPanel.swift
│   ├── ProviderSection.swift
│   ├── ModelSearch.swift
│   └── FavoritesManager.swift
├── Artifacts/
│   ├── ArtifactView.swift
│   ├── CodeArtifactView.swift
│   ├── MarkdownArtifactView.swift
│   ├── HTMLArtifactView.swift
│   ├── MermaidArtifactView.swift
│   ├── ReactArtifactView.swift
│   ├── DataArtifactView.swift
│   ├── ArtifactStore.swift
│   └── VersionHistory.swift
├── Terminal/
│   ├── TerminalView.swift
│   ├── PTYManager.swift
│   ├── SessionManager.swift
│   ├── ShellDetector.swift
│   ├── ThemeSync.swift
│   └── CommandHistory.swift
├── MCPClient/
│   ├── MCPClientService.swift
│   ├── ServerRegistry.swift
│   ├── ConnectionManager.swift
│   ├── ToolRegistry.swift
│   ├── ResourceRegistry.swift
│   ├── PromptRegistry.swift
│   └── SamplingHandler.swift
├── BrowserAutomation/
│   ├── WebKitCDPBridge.swift
│   ├── PlaywrightBridge.swift
│   ├── ComputerUseAgent.swift
│   ├── AccessibilityBridge.swift
│   ├── ScreenshotManager.swift
│   └── DOMInspector.swift
├── AgentRuntime/
│   ├── AgentOrchestrator.swift
│   ├── AgentProfile.swift
│   ├── ExecutionPolicy.swift
│   ├── ToolRegistry.swift
│   ├── ApprovalCenter.swift
│   ├── AgentTools/
│   │   ├── FileTool.swift
│   │   ├── ShellTool.swift
│   │   ├── GitTool.swift
│   │   ├── WebTool.swift
│   │   ├── SearchTool.swift
│   │   ├── CodeTool.swift
│   │   └── CustomTool.swift
│   └── ToolBridge.swift
├── Skills/
│   ├── SkillsView.swift
│   ├── SkillManager.swift
│   ├── SkillSandbox.swift
│   ├── MarketplaceClient.swift
│   └── SkillBuilder.swift
├── FileIndexing/
│   ├── FileIndexService.swift
│   ├── SpotlightIndexer.swift
│   ├── SQLiteFTSIndexer.swift
│   ├── SymbolExtractor.swift
│   └── WatcherManager.swift
├── GitIntegration/
│   ├── GitService.swift
│   ├── RepositoryView.swift
│   ├── DiffView.swift
│   ├── CommitView.swift
│   └── BlameView.swift
└── Settings/
    ├── AgenticSettingsView.swift
    ├── ProviderSettings.swift
    ├── ModelSettings.swift
    ├── MCPSettings.swift
    ├── FeatureSettings.swift
    └── AdvancedSettings.swift
```

---

## Model Provider Abstraction

### Unified Provider Protocol

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

enum ProviderType: String, Codable, CaseIterable, Sendable {
    case openCode = "opencode"
    case nvidiaNIM = "nim"
    case openRouter = "openrouter"
    case customEndpoint = "custom"
    case appleFoundation = "apple_foundation"
    case applePCC = "apple_pcc"
    case mlx = "mlx"
    case ollama = "ollama"
    case ollamaCloud = "ollama_cloud"
}

struct ProviderCapabilities: OptionSet, Codable, Sendable {
    let rawValue: UInt32
    static let streaming = ProviderCapabilities(rawValue: 1 << 0)
    static let reasoning = ProviderCapabilities(rawValue: 1 << 1)
    static let tools = ProviderCapabilities(rawValue: 1 << 2)
    static let vision = ProviderCapabilities(rawValue: 1 << 3)
    static let onDevice = ProviderCapabilities(rawValue: 1 << 4)
    static let privateCloud = ProviderCapabilities(rawValue: 1 << 5)
    static let removableStore = ProviderCapabilities(rawValue: 1 << 6)
    static let metalAcceleration = ProviderCapabilities(rawValue: 1 << 7)
}
```

### Provider Implementations

#### OpenCode Provider (Local Ollama/LM Studio)

```swift
final class OpenCodeProvider: ModelProvider {
    let baseURL: URL  // http://localhost:11434 or custom
    
    func fetchModels() async throws -> [ModelDescriptor] {
        let response = try await HTTPClient.get(baseURL.appendingPathComponent("/api/tags"))
        return try JSONDecoder().decode(OllamaModelsResponse.self, from: response).models
            .map { ModelDescriptor(from: $0, provider: .openCode) }
    }
    
    func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        var ollamaRequest = OllamaChatRequest(from: request)
        ollamaRequest.think = reasoning?.enabled ?? false
        ollamaRequest.options = reasoning?.toOllamaOptions()
        
        return try await HTTPClient.streamPOST(
            baseURL.appendingPathComponent("/api/chat"),
            body: ollamaRequest
        ) { chunk in
            ChatChunk(from: chunk)
        }
    }
}
```

#### NVIDIA NIM Provider

```swift
final class NVIDIANIMProvider: ModelProvider {
    let apiKey: String
    let baseURL = URL(string: "https://integrate.api.nvidia.com/v1")!
    
    func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        var nimRequest = NIMChatRequest(from: request)
        nimRequest.reasoningEffort = reasoning?.toNIMEffort()
        
        return try await HTTPClient.streamPOST(
            baseURL.appendingPathComponent("/chat/completions"),
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: nimRequest
        ) { chunk in
            ChatChunk(from: chunk)
        }
    }
}
```

#### OpenRouter Provider

```swift
final class OpenRouterProvider: ModelProvider {
    let apiKey: String
    let baseURL = URL(string: "https://openrouter.ai/api/v1")!
    
    func fetchModels() async throws -> [ModelDescriptor] {
        let response = try await HTTPClient.get(
            baseURL.appendingPathComponent("/models"),
            headers: ["Authorization": "Bearer \(apiKey)"]
        )
        return try JSONDecoder().decode(OpenRouterModelsResponse.self, from: response).data
            .map { ModelDescriptor(from: $0, provider: .openRouter) }
    }
}
```

#### Apple Foundation Models + PCC Provider

```swift
final class AppleFoundationProvider: ModelProvider {
    func checkAvailability() async -> ProviderAvailability {
        let availability = SystemLanguageModel.default.availability
        return ProviderAvailability(
            isAvailable: availability == .available,
            reason: availability.unavailableReason
        )
    }
    
    func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        let session = LanguageModelSession()
        let options = GenerationOptions(
            temperature: request.temperature,
            topP: request.topP,
            maximumResponseTokens: request.maxTokens,
            reasoningEffort: reasoning?.toAppleEffort() ?? .medium
        )
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let stream = session.streamResponse(to: request.prompt, options: options)
                    for try await chunk in stream {
                        continuation.yield(ChatChunk(text: chunk, isComplete: false))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
```

#### MLX Provider

```swift
final class MLXProvider: ModelProvider {
    let modelRegistry: ModelRegistry
    
    func fetchModels() async throws -> [ModelDescriptor] {
        // Combine local MLX models + HF MLX community models
        let local = await modelRegistry.listLocalMLXModels()
        let remote = try await HuggingFaceModelProvider.fetchMLXModels()
        return local + remote
    }
    
    func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        let model = try await modelRegistry.loadMLXModel(request.model)
        return MLXInferenceProvider.shared.generate(request, model: model)
    }
}
```

---

## Reasoning Control System

### Reasoning Configuration

```swift
struct ReasoningConfig: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var budget: ReasoningBudget = .medium
    var depth: ReasoningDepth = .balanced
    var temperature: Double = 0.7
    var topP: Double = 0.95
    var maxTokens: Int = 4096
    var stopSequences: [String] = []
    var customPrompt: String?
}

enum ReasoningBudget: String, CaseIterable, Codable, Sendable {
    case low = "512"
    case medium = "2048"
    case high = "8192"
    case unlimited = "unlimited"
    
    var tokenLimit: Int {
        switch self {
        case .low: return 512
        case .medium: return 2048
        case .high: return 8192
        case .unlimited: return Int.max
        }
    }
}

enum ReasoningDepth: String, CaseIterable, Codable, Sendable {
    case minimal = "1-2 steps"
    case balanced = "3-5 steps"
    case deep = "6-10 steps"
    case exhaustive = "10+ steps"
}
```

### Provider-Specific Mapping

```swift
extension ReasoningConfig {
    func toOllamaOptions() -> OllamaOptions {
        OllamaOptions(
            num_predict: budget == .unlimited ? -1 : budget.tokenLimit,
            temperature: temperature,
            top_p: topP,
            stop: stopSequences.isEmpty ? nil : stopSequences
        )
    }
    
    func toNIMEffort() -> NIMEffort {
        switch depth {
        case .minimal: return .low
        case .balanced: return .medium
        case .deep, .exhaustive: return .high
        }
    }
    
    func toAppleEffort() -> ReasoningEffort {
        switch depth {
        case .minimal: return .low
        case .balanced: return .medium
        case .deep, .exhaustive: return .high
        }
    }
}
```

---

## Chat Interface

### Conversation View

```swift
struct ConversationView: View {
    @Bindable var conversation: Conversation
    @State var messageInput: String = ""
    @State var attachedFiles: [AttachedFile] = []
    @State var showReasoning: Bool = true
    
    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(conversation.messages) { message in
                    MessageBubble(message: message, showReasoning: showReasoning)
                        .id(message.id)
                        .contextMenu { messageContextMenu(message) }
                }
            }
            .onChange(of: conversation.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
        }
        .safeAreaInset(edge: .bottom) {
            ComposerView(
                input: $messageInput,
                attachedFiles: $attachedFiles,
                onSend: { sendMessage() }
            )
        }
    }
}
```

### Message Bubble with Reasoning

```swift
struct MessageBubble: View {
    let message: Message
    let showReasoning: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Role indicator
            HStack {
                Image(systemName: message.role.icon)
                    .foregroundStyle(message.role.color)
                Text(message.role.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            
            // Reasoning (collapsible)
            if showReasoning, let reasoning = message.reasoning, !reasoning.isEmpty {
                DisclosureGroup("Reasoning") {
                    StreamingTextView(text: reasoning)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            
            // Content
            StreamingTextView(text: message.content)
                .textSelection(.enabled)
            
            // Tool calls
            if !message.toolCalls.isEmpty {
                ToolCallView(calls: message.toolCalls)
            }
            
            // Artifacts
            if !message.artifacts.isEmpty {
                ArtifactListView(artifacts: message.artifacts)
            }
            
            // Actions
            MessageActionsView(message: message)
        }
        .padding(.vertical, 4)
    }
}
```

### Composer View

```swift
struct ComposerView: View {
    @Binding var input: String
    @Binding var attachedFiles: [AttachedFile]
    let onSend: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            if !attachedFiles.isEmpty {
                AttachedFilesBar(files: $attachedFiles)
            }
            
            HStack(alignment: .bottom, spacing: 8) {
                // Model picker (compact)
                ModelPickerCompact()
                
                // Text input
                TextEditor(text: $input)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 44, maxHeight: 200)
                    .overlay(alignment: .leading) {
                        if input.isEmpty {
                            Text("Message...")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                        }
                    }
                
                // Send button
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(input.isEmpty ? .tertiary : .accent)
                }
                .disabled(input.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal)
    }
}
```

---

## Artifacts System

### Artifact Types

```swift
enum ArtifactType: String, Codable, CaseIterable, Sendable {
    case code = "code"
    case markdown = "markdown"
    case html = "html"
    case mermaid = "mermaid"
    case react = "react"
    case data = "data"
    case image = "image"
    case pdf = "pdf"
}

struct Artifact: Identifiable, Codable, Sendable {
    let id: UUID
    let type: ArtifactType
    let title: String
    let content: String
    let language: String?
    let version: Int
    let createdAt: Date
    let updatedAt: Date
    let metadata: ArtifactMetadata
}

struct ArtifactMetadata: Codable, Sendable {
    let filePath: String?
    let lineRange: Range<Int>?
    let dependencies: [String]
    let exports: [String]
}
```

### Artifact Views

```swift
// Code Artifact - Syntax highlighted, runnable
struct CodeArtifactView: View {
    let artifact: Artifact
    @State var isEditing: Bool = false
    
    var body: some View {
        VStack(alignment: .leading) {
            ArtifactHeader(artifact: artifact)
            
            if isEditing {
                CodeEditor(text: artifact.content, language: artifact.language)
            } else {
                SyntaxHighlightedView(code: artifact.content, language: artifact.language)
            }
            
            ArtifactActions(artifact: artifact)
        }
    }
}

// HTML Artifact - Sandboxed WebView
struct HTMLArtifactView: View {
    let artifact: Artifact
    
    var body: some View {
        WebView(html: artifact.content, sandboxed: true)
            .frame(minHeight: 400)
    }
}

// Mermaid Artifact - Diagram rendering
struct MermaidArtifactView: View {
    let artifact: Artifact
    
    var body: some View {
        MermaidView(source: artifact.content)
            .frame(minHeight: 400)
    }
}

// Data Artifact - Table/Chart
struct DataArtifactView: View {
    let artifact: Artifact
    
    var body: some View {
        if let data = try? JSONDecoder().decode(DataTable.self, from: artifact.content.data(using: .utf8)!) {
            DataTableView(table: data)
        } else {
            Text("Invalid data format")
        }
    }
}
```

---

## Terminal Integration

### PTY Manager

```swift
final class PTYManager: Sendable {
    private var sessions: [String: PTYSession] = [:]
    
    func createSession(
        id: String,
        shell: String? = nil,
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> PTYSession {
        let session = PTYSession(
            id: id,
            shell: shell ?? detectShell(),
            workingDirectory: workingDirectory,
            environment: environment
        )
        
        try await session.start()
        sessions[id] = session
        return session
    }
    
    func closeSession(_ id: String) async {
        await sessions[id]?.close()
        sessions.removeValue(forKey: id)
    }
}

struct PTYSession: Sendable {
    let id: String
    let shell: String
    let workingDirectory: URL
    var process: Process?
    var masterFD: Int32?
    
    func start() async throws
    func write(_ data: Data) async throws
    func resize(rows: Int, cols: Int) async throws
    func close() async
    
    var output: AsyncStream<Data> { get }
}
```

### Terminal View

```swift
struct TerminalView: View {
    @State var sessions: [TerminalSession] = []
    @State var activeSessionID: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            TabBar(sessions: sessions, activeID: $activeSessionID)
            
            // Terminal content
            if let session = sessions.first(where: { $0.id == activeSessionID }) {
                TerminalEmulatorView(session: session)
            }
        }
    }
}
```

---

## MCP Client

### Server Management

```swift
final class MCPClientService: Sendable {
    private var connections: [String: MCPConnection] = [:]
    
    func discoverServers() async throws -> [MCPServerConfig] {
        // Local: ~/.config/mcp/servers.json
        // Project: .mcp.json
        // Remote: Registry API
    }
    
    func connect(to server: MCPServerConfig) async throws -> MCPConnection {
        let connection = switch server.transport {
        case .stdio:
            StdioMCPConnection(server: server)
        case .http:
            HTTPMCPConnection(server: server)
        case .websocket:
            WebSocketMCPConnection(server: server)
        }
        
        try await connection.connect()
        connections[server.id] = connection
        return connection
    }
    
    func listTools() async -> [MCPTool] {
        // Aggregate tools from all connected servers
    }
    
    func callTool(_ name: String, arguments: [String: Any]) async throws -> MCPToolResult
}
```

### Tool Palette Integration

```swift
struct MCPToolPalette: View {
    @State var availableTools: [MCPTool] = []
    @Binding var selectedTools: Set<String>
    
    var body: some View {
        List(availableTools, selection: $selectedTools) { tool in
            HStack {
                Image(systemName: tool.icon)
                VStack(alignment: .leading) {
                    Text(tool.name).font(.headline)
                    Text(tool.description).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}
```

---

## Browser Automation

### Hybrid Approach

```swift
final class BrowserAutomationService: Sendable {
    // WebKit + CDP for web tasks
    let webkitBridge: WebKitCDPBridge
    
    // Playwright for complex automation
    let playwrightBridge: PlaywrightBridge
    
    // AppleScript + AX for system tasks
    let accessibilityBridge: AccessibilityBridge
    
    func navigate(to url: URL, waitUntil: WaitCondition) async throws
    func click(selector: String) async throws
    func fill(selector: String, value: String) async throws
    func screenshot() async throws -> NSImage
    func evaluateScript(_ script: String) async throws -> Any
    func getDOM() async throws -> DOMTree
}

final class ComputerUseAgent: Sendable {
    // Screenshot + Vision + Accessibility
    func observeScreen() async throws -> ScreenObservation
    func click(at point: CGPoint) async throws
    func type(_ text: String) async throws
    func keyPress(_ key: String) async throws
    func scroll(direction: ScrollDirection) async throws
}
```

---

## Agent Runtime

### Agent Orchestrator

```swift
final class AgentOrchestrator: Sendable {
    func runAgent(
        profile: AgentProfile,
        prompt: String,
        context: AgentContext
    ) async throws -> AgentResult {
        var history = context.history
        history.append(Message(role: .user, content: prompt))
        
        let policy = ExecutionPolicy.forProfile(profile)
        let tools = ToolRegistry.tools(for: profile, policy: policy)
        
        while true {
            let request = ChatRequest(
                messages: history,
                tools: tools,
                model: context.model
            )
            
            let stream = try await ModelRegistry.shared.streamChat(request, reasoning: context.reasoning)
            
            var response = ""
            var toolCalls: [ToolCall] = []
            
            for try await chunk in stream {
                response += chunk.text
                if let call = chunk.toolCall {
                    toolCalls.append(call)
                }
            }
            
            history.append(Message(role: .assistant, content: response, toolCalls: toolCalls))
            
            if toolCalls.isEmpty { break }
            
            // Execute tools
            for call in toolCalls {
                let approval = await ApprovalCenter.requestApproval(for: call, policy: policy)
                guard approval.granted else {
                    history.append(Message(role: .system, content: "Tool call denied: \(approval.reason)"))
                    continue
                }
                
                let result = try await ToolBridge.execute(call)
                history.append(Message(role: .tool, content: result, toolCallID: call.id))
            }
        }
        
        return AgentResult(messages: history, artifacts: extractArtifacts(history))
    }
}
```

### Built-in Tools

```swift
protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONSchema { get }
    var permissionLevel: PermissionLevel { get }
    
    func execute(_ arguments: [String: Any], context: ToolContext) async throws -> ToolResult
}

enum PermissionLevel: String, Codable, Sendable {
    case read    // No side effects
    case write   // Modifies files/state
    case execute // Runs commands
    case admin   // System-level changes
}

struct FileTool: AgentTool {
    let name = "file"
    let operations = ["read", "write", "list", "glob", "grep", "delete"]
    ...
}

struct ShellTool: AgentTool {
    let name = "shell"
    let operations = ["run", "stream", "background"]
    ...
}

struct GitTool: AgentTool {
    let name = "git"
    let operations = ["status", "diff", "commit", "branch", "push", "pull", "log"]
    ...
}

struct WebTool: AgentTool {
    let name = "web"
    let operations = ["search", "fetch", "screenshot"]
    ...
}
```

---

## Skills System

### Skill Definition

```swift
struct Skill: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let description: String
    let version: String
    let author: String
    let repository: URL?
    let entryPoint: String  // Swift script path
    let permissions: [PermissionLevel]
    let dependencies: [String]
    let manifest: SkillManifest
}

struct SkillManifest: Codable, Sendable {
    let commands: [SkillCommand]
    let settings: [SkillSetting]
    let hooks: [SkillHook]
}
```

### Skill Sandbox

```swift
final class SkillSandbox: Sendable {
    func run(_ skill: Skill, command: String, arguments: [String]) async throws -> SkillResult {
        // Swift scripting with restricted capabilities
        let scriptURL = skill.repository.appendingPathComponent(skill.entryPoint)
        
        let process = ProcessRunner(
            executable: "swift",
            arguments: ["run", scriptURL.path, command] + arguments,
            environment: sandboxEnvironment(for: skill)
        )
        
        return try await process.run { output in
            SkillResult(from: output)
        }
    }
    
    private func sandboxEnvironment(for skill: Skill) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["SKILL_HOME"] = skill.repository.path
        env["SKILL_PERMISSIONS"] = skill.permissions.map(\.rawValue).joined(separator: ",")
        return env
    }
}
```

---

## File Indexing & Search

### Hybrid Indexer

```swift
final class FileIndexService: Sendable {
    // Primary: Spotlight (MDQuery)
    let spotlightIndexer = SpotlightIndexer()
    
    // Secondary: Custom SQLite FTS5 for code-aware search
    let sqliteIndexer = SQLiteFTSIndexer()
    
    // Watchers
    let watcherManager = WatcherManager()
    
    func indexWorkspace(_ workspace: Workspace) async throws {
        try await spotlightIndexer.index(workspace.rootPath)
        try await sqliteIndexer.index(workspace.rootPath)
        try await watcherManager.startWatching(workspace.rootPath)
    }
    
    func search(
        query: String,
        options: SearchOptions
    ) async -> [SearchResult] {
        // Combine results from both indexers
        async let spotlightResults = spotlightIndexer.search(query, options)
        async let sqliteResults = sqliteIndexer.search(query, options)
        
        return mergeAndRank(await spotlightResults, await sqliteResults)
    }
}
```

---

## Integration with Kiln

### Cross-Module Workflows

```
+-----------------+     +-----------------+
|  AgenticConsole |---->|  DevPlatform    |
|  (Chat/Code)    |     |  (Edit/Build)   |
+-----------------+     +-----------------+
        |                       |
        v                       v
+---------------------------------------------+
|           Shared Workspace                   |
|  * Conversations  * Artifacts                |
|  * Files          * Git History              |
|  * Terminal       * MCP Servers              |
+---------------------------------------------+
        |
        v
+-----------------+     +-----------------+
|  ModelLab       |---->|  SwarmingEngine |
|  (Models)       |     |  (Multi-Agent)  |
+-----------------+     +-----------------+
```

### Shared Services Used

| Service | Usage |
|---------|-------|
| ModelRegistry | All model interactions |
| MCPClient | External tools, custom servers |
| WorkspaceManager | Project files, security-scoped bookmarks |
| TerminalService | Shell sessions, command execution |
| GitService | Version control in chat |
| FileIndexService | @mention file references, search |
| SettingsService | Provider configs, reasoning defaults |
| KeychainService | API keys, MCP credentials |

---

## Settings

```swift
struct AgenticSettings: Codable, Sendable {
    // General
    var theme: Theme = .system
    var language: String = "en"
    var startupBehavior: StartupBehavior = .newChat
    
    // Models
    var defaultProvider: String = "opencode"
    var defaultModel: String = ""
    var reasoningDefaults: ReasoningConfig = .default
    var modelOverrides: [String: ReasoningConfig] = [:]
    
    // Providers
    var openCodeConfig: OpenCodeConfig = .default
    var nimConfig: NVIDIANIMConfig = .default
    var openRouterConfig: OpenRouterConfig = .default
    var customEndpoints: [CustomEndpointConfig] = []
    var appleFoundationConfig: AppleFoundationConfig = .default
    var mlxConfig: MLXConfig = .default
    
    // MCP
    var mcpServers: [MCPServerConfig] = []
    var autoDiscoverMCPServers: Bool = true
    
    // Features
    var enableArtifacts: Bool = true
    var enableTerminal: Bool = true
    var enableBrowserAutomation: Bool = true
    var enableGitIntegration: Bool = true
    var enableFileIndexing: Bool = true
    var enableSkills: Bool = true
    var enableTelemetry: Bool = false
    
    // Advanced
    var maxConcurrentStreams: Int = 3
    var requestTimeout: TimeInterval = 120
    var logLevel: LogLevel = .info
}
```

---

## Performance Targets

| Metric | Target |
|--------|--------|
| Cold Launch | < 2s |
| Message Send Latency | < 100ms |
| First Token (local) | < 500ms |
| First Token (cloud) | < 2s |
| Artifact Render | < 200ms |
| Terminal Startup | < 300ms |
| Memory (idle) | < 100 MB |
| Memory (active) | < 300 MB |

---

## Document Version

- **Version**: 1.0
- **Date**: 2026-10-15
- **Status**: Draft for Review