import Foundation
import Observation
import SwiftData

struct ToolCallAccumulator {
    private var calls: [Int: ToolCall] = [:]

    mutating func append(_ fragments: [ToolCall]) {
        for (position, fragment) in fragments.enumerated() {
            let key = fragment.index
                ?? calls.first(where: { !fragment.id.isEmpty && $0.value.id == fragment.id })?.key
                ?? position
            var call = calls[key] ?? ToolCall(id: fragment.id.isEmpty ? "call_\(UUID().uuidString)" : fragment.id, index: key)
            if !fragment.id.isEmpty { call.id = fragment.id }
            if !fragment.name.isEmpty { call.name += fragment.name }
            call.arguments += fragment.arguments
            calls[key] = call
        }
    }

    var completed: [ToolCall] {
        calls.keys.sorted().compactMap { calls[$0] }
    }
}

@MainActor
@Observable
public final class ChatSession {
    public let registry: ModelRegistry
    public let conversations: ConversationStore
    public let artifacts: ArtifactStore
    public let ptyManager: PTYManager
    public let mcpService: MCPClientService
    public let gitService: GitService
    public let fileIndexService: FileIndexService
    /// Folder the agent's file and shell tools are scoped to. Nil = tools that need a workspace are unavailable.
    public var workspaceRoot: String? {
        didSet { UserDefaults.standard.set(workspaceRoot, forKey: Self.workspaceKey) }
    }
    nonisolated static let workspaceKey = "agent.workspaceRoot"

    public private(set) var conversationID: UUID?
    public private(set) var conversationTitle: String
    public private(set) var messages: [MessageSnapshot]
    public private(set) var isStreaming = false
    public private(set) var streamingText = ""
    public private(set) var streamingReasoning = ""
    public private(set) var streamingToolCalls: [ToolCall] = []
    public private(set) var errorText: String?
    public private(set) var lastUsage: ChatChunk.Usage?
    public private(set) var recentModelIDs: [String] = []

    /// Agent mode: replies come from the orchestrator (tools, approvals, audit) instead of a bare completion.
    public var agentEnabled = false
    /// Text waiting to be put in the message box (a starter prompt, or context handed over from another tool).
    public var draft = ""
    public var agentProfileIndex = 0
    public private(set) var orchestrator: AgentOrchestrator?
    /// Tool calls of the current (or last) agent run, in order.
    public private(set) var agentActivity: [ToolCallRecord] = []
    public private(set) var agentRound = 0
    public private(set) var agentNotice: String?
    private var agentStop: AgentStopFlag?

    public var agentProfiles: [AgentProfile] { AgentProfile.builtIns.filter { !$0.toolPermissions.enabledTools.isEmpty } }
    public var agentProfile: AgentProfile? {
        let all = agentProfiles
        return all.isEmpty ? nil : all[min(max(0, agentProfileIndex), all.count - 1)]
    }

    public func attachOrchestrator(_ orchestrator: AgentOrchestrator) { self.orchestrator = orchestrator }

    /// Points the agent at a folder chosen by the user, keeping access to it across launches. nil = no project.
    public func setWorkspace(_ url: URL?) {
        guard let url else { WorkspaceStore.shared.clearCurrent(); workspaceRoot = nil; return }
        _ = try? WorkspaceStore.shared.remember(url)
        workspaceRoot = url.path
    }

    public func openRecentWorkspace(_ entry: WorkspaceStore.Entry) {
        if let url = WorkspaceStore.shared.open(path: entry.path) { workspaceRoot = url.path }
    }

    public var selectedModelID: String
    public var reasoning: ReasoningConfig = .default

    private var streamTask: Task<Void, Never>?
    private let recentsKey = "chat.recentModels"
    private var recentsDefaults: UserDefaults?

    public init(
        registry: ModelRegistry,
        conversations: ConversationStore,
        artifacts: ArtifactStore,
        ptyManager: PTYManager = PTYManager(),
        mcpService: MCPClientService = MCPClientService(),
        gitService: GitService = GitService(),
        fileIndexService: FileIndexService = FileIndexService(),
        workspaceRoot: String? = nil,
        initialModelID: String = ""
    ) {
        self.registry = registry
        self.conversations = conversations
        self.artifacts = artifacts
        self.ptyManager = ptyManager
        self.mcpService = mcpService
        self.gitService = gitService
        self.fileIndexService = fileIndexService
        // The last project, with its sandbox access restored from its bookmark; the older plain-path default is
        // only a fallback (it works for folders inside Kiln's own container).
        self.workspaceRoot = workspaceRoot ?? WorkspaceStore.shared.current?.path ?? UserDefaults.standard.string(forKey: Self.workspaceKey)
        self.selectedModelID = initialModelID
        self.conversationTitle = "New Conversation"
        self.messages = []
        recentsDefaults = UserDefaults.standard
        recentModelIDs = recentsDefaults?.stringArray(forKey: recentsKey) ?? []
    }

    public func recordRecent(modelID: String) {
        var updated = recentModelIDs.filter { $0 != modelID }
        updated.insert(modelID, at: 0)
        if updated.count > 10 { updated = Array(updated.prefix(10)) }
        recentModelIDs = updated
        recentsDefaults?.set(updated, forKey: recentsKey)
    }

    // MARK: Conversation lifecycle

    public func newConversation() async {
        stopStreaming()
        do {
            let summary = try await conversations.createConversation(title: "New Conversation", modelID: selectedModelID.isEmpty ? nil : selectedModelID)
            conversationID = summary.id
            conversationTitle = summary.title
            messages = []
            errorText = nil
        } catch {
            errorText = "Could not create conversation: \(error)"
        }
    }

    public func loadConversation(_ id: UUID) async {
        stopStreaming()
        do {
            let page = try await conversations.messages(conversationID: id)
            let summaries = try await conversations.conversations()
            conversationID = id
            conversationTitle = summaries.first { $0.id == id }?.title ?? "Conversation"
            messages = page.messages
            if let model = summaries.first(where: { $0.id == id })?.modelID, !model.isEmpty {
                selectedModelID = model
            }
            errorText = page.truncated ? "Showing the last \(page.messages.count) of \(page.total) messages." : nil
        } catch {
            errorText = "Could not load conversation: \(error)"
        }
    }

    public func conversations() async -> [ConversationSummary] {
        (try? await conversations.conversations()) ?? []
    }

    public func fork(at messageID: UUID) async {
        guard let conversationID else { return }
        do {
            let title = "Fork of \(conversationTitle)"
            if let fork = try await conversations.fork(conversationID: conversationID, atMessageID: messageID, newTitle: title) {
                await loadConversation(fork.id)
            }
        } catch {
            errorText = "Fork failed: \(error)"
        }
    }

    public func deleteMessage(_ id: UUID) async {
        guard conversationID != nil else { return }
        do {
            try await conversations.deleteMessage(id)
            messages.removeAll { $0.id == id }
        } catch {
            errorText = "Delete failed: \(error)"
        }
    }

    /// Conversations made before titles were derived from their first message are all called "New Conversation".
    /// Names them once, without moving them in the history. Returns how many were renamed.
    @discardableResult
    public func retitleUntitledConversations() async -> Int {
        var renamed = 0
        for summary in await conversations() where summary.title == ConversationTitle.placeholder && summary.messageCount > 0 {
            guard let page = try? await conversations.messages(conversationID: summary.id),
                  let first = page.messages.first(where: { $0.role == .user }) else { continue }
            let title = ConversationTitle.make(from: first.content)
            guard title != ConversationTitle.placeholder else { continue }
            try? await conversations.renameConversation(summary.id, to: title, touch: false)
            renamed += 1
        }
        return renamed
    }

    public func deleteConversation(_ id: UUID) async {
        try? await conversations.deleteConversation(id)
        if conversationID == id {
            conversationID = nil
            messages = []
            conversationTitle = ConversationTitle.placeholder
        }
    }

    public func renameConversation(to title: String) async {
        guard let conversationID else { return }
        do {
            try await conversations.renameConversation(conversationID, to: title)
            conversationTitle = title
        } catch {
            errorText = "Rename failed: \(error)"
        }
    }

    // MARK: Streaming

    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        guard !selectedModelID.isEmpty else {
            errorText = "No model selected. Pick one in the model picker."
            return
        }
        if conversationID == nil {
            await newConversation()
            guard conversationID != nil else { return }
        }
        guard let conversationID else { return }
        errorText = nil

        do {
            if let user = try await conversations.appendMessage(conversationID: conversationID, role: .user, content: trimmed) {
                messages.append(user)
            }
            if conversationTitle == ConversationTitle.placeholder {
                await renameConversation(to: ConversationTitle.make(from: trimmed))
            }
            try await conversations.setConversationModel(conversationID, modelID: selectedModelID.isEmpty ? nil : selectedModelID)
        } catch {
            errorText = "Could not persist message: \(error)"
            return
        }
        await runCompletion()
    }

    public func regenerate() async {
        guard !isStreaming else { return }
        guard conversationID != nil else { return }
        guard !selectedModelID.isEmpty else {
            errorText = "No model selected. Pick one in the model picker."
            return
        }
        guard messages.contains(where: { $0.role == .user }) else { return }
        if let lastAssistant = messages.last(where: { $0.role == .assistant }) {
            try? await conversations.deleteMessage(lastAssistant.id)
            messages.removeAll { $0.id == lastAssistant.id }
        }
        await runCompletion()
    }

    public func stopStreaming() {
        agentStop?.stop()
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    private func runCompletion() async {
        guard let conversationID else { return }
        guard !selectedModelID.isEmpty else {
            errorText = "No model selected. Pick one in the model picker."
            return
        }
        isStreaming = true
        streamingText = ""
        streamingReasoning = ""
        streamingToolCalls = []
        if agentEnabled, let orchestrator, let profile = agentProfile {
            await runAgent(orchestrator: orchestrator, profile: profile, conversationID: conversationID)
            return
        }

        let history = messages.map { ChatMessage(role: $0.role, content: $0.content) }
        let request = ChatRequest(
            messages: history,
            model: selectedModelID,
            temperature: reasoning.temperature,
            maxTokens: reasoning.maxTokens,
            topP: reasoning.topP,
            tools: []
        )
        let reasoning = reasoning
        let store = conversations

        let task = Task { [weak self] in
            var content = ""
            var reasoningText = ""
            var toolAccumulator = ToolCallAccumulator()
            var usage: ChatChunk.Usage?
            do {
                let stream = try await self?.registry.streamChat(request, reasoning: reasoning)
                guard let stream else { return }
                for try await chunk in stream {
                    try Task.checkCancellation()
                    if let thinking = chunk.reasoning, !thinking.isEmpty {
                        self?.streamingReasoning += thinking
                        reasoningText += thinking
                    }
                    if let delta = chunk.delta?.content, !delta.isEmpty {
                        content += delta
                        self?.streamingText = content
                    }
                    toolAccumulator.append(chunk.toolCalls)
                    self?.streamingToolCalls = toolAccumulator.completed
                    if let chunkUsage = chunk.usage { usage = chunkUsage }
                    if chunk.finishReason != nil { break }
                }
            } catch is CancellationError {
                if content.isEmpty {
                    self?.isStreaming = false
                    return
                }
                usage = usage ?? ChatChunk.Usage(promptTokens: 0, completionTokens: content.count / 4, totalTokens: content.count / 4)
            } catch {
                self?.errorText = String(describing: error)
                self?.isStreaming = false
                return
            }
            let tokenCount = usage.map { $0.promptTokens + $0.completionTokens } ?? content.count / 4
            if let saved = try? await store.appendMessage(
                conversationID: conversationID,
                role: .assistant,
                content: content,
                reasoning: reasoningText.isEmpty ? nil : reasoningText,
                tokenCount: tokenCount,
                toolCalls: toolAccumulator.completed,
                modelID: request.model
            ) {
                self?.messages.append(saved)
                if let usage { self?.lastUsage = usage }
            }
            if content.isEmpty && toolAccumulator.completed.isEmpty {
                self?.errorText = "The model returned an empty response. Try again or pick another model."
            }
            self?.streamingText = ""
            self?.streamingReasoning = ""
            self?.streamingToolCalls = []
            self?.isStreaming = false
        }
        streamTask = task
        await task.value
    }

    // MARK: Agent runs

    /// Maps one orchestrator event onto the live activity list. Pure so it can be tested.
    static func apply(_ event: AgentEvent, to activity: inout [ToolCallRecord]) {
        switch event {
        case .toolCallStarted(let record), .toolCallFinished(let record):
            if let index = activity.firstIndex(where: { $0.id == record.id }) { activity[index] = record }
            else { activity.append(record) }
        case .awaitingApproval(let request):
            // The call is parked on a human; say so instead of leaving it looking merely queued.
            if let index = activity.lastIndex(where: { $0.toolName == request.toolName && !$0.status.isTerminal }) {
                activity[index].status = .awaitingApproval
            }
        case .approvalResolved:
            if let index = activity.lastIndex(where: { $0.status == .awaitingApproval }) {
                activity[index].status = .running
            }
        default: break
        }
    }

    private func runAgent(orchestrator: AgentOrchestrator, profile: AgentProfile, conversationID: UUID) async {
        guard let promptIndex = messages.lastIndex(where: { $0.role == .user }) else { isStreaming = false; return }
        let prompt = messages[promptIndex].content
        let history = messages[..<promptIndex].map { ChatMessage(role: $0.role, content: $0.content) }
        var profile = profile
        profile.modelID = selectedModelID
        let stop = AgentStopFlag()
        agentStop = stop
        agentActivity = []
        agentRound = 0
        agentNotice = nil
        let root = workspaceRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let registry = registry
        let reasoning = reasoning
        let store = conversations
        let model = selectedModelID

        let task = Task { [weak self] in
            var finalText = ""
            var tokens = 0
            let stream = orchestrator.run(
                profile: profile, prompt: prompt, history: Array(history), workspaceRoot: root, stop: stop,
                chat: { request in try await registry.streamChat(request, reasoning: reasoning) }
            )
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .textDelta(let delta): self.streamingText += delta
                    case .textReset: self.streamingText = ""
                    case .reasoningDelta(let thinking): self.streamingReasoning += thinking
                    case .roundStarted(let round): self.agentRound = round; self.streamingText = ""; self.streamingReasoning = ""
                    case .retryScheduled(let attempt, let delay, let reason):
                        self.agentNotice = "Retrying (\(attempt)) in \(Int(delay))s: \(reason)"
                    case .policyDenied(let tool, _, let reason): self.agentNotice = "\(tool) was blocked: \(reason)"
                    case .finished(let summary): finalText = summary.finalText; tokens = summary.totalTokens
                    default: break
                    }
                    Self.apply(event, to: &self.agentActivity)
                }
            } catch {
                self?.errorText = AgentRetry.explain(error)
            }
            if finalText.isEmpty { finalText = self?.streamingText ?? "" }
            if !finalText.isEmpty, let saved = try? await store.appendMessage(
                conversationID: conversationID, role: .assistant, content: finalText,
                reasoning: nil, tokenCount: tokens, toolCalls: [], modelID: model
            ) {
                self?.messages.append(saved)
            }
            self?.streamingText = ""
            self?.streamingReasoning = ""
            self?.isStreaming = false
            self?.agentStop = nil
        }
        streamTask = task
        await task.value
    }
}
