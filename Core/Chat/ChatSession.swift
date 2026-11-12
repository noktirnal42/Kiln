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

/// A line in the thread that is not a message: "Context compacted (A → B tokens)".
public struct ContextNote: Identifiable, Equatable, Codable, Sendable {
    public var id = UUID()
    /// Shown after this many of the conversation's messages.
    public var afterMessageCount: Int
    public var text: String
}

/// What a conversation remembers of its own compaction: the summary, how many messages it stands in for, and the
/// notes to show. History is rebuilt as [summary] + the messages after `covered`.
struct ConversationCompaction: Codable, Equatable, Sendable {
    var summary: String?
    var covered = 0
    var notes: [ContextNote] = []
}

/// The context meter's reading.
public struct ContextUsage: Equatable, Sendable {
    public var used: Int
    public var window: Int
    public var fraction: Double { window > 0 ? min(1, Double(used) / Double(window)) : 0 }
    public var percent: Int { Int((fraction * 100).rounded()) }
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
    /// Keeps Spotlight in step with conversations when the person has turned that on (Settings). Nil in tests.
    public var spotlight: SpotlightSync?
    public private(set) var conversationTitle: String
    public private(set) var messages: [MessageSnapshot]
    public private(set) var isStreaming = false {
        didSet {
            // A finished run sends the next queued message, unless the person stopped it (then the queue waits for them).
            if oldValue, !isStreaming, let id = conversationID, let spotlight {
                Task { await spotlight.update(id) }
            }
            if oldValue, !isStreaming, !queuePaused, errorText == nil, !queuedMessages.isEmpty {
                Task { [weak self] in await self?.sendNextQueued() }
            }
        }
    }

    // MARK: Composer context (shared by the Agent view and the dock, so both show the same draft state)
    /// Files, folders and images attached to the next message.
    public var attachments: [ComposerAttachment] = []
    /// Shared by the centered thread and the compact dock, retained separately for each open conversation.
    public var composerText = ""
    private struct ComposerDraft {
        var text: String
        var attachments: [ComposerAttachment]
    }
    private var composerDrafts: [UUID: ComposerDraft] = [:]

    private func switchComposer(to id: UUID, preserveCurrent: Bool = false) {
        if let conversationID {
            composerDrafts[conversationID] = ComposerDraft(text: composerText, attachments: attachments)
        }
        guard !preserveCurrent else { return }
        let saved = composerDrafts[id]
        composerText = saved?.text ?? ""
        attachments = saved?.attachments ?? []
    }
    /// Messages typed while a run was going, oldest first.
    public private(set) var queuedMessages: [QueuedMessage] = []
    /// Set when the person pressed Stop: queued messages stay put until they send one or press Send now.
    public private(set) var queuePaused = false

    public func attach(_ urls: [URL]) {
        for url in urls where !attachments.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            attachments.append(ComposerAttachment(url: url))
        }
    }
    public func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }
    public func removeQueued(_ id: UUID) { queuedMessages.removeAll { $0.id == id } }

    /// Sends the oldest queued message now (when idle) and resumes automatic sending.
    public func sendNextQueued() async {
        guard !isStreaming, !queuedMessages.isEmpty else { return }
        queuePaused = false
        let next = queuedMessages.removeFirst()
        attachments = next.attachments
        await send(next.text)
    }
    public private(set) var streamingText = ""
    public private(set) var streamingReasoning = ""
    /// How long the last reply took to start and to finish. First-token time is provider latency; the rest is streaming.
    public struct ResponseTiming: Equatable, Sendable {
        public var firstTokenSeconds: Double?
        public var totalSeconds: Double
    }
    public private(set) var lastTiming: ResponseTiming?
    public private(set) var streamingToolCalls: [ToolCall] = []
    public private(set) var errorText: String?
    /// Set by a file chip in the thread; the window opens the file in the editor and clears nothing (each request has its own id).
    public var fileOpenRequest: FileOpenRequest?
    public private(set) var lastUsage: ChatChunk.Usage?
    public private(set) var recentModelIDs: [String] = []

    /// Agent mode: replies come from the orchestrator (tools, approvals, audit) instead of a bare completion.
    /// On by default and on the full Workstation Agent: Kiln is meant to be a working coding agent out of the box,
    /// and every write, command and network call still waits for approval.
    public var agentEnabled = true
    public private(set) var roundLimitRevision = 0
    public private(set) var pausedAfterRounds: Int?
    private let roundLimits: AgentRoundLimits
    private struct PausedContext {
        var conversationID: UUID
        var profileName: String
        var modelID: String
        var workspacePath: String?
        var messages: [ChatMessage]
    }
    private var pausedContext: PausedContext?
    private var continuingContext: PausedContext?

    public func roundLimit(for profile: AgentProfile) -> Int {
        _ = roundLimitRevision
        return roundLimits.limit(for: profile.name)
    }

    public func setRoundLimit(_ limit: Int, for profile: AgentProfile) {
        guard roundLimits.set(limit, for: profile.name) else { return }
        roundLimitRevision += 1
        Task { await platformAudit.record("agent.round_limit_changed", ["profile": .string(profile.name), "steps": .int(limit), "source": .string("settings")]) }
    }

    public func continuePausedRun() async {
        guard pausedAfterRounds != nil, !isStreaming, let context = pausedContext else { return }
        guard agentEnabled, context.conversationID == conversationID, context.profileName == agentProfile?.name,
              context.modelID == selectedModelID, context.workspacePath == workspaceRoot else {
            errorText = "The model, profile, project or agent mode changed. Continue with a new message after reviewing the previous work."
            return
        }
        continuingContext = context
        defer { continuingContext = nil }
        await send("Continue the previous task from where you stopped. Verify the current state before changing files.", includeAttachments: false)
    }
    /// Text waiting to be put in the message box (a starter prompt, or context handed over from another tool).
    public var draft = ""
    public var agentProfileIndex = AgentProfile.builtIns.filter { !$0.toolPermissions.enabledTools.isEmpty }
        .firstIndex { $0.name == "Workstation Agent" } ?? 0
    public private(set) var orchestrator: AgentOrchestrator?
    /// Tool calls of the current (or last) agent run, in order.
    public private(set) var agentActivity: [ToolCallRecord] = []
    public private(set) var agentRound = 0
    /// When the current agent run began, for the live "Running swift test · 1m 26s" line.
    public private(set) var runStartedAt: Date?
    public private(set) var agentNotice: String?
    private var agentStop: AgentStopFlag?

    // MARK: Context management
    /// Notes ("Context compacted …") for the open conversation, in thread order.
    public private(set) var contextNotes: [ContextNote] = []
    /// Estimated tokens used against the model's window, nil until a window is known.
    public private(set) var contextUsage: ContextUsage?
    public private(set) var isCompacting = false
    /// Whether the open conversation carries a summary of earlier messages.
    public var hasContextSummary: Bool { compactions[conversationID ?? UUID()]?.summary != nil }
    private var compactions: [UUID: ConversationCompaction] = [:]
    private var windowCache: [String: Int] = [:]
    private var compactionDefaults: UserDefaults?
    nonisolated static let compactionKey = "chat.compaction.v1"

    // MARK: Memory files
    /// KILN.md / AGENTS.md / CLAUDE.md for the user and the open project, read when a run starts.
    public private(set) var memory = MemorySnapshot.empty
    /// The user's home for user-scope memory; nil under tests so a developer's own files never leak in.
    let memoryHome: URL?
    var platformAudit: PlatformAudit { PlatformAudit(chain: orchestrator?.auditChain) }

    public func reloadMemory() {
        memory = MemoryLoader.load(workspaceRoot: workspaceRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }, home: memoryHome)
    }

    /// Saves one memory file from the pane, records it in the audit chain, and re-reads memory.
    public func saveMemory(path: String, text: String) async throws {
        let root = workspaceRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let existed = FileManager.default.fileExists(atPath: path)
        try MemoryLoader.save(text, path: path, workspaceRoot: root, home: memoryHome)
        await platformAudit.record("memory.saved", [
            "path": .string(path), "bytes": .int(text.utf8.count), "created": .bool(!existed), "source": .string("pane"),
        ])
        reloadMemory()
        updateContextMeter()
    }

    /// The profile as a run uses it: its own prompt plus the memory files.
    func effectiveProfile(_ profile: AgentProfile) -> AgentProfile {
        var profile = profile
        profile.systemPrompt += memory.promptSection
        return profile
    }

    // MARK: Verifier
    /// The model that re-checks each reply against the tool evidence; empty = off (UserDefaults `agent.verifier.model`).
    nonisolated static let verifierModelKey = "agent.verifier.model"
    public private(set) var verifierReport: VerifierReport?

    func verify(answer: String, evidence: [ToolCallRecord], conversationID: UUID) async {
        let model = UserDefaults.standard.string(forKey: Self.verifierModelKey) ?? ""
        guard !model.isEmpty, !answer.isEmpty else { verifierReport = nil; return }
        let registry = registry
        let items = evidence.map { VerifierEvidence(tool: $0.toolName, arguments: $0.argumentsJSON, status: $0.status.rawValue, excerpt: $0.errorText ?? $0.resultText ?? "") }
        let report = await ClaimVerifier.verify(answer: answer, evidence: items, model: model) { model, system, prompt in
            var text = ""
            let request = ChatRequest(messages: [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: prompt)], model: model, temperature: 0, maxTokens: 800)
            for try await chunk in try await registry.streamChat(request, reasoning: nil) { text += chunk.delta?.content ?? "" }
            return text
        }
        verifierReport = report
        await platformAudit.record("verifier.report", ["model": .string(model), "findings": .int(report.findings.count), "available": .bool(report.unavailable == nil)])
    }

    // MARK: Scheduled tasks
    public func platformAuditRecord(_ type: String, _ payload: [String: AuditValue]) async { await platformAudit.record(type, payload) }
    let scheduleStore: ScheduleStore?
    private var schedulerTask: Task<Void, Never>?

    /// Checks every 30 seconds for due tasks. Call once at launch.
    public func startScheduler() {
        guard schedulerTask == nil, scheduleStore != nil else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.runDueTasks()
            }
        }
    }

    /// Runs each due task as a normal agent run in its own conversation, one at a time. A busy session defers them.
    public func runDueTasks(now: Date = Date()) async {
        guard let scheduleStore, !isStreaming else { return }
        for task in scheduleStore.due(now: now) {
            guard !isStreaming else { return }
            scheduleStore.markRun(task.id, at: now)
            await newConversation()
            await renameConversation(to: "⏱ \(task.name)")
            if let index = agentProfiles.firstIndex(where: { $0.name == task.profileName }) { agentProfileIndex = index }
            agentEnabled = true
            planMode = false
            await platformAudit.record("schedule.run", ["name": .string(task.name), "profile": .string(task.profileName), "schedule": .string(task.describe)])
            await send(task.prompt)
            attention?.scheduledTaskFinished(name: task.name)
        }
    }

    // MARK: Usage and budget
    let usageLedger: UsageLedger?
    private var modelMeta: [String: (provider: String, local: Bool)] = [:]

    private func providerInfo(for modelID: String) -> (provider: String, local: Bool) {
        modelMeta[modelID] ?? (modelID.split(separator: "/").first.map(String.init) ?? "unknown", false)
    }

    private func recordUsage(tokens: Int, model: String, conversationID: UUID) {
        guard let usageLedger, tokens > 0 else { return }
        let info = providerInfo(for: model)
        usageLedger.record(UsageRecord(date: Date(), providerID: info.provider, modelID: model, local: info.local,
                                       inputTokens: tokens, outputTokens: 0, conversationID: conversationID))
    }

    // MARK: Sessions
    /// Per conversation: running, waiting for approval, or idle. Only the open conversation runs here at a time.
    public private(set) var sessionStates: [UUID: SessionState] = [:]
    /// Notifies and badges the Dock when a run needs approval. Set by the app; nil under tests unless a test sets one.
    public var attention: (any AttentionSink)?
    private var pendingApprovals = 0

    func setSessionState(_ state: SessionState, for id: UUID) {
        sessionStates[id] = state == .idle ? nil : state
    }

    public func sessionRows() async -> [SessionRow] {
        SessionList.rows(await conversations(), states: sessionStates, open: conversationID)
    }

    /// Fork a session from its latest message and open the fork.
    public func forkLatest(of id: UUID) async {
        await loadConversation(id)
        if let last = messages.last { await fork(at: last.id) }
    }

    // MARK: Task list (the agent's kiln_todo_write)
    public private(set) var todoItems: [TodoItem] = []

    func syncTodos(_ id: UUID) {
        if id == conversationID { todoItems = TodoBoard.shared.items(for: id) }
    }

    public func clearTodos() { if let conversationID { TodoBoard.shared.clear(conversationID) } }

    // MARK: Diff of a run
    /// Bumped after a file is reverted so open diff cards read the files again.
    public private(set) var diffRevision = 0

    /// What the run started by `messageID` changed, file by file (computed off the main thread).
    public func runDiff(for messageID: UUID) async -> [RunFileDiff] {
        guard let store = checkpointStore, let conversationID, let workspaceRoot,
              let manifest = store.all(conversationID: conversationID).first(where: { $0.messageID == messageID }) else { return [] }
        let root = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        return await Task.detached(priority: .userInitiated) { RunDiff.files(manifest: manifest, store: store, workspaceRoot: root) }.value
    }

    /// Puts one file of that run back as it was. Says what happened in the notice line; a file changed since is left alone.
    public func revertFile(_ path: String, in messageID: UUID) async {
        guard !isStreaming, let store = checkpointStore, let conversationID, let workspaceRoot,
              let manifest = store.all(conversationID: conversationID).first(where: { $0.messageID == messageID }) else { return }
        let result = store.revert(file: path, in: manifest, workspaceRoot: URL(fileURLWithPath: workspaceRoot, isDirectory: true))
        agentNotice = result
        await platformAudit.record("checkpoint.file_reverted", ["path": .string(path), "result": .string(result)])
        diffRevision += 1
    }

    /// Recheck every file at the moment it is restored; the diff may have become stale while the dialog was open.
    public func revertFiles(_ paths: [String], in messageID: UUID) async {
        guard !isStreaming, let store = checkpointStore, let conversationID, let workspaceRoot,
              let manifest = store.all(conversationID: conversationID).first(where: { $0.messageID == messageID }) else { return }
        let root = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        var results: [String] = []
        for path in paths {
            guard !isStreaming else {
                results.append("Stopped undoing changes because a new run started.")
                break
            }
            let result = store.revert(file: path, in: manifest, workspaceRoot: root)
            results.append(result)
            await platformAudit.record("checkpoint.file_reverted", ["path": .string(path), "result": .string(result)])
        }
        agentNotice = results.joined(separator: " ")
        diffRevision += 1
    }

    // MARK: Checkpoints and rewind
    let checkpointStore: CheckpointStore?
    /// User messages whose run changed files or ran commands, so the thread can offer "Rewind to here".
    public private(set) var checkpointedMessageIDs: Set<UUID> = []

    func refreshCheckpoints() {
        guard let checkpointStore, let conversationID else { checkpointedMessageIDs = []; return }
        checkpointedMessageIDs = Set(checkpointStore.all(conversationID: conversationID).filter { !$0.rewound }.map(\.messageID))
    }

    /// Rewinds the conversation to just before `messageID` (which must be a user message): later messages are removed and the
    /// text goes back in the message box. With `restoreFiles`, files the agent changed since then are put back too.
    @discardableResult
    public func rewind(to messageID: UUID, restoreFiles: Bool = true, refillMessageBox: Bool = true) async -> RewindReport? {
        guard !isStreaming, let conversationID, let index = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        var report = RewindReport()
        if restoreFiles, let checkpointStore, let workspaceRoot {
            report = checkpointStore.rewind(conversationID: conversationID, messages: messages.map(\.id), from: messageID,
                                            workspaceRoot: URL(fileURLWithPath: workspaceRoot, isDirectory: true))
        }
        let removed = Array(messages[index...])
        for message in removed { try? await conversations.deleteMessage(message.id) }
        messages.removeSubrange(index...)
        if var state = compactions[conversationID] {
            state.covered = min(state.covered, messages.count)
            if state.covered == 0 { state.summary = nil }
            state.notes.removeAll { $0.afterMessageCount > messages.count }
            compactions[conversationID] = state
            saveCompactions()
            contextNotes = state.notes
        }
        if refillMessageBox, removed.first?.role == .user { draft = removed[0].content }
        agentNotice = restoreFiles ? "Rewound to before this message. " + report.summary : "Rewound the conversation; files were not changed."
        await platformAudit.record("checkpoint.rewound", [
            "messages_removed": .int(removed.count), "files_restored": .int(report.restored.count),
            "files_removed": .int(report.deleted.count), "files_skipped": .int(report.skipped.count),
            "unrestorable_commands": .int(report.unrestorable.count), "restore_files": .bool(restoreFiles),
        ])
        refreshCheckpoints()
        updateContextMeter()
        return report
    }

    // MARK: Plan mode
    /// While on, runs are read-only and end with a plan for the person to approve.
    public var planMode = false
    public private(set) var pendingPlan: PlanProposal?

    public func approvePlan(editedText: String? = nil) async {
        guard let plan = pendingPlan else { return }
        let text = (editedText ?? plan.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pendingPlan = nil
        planMode = false
        await platformAudit.record("plan.approved", ["characters": .int(text.count), "edited": .bool(text != plan.text.trimmingCharacters(in: .whitespacesAndNewlines))])
        await send(PlanMode.approvedPrompt(plan: text))
    }

    public func rejectPlan() async {
        guard pendingPlan != nil else { return }
        pendingPlan = nil
        await platformAudit.record("plan.rejected")
    }

    // MARK: Slash commands
    public enum Pane: Equatable { case memory, commands, hooks, sessions, usage, schedules }
    /// A pane a slash command asked the chat to open.
    public var requestedPane: Pane?

    public func availableCommands() -> [SlashCommand] {
        SlashCommands.all(workspaceRoot: workspaceRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }, home: memoryHome)
    }

    /// Runs a built-in command. Returns nothing to send.
    private func runBuiltIn(_ command: BuiltInCommand, arguments: String) async {
        switch command {
        case .compact: await compactNow()
        case .clear: await newConversation()
        case .plan:
            planMode = PlanMode.parse(arguments) ?? !planMode
            agentNotice = planMode ? "Plan mode on: the agent explores read-only and proposes a plan." : "Plan mode off."
            await platformAudit.record("plan.mode", ["on": .bool(planMode)])
        case .cost: requestedPane = .usage
        case .schedule: requestedPane = .schedules
        case .memory: reloadMemory(); requestedPane = .memory
        case .commands: requestedPane = .commands
        case .hooks: requestedPane = .hooks
        case .sessions: requestedPane = .sessions
        case .help:
            agentNotice = availableCommands().map { "/\($0.name) — \($0.summary)" }.joined(separator: "\n")
        case .model:
            let query = arguments.lowercased()
            guard !query.isEmpty else { agentNotice = "Model: \(selectedModelID.isEmpty ? "none" : selectedModelID). Use /model <part of a name> to switch."; return }
            let models = await registry.allModels()
            if let match = models.first(where: { $0.id.lowercased() == query }) ?? models.first(where: { $0.id.lowercased().contains(query) || $0.name.lowercased().contains(query) }) {
                selectedModelID = match.id
                recordRecent(modelID: match.id)
                await refreshContext()
                agentNotice = "Model: \(match.id)"
            } else {
                errorText = "No model matches “\(arguments)”."
            }
        }
        await platformAudit.record("command.builtin", ["name": .string(command.rawValue)])
    }

    /// Saves a command file from the pane (project or user scope) and records it in the audit chain.
    public func saveCommandFile(path: String, name: String, text: String) async throws {
        let url = URL(fileURLWithPath: path)
        let existed = FileManager.default.fileExists(atPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        await platformAudit.record("command.saved", ["path": .string(path), "name": .string(name), "created": .bool(!existed), "source": .string("pane")])
    }

    /// Writes `.kiln/hooks/hooks.json` for the project after checking it parses, and records it in the audit chain.
    public func saveHooksFile(_ text: String) async throws {
        guard let workspaceRoot else { throw MemoryLoader.SaveError.notAMemoryFile("no project open") }
        struct File: Decodable { var hooks: [HookDefinition] }
        let parsed = try JSONDecoder().decode(File.self, from: Data(text.utf8))
        let url = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(".kiln/hooks/hooks.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        await platformAudit.record("hooks.saved", ["path": .string(url.path), "hooks": .int(parsed.hooks.count)])
    }

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
        reloadMemory()
        updateContextMeter()
    }

    public func openRecentWorkspace(_ entry: WorkspaceStore.Entry) {
        if let url = WorkspaceStore.shared.open(path: entry.path) { workspaceRoot = url.path; reloadMemory(); updateContextMeter() }
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
        initialModelID: String = "",
        compactionDefaults: UserDefaults? = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .standard : nil,
        memoryHome: URL? = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? FileManager.default.homeDirectoryForCurrentUser : nil,
        checkpointStore: CheckpointStore? = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .default : nil,
        usageLedger: UsageLedger? = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .default : nil,
        scheduleStore: ScheduleStore? = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .default : nil,
        roundLimits: AgentRoundLimits = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .shared : AgentRoundLimits(defaults: nil)
    ) {
        self.roundLimits = roundLimits
        self.scheduleStore = scheduleStore
        self.usageLedger = usageLedger
        self.memoryHome = memoryHome
        self.checkpointStore = checkpointStore
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
        self.compactionDefaults = compactionDefaults
        if let data = compactionDefaults?.data(forKey: Self.compactionKey),
           let saved = try? JSONDecoder().decode([UUID: ConversationCompaction].self, from: data) {
            compactions = saved
        }
        // Unit tests switch between stub models; they must not write those into the real app's recent models.
        TodoBoard.shared.observe { [weak self] id in Task { @MainActor in self?.syncTodos(id) } }
        recentsDefaults = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? UserDefaults.standard : nil
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

    public func newConversation(preserveComposer: Bool = false) async {
        stopStreaming()
        pausedAfterRounds = nil
        pausedContext = nil
        queuedMessages = []
        todoItems = []
        do {
            let summary = try await conversations.createConversation(title: "New Conversation", modelID: selectedModelID.isEmpty ? nil : selectedModelID)
            switchComposer(to: summary.id, preserveCurrent: preserveComposer)
            conversationID = summary.id
            conversationTitle = summary.title
            messages = []
            contextNotes = []
            errorText = nil
            await refreshContext()
        } catch {
            errorText = "Could not create conversation: \(error)"
        }
    }

    public func loadConversation(_ id: UUID) async {
        stopStreaming()
        pausedAfterRounds = nil
        pausedContext = nil
        do {
            let page = try await conversations.messages(conversationID: id)
            let summaries = try await conversations.conversations()
            if conversationID != id { switchComposer(to: id) }
            conversationID = id
            todoItems = TodoBoard.shared.items(for: id)
            conversationTitle = summaries.first { $0.id == id }?.title ?? "Conversation"
            messages = page.messages
            if let model = summaries.first(where: { $0.id == id })?.modelID, !model.isEmpty {
                selectedModelID = model
            }
            errorText = page.truncated ? "Showing the last \(page.messages.count) of \(page.total) messages." : nil
            contextNotes = compactions[id]?.notes ?? []
            refreshCheckpoints()
            await refreshContext()
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
            if let index = messages.firstIndex(where: { $0.id == id }) {
                // Deleting a message the summary already covers shifts the covered count with it.
                if var state = compactions[conversationID!], index < state.covered {
                    state.covered -= 1
                    compactions[conversationID!] = state
                }
                messages.remove(at: index)
            }
            updateContextMeter()
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

    /// Bumped whenever a conversation is deleted, so lists of conversations (sidebar, Sessions) know to reload.
    public private(set) var conversationListGeneration = 0

    public func deleteConversation(_ id: UUID) async {
        try? await conversations.deleteConversation(id)
        await spotlight?.remove(id)
        conversationListGeneration += 1
        compactions[id] = nil
        composerDrafts[id] = nil
        saveCompactions()
        if conversationID == id {
            conversationID = nil
            pausedAfterRounds = nil
            pausedContext = nil
            composerText = ""
            attachments = []
            contextNotes = []
            contextUsage = nil
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

    public func send(_ text: String, includeAttachments: Bool = true) async {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isStreaming {
            // Keep typing while the agent works: the message waits its turn instead of being dropped.
            queuedMessages.append(QueuedMessage(text: trimmed, attachments: includeAttachments ? attachments : []))
            if includeAttachments { attachments = [] }
            return
        }
        pausedAfterRounds = nil
        pausedContext = nil
        queuePaused = false
        switch SlashCommands.resolve(trimmed, commands: availableCommands()) {
        case .plainMessage: break
        case .builtIn(let command, let arguments):
            errorText = nil
            await runBuiltIn(command, arguments: arguments)
            return
        case .unknown(let name): errorText = "Unknown command /\(name). Type /help for the list."; return
        case .prompt(let expanded, let name, let model):
            if let model, !model.isEmpty, await registry.allModels().contains(where: { $0.id == model }) { selectedModelID = model }
            await platformAudit.record("command.invoked", ["name": .string(name), "argument_characters": .int(trimmed.count)])
            trimmed = expanded
        }
        guard !selectedModelID.isEmpty else {
            errorText = "No model selected. Pick one in the model picker."
            return
        }
        if conversationID == nil {
            await newConversation(preserveComposer: true)
            guard conversationID != nil else { return }
        }
        guard let conversationID else { return }
        errorText = nil

        let titleSource = trimmed
        let expansion = ContextExpander.expand(prompt: trimmed, attachments: includeAttachments ? attachments : [], workspaceRoot: workspaceRoot.map { URL(fileURLWithPath: $0, isDirectory: true) })
        if includeAttachments { attachments = [] }
        if !expansion.skipped.isEmpty { agentNotice = "Not attached: " + expansion.skipped.joined(separator: "; ") }
        trimmed = expansion.text

        do {
            if let user = try await conversations.appendMessage(conversationID: conversationID, role: .user, content: trimmed) {
                messages.append(user)
            }
            if conversationTitle == ConversationTitle.placeholder {
                await renameConversation(to: ConversationTitle.make(from: titleSource))
            }
            try await conversations.setConversationModel(conversationID, modelID: selectedModelID.isEmpty ? nil : selectedModelID)
        } catch {
            errorText = "Could not persist message: \(error)"
            return
        }
        await runCompletion()
    }

    /// Hides the error banner above the message box.
    public func dismissError() { errorText = nil }
    public func reportError(_ message: String) { errorText = message }

    /// Edit and resubmit: the conversation goes back to before `messageID` (files are left as they are) and `text` is sent in its place.
    public func resubmit(_ messageID: UUID, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !trimmed.isEmpty,
              messages.first(where: { $0.id == messageID })?.role == .user else { return }
        await rewind(to: messageID, restoreFiles: false, refillMessageBox: false)
        await send(trimmed, includeAttachments: false)
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
        queuePaused = true
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

        let startedAt = Date()
        let task = Task { [weak self] in
            var content = ""
            var reasoningText = ""
            var firstTokenAt: Date?
            var toolAccumulator = ToolCallAccumulator()
            var usage: ChatChunk.Usage?
            do {
                let stream = try await self?.registry.streamChat(request, reasoning: reasoning)
                guard let stream else { return }
                for try await chunk in stream {
                    try Task.checkCancellation()
                    if firstTokenAt == nil, !(chunk.reasoning ?? "").isEmpty || !(chunk.delta?.content ?? "").isEmpty { firstTokenAt = Date() }
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
            self?.lastTiming = ResponseTiming(firstTokenSeconds: firstTokenAt.map { $0.timeIntervalSince(startedAt) },
                                              totalSeconds: Date().timeIntervalSince(startedAt))
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

    /// What to tell the person when the model stopped without writing an answer. Pure so it can be tested.
    nonisolated static func noFinalAnswerNotice(activity: [ToolCallRecord]) -> String {
        let steps = activity.count
        guard let last = activity.last else { return "The model finished without writing an answer." }
        let outcome: String
        switch last.status {
        case .succeeded: outcome = "succeeded"
        case .failed: outcome = "failed"
        case .cancelled: outcome = "was cancelled"
        case .denied: outcome = "was denied"
        default: outcome = "did not finish"
        }
        let detail = (last.errorText ?? last.resultText ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let snippet = detail.isEmpty ? "" : " Its output began: \"\(String(detail.prefix(160)))\"."
        return "The model ran \(steps) step\(steps == 1 ? "" : "s") but stopped without writing an answer, so I can't tell you the task is done. The last step (\(last.toolName)) \(outcome).\(snippet) Ask it to continue, or check the activity above."
    }

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
        let continuation = continuingContext
        continuingContext = nil
        let history: [ChatMessage]
        if let continuation, continuation.conversationID == conversationID {
            history = continuation.messages
        } else {
            history = Self.agentHistory(messages: messages, upTo: promptIndex, compaction: compactions[conversationID])
        }
        let window = await contextWindow(for: selectedModelID)
        reloadMemory()
        var profile = effectiveProfile(profile)
        profile.modelID = selectedModelID
        let planning = planMode
        if planning { profile.mode = .plan; profile.systemPrompt += PlanMode.instructions }
        pendingPlan = nil
        verifierReport = nil
        setSessionState(.running, for: conversationID)
        let recorder: CheckpointRecorder? = {
            guard let checkpointStore, let rootPath = workspaceRoot, !planning else { return nil }
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            return CheckpointRecorder(store: checkpointStore, conversationID: conversationID, messageID: messages[promptIndex].id, workspaceRoot: root)
        }()
        let stop = AgentStopFlag()
        agentStop = stop
        agentActivity = []
        agentRound = 0
        runStartedAt = Date()
        agentNotice = nil
        let root = workspaceRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let registry = registry
        let reasoning = reasoning
        let store = conversations
        let model = selectedModelID
        let hooks = HookRunner.load(workspaceRoot: root, home: memoryHome)
        let gate = usageLedger.map { UsageBudgetGate(ledger: $0, modelID: model, local: providerInfo(for: model).local) }
        let roundLimit = roundLimits.limit(for: profile.name)

        let startedAt = Date()
        let task = Task { [weak self] in
            var finalText = ""
            var tokens = 0
            var firstTokenAt: Date?
            let stream = orchestrator.run(
                profile: profile, prompt: prompt, history: history, workspaceRoot: root, contextWindow: window, roundLimit: roundLimit, stop: stop, hooks: hooks, checkpoint: recorder, budgetGate: gate?.isActive == true ? gate : nil,
                chat: { request in try await registry.streamChat(request, reasoning: reasoning) }
            )
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .textDelta(let delta):
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        self.streamingText += delta
                    case .textReset: self.streamingText = ""
                    case .reasoningDelta(let thinking):
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        self.streamingReasoning += thinking
                    case .roundStarted(let round): self.agentRound = round; self.streamingText = ""; self.streamingReasoning = ""
                    case .retryScheduled(let attempt, let delay, let reason):
                        self.agentNotice = "Retrying (\(attempt)) in \(Int(delay))s: \(reason)"
                    case .policyDenied(let tool, _, let reason): self.agentNotice = "\(tool) was blocked: \(reason)"
                    case .contextMeasured(let used, let window): self.contextUsage = ContextUsage(used: used, window: window)
                    case .toolsFitted(let offered, let total):
                        self.agentNotice = "To save context, \(offered) of \(total) tools are loaded now; the agent loads the others when it needs them."
                    case .contextCompacted(let compaction):
                        self.recordCompaction(compaction, conversationID: conversationID, promptIndex: promptIndex)
                    case .pausedContext(let context):
                        guard self.conversationID == conversationID else { break }
                        let restored = context.map { message in
                            var message = message
                            if message.metadata.removeValue(forKey: ContextMetadata.prompt) != nil {
                                message.metadata[ContextMetadata.sourceIndex] = String(promptIndex)
                            }
                            return message
                        }
                        self.pausedContext = PausedContext(conversationID: conversationID, profileName: profile.name, modelID: model, workspacePath: root?.path, messages: restored)
                    case .finished(let summary):
                        finalText = summary.finalText; tokens = summary.totalTokens
                        if self.conversationID == conversationID {
                            self.pausedAfterRounds = summary.pausedAfterRounds
                            if summary.pausedAfterRounds != nil { self.queuePaused = true }
                        }
                    case .awaitingApproval(let request):
                        self.setSessionState(.waitingForApproval, for: conversationID)
                        self.pendingApprovals += 1
                        self.attention?.needsApproval(tool: request.toolName, conversation: self.conversationTitle, pending: self.pendingApprovals)
                    case .approvalResolved:
                        self.setSessionState(.running, for: conversationID)
                        self.pendingApprovals = max(0, self.pendingApprovals - 1)
                        self.attention?.cleared(pending: self.pendingApprovals)
                    default: break
                    }
                    Self.apply(event, to: &self.agentActivity)
                }
            } catch {
                self?.errorText = (error as? AgentRunError)?.description ?? AgentRetry.explain(error)
            }
            self?.lastTiming = ResponseTiming(firstTokenSeconds: firstTokenAt.map { $0.timeIntervalSince(startedAt) },
                                              totalSeconds: Date().timeIntervalSince(startedAt))
            // A Stop (or a failure) mid-call leaves records parked as running; show them as cancelled, not live.
            if let self {
                for index in self.agentActivity.indices where !self.agentActivity[index].status.isTerminal {
                    self.agentActivity[index].status = .cancelled
                }
            }
            if finalText.isEmpty { finalText = self?.streamingText ?? "" }
            // A run that ends without a word would otherwise leave no reply at all: say what happened, without claiming success.
            if finalText.isEmpty, let self, self.errorText == nil, !self.agentActivity.isEmpty {
                finalText = Self.noFinalAnswerNotice(activity: self.agentActivity)
            }
            if !finalText.isEmpty, let saved = try? await store.appendMessage(
                conversationID: conversationID, role: .assistant, content: finalText,
                reasoning: nil, tokenCount: tokens, toolCalls: self?.finishedToolCalls() ?? [], modelID: model
            ) {
                self?.messages.append(saved)
            }
            self?.recordUsage(tokens: tokens, model: model, conversationID: conversationID)
            if !finalText.isEmpty, let self { await self.verify(answer: finalText, evidence: self.agentActivity, conversationID: conversationID) }
            if let recorder, let made = recorder.finish() {
                await self?.platformAudit.record("checkpoint.created", [
                    "files": .int(made.files.count), "unrestorable_commands": .int(made.unrestorable.count), "message_id": .string(made.messageID.uuidString),
                ])
                self?.refreshCheckpoints()
            }
            if planning, let self, self.errorText == nil, !finalText.isEmpty, !stop.stopped {
                self.pendingPlan = PlanProposal(text: finalText, request: prompt)
                await self.platformAudit.record("plan.proposed", ["characters": .int(finalText.count)])
            }
            self?.setSessionState(.idle, for: conversationID)
            if let self, self.pendingApprovals > 0 { self.pendingApprovals = 0; self.attention?.cleared(pending: 0) }
            self?.updateContextMeter()
            self?.streamingText = ""
            self?.streamingReasoning = ""
            self?.isStreaming = false
            self?.agentStop = nil
        }
        streamTask = task
        await task.value
    }

    // MARK: Context management

    nonisolated static func isCompactCommand(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered == "/compact" || lowered.hasPrefix("/compact ")
    }

    /// Prior turns as the model should see them: the summary (if any) followed by the messages it doesn't cover.
    /// Each carries its position so a later compaction can say which messages it replaced.
    nonisolated static func agentHistory(messages: [MessageSnapshot], upTo end: Int, compaction: ConversationCompaction?) -> [ChatMessage] {
        let end = min(max(0, end), messages.count)
        var result: [ChatMessage] = []
        var start = 0
        if let compaction, let summary = compaction.summary {
            start = min(max(0, compaction.covered), end)
            result.append(ContextCompactor.restoredSummary(summary, covers: start))
        }
        for index in start..<end {
            let message = messages[index]
            result.append(ChatMessage(role: message.role, content: message.content,
                                      metadata: [ContextMetadata.sourceIndex: String(index)]))
        }
        return result
    }

    /// How many conversation messages a compaction's summary now stands in for.
    nonisolated static func coveredCount(replaced: [ChatMessage], promptIndex: Int, previous: Int) -> Int {
        var covered = previous
        for message in replaced {
            if let raw = message.metadata[ContextMetadata.sourceIndex], let index = Int(raw) { covered = max(covered, index + 1) }
            if let raw = message.metadata[ContextMetadata.covers], let count = Int(raw) { covered = max(covered, count) }
            if message.metadata[ContextMetadata.prompt] != nil { covered = max(covered, promptIndex + 1) }
        }
        return covered
    }

    private func saveCompactions() {
        guard let compactionDefaults else { return }
        if let data = try? JSONEncoder().encode(compactions) { compactionDefaults.set(data, forKey: Self.compactionKey) }
    }

    private func recordCompaction(_ compaction: ContextCompaction, conversationID: UUID, promptIndex: Int) {
        var state = compactions[conversationID] ?? ConversationCompaction()
        if let summary = compaction.summary {
            state.summary = summary
            state.covered = Self.coveredCount(replaced: compaction.replacedMessages, promptIndex: promptIndex, previous: state.covered)
        }
        let note = ContextNote(afterMessageCount: messages.count, text: compaction.headline)
        state.notes.append(note)
        compactions[conversationID] = state
        saveCompactions()
        if self.conversationID == conversationID {
            contextNotes = state.notes
            contextUsage = contextUsage.map { ContextUsage(used: compaction.tokensAfter, window: $0.window) }
        }
    }

    /// The window of the selected model, cached; nil when no provider reports it.
    func contextWindow(for modelID: String) async -> Int? {
        guard !modelID.isEmpty else { return nil }
        // For testing compaction without a long run: `-agent.contextWindowOverride 4000` on the command line.
        let override = UserDefaults.standard.integer(forKey: "agent.contextWindowOverride")
        if override > 0 { windowCache[modelID] = override; return override }
        if let cached = windowCache[modelID] { return cached }
        let models = await registry.allModels()
        for model in models {
            windowCache[model.id] = model.contextWindow
            modelMeta[model.id] = (model.providerID, model.isOnDevice || [.ollama, .mlx, .appleFoundation, .applePCC].contains(model.providerType))
        }
        return windowCache[modelID]
    }

    /// Looks up the model's window and refreshes the meter. Call when the model or conversation changes.
    public func refreshContext() async {
        reloadMemory()
        _ = await contextWindow(for: selectedModelID)
        updateContextMeter()
    }

    /// Re-estimates what the next request will carry. Cheap: no model call.
    public func updateContextMeter() {
        guard let window = windowCache[selectedModelID], let profile = agentProfile else { contextUsage = nil; return }
        let root = workspaceRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        var tokens = ContextCompactor.estimateTokens(effectiveProfile(profile).systemPrompt)
        tokens += ContextCompactor.estimateTokens(Self.agentHistory(messages: messages, upTo: messages.count,
                                                                    compaction: conversationID.flatMap { compactions[$0] }))
        if let orchestrator {
            tokens += orchestrator.contextBudget(profile: profile, contextWindow: window, workspaceRoot: root).toolSchemaTokens
        }
        contextUsage = ContextUsage(used: tokens, window: window)
    }

    /// `/compact`: summarise the conversation now instead of waiting for the window to fill.
    public func compactNow() async {
        guard !isStreaming, !isCompacting, let conversationID else {
            if conversationID == nil { agentNotice = "Nothing to compact yet." }
            return
        }
        guard let orchestrator, let profile = agentProfile, !selectedModelID.isEmpty,
              let window = await contextWindow(for: selectedModelID) else {
            errorText = "Compaction needs the agent and a model with a known context window."
            return
        }
        isCompacting = true
        defer { isCompacting = false }
        errorText = nil
        var profile2 = effectiveProfile(profile)
        profile2.modelID = selectedModelID
        let history = Self.agentHistory(messages: messages, upTo: messages.count, compaction: compactions[conversationID])
        let registry = registry, reasoning = reasoning
        let root = workspaceRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let outcome = await orchestrator.compact(
            profile: profile2, history: history, contextWindow: window, workspaceRoot: root,
            chat: { request in try await registry.streamChat(request, reasoning: reasoning) }
        )
        guard outcome.didCompact, outcome.summary != nil else {
            agentNotice = "Nothing to compact yet: the conversation is already short."
            updateContextMeter()
            return
        }
        agentNotice = nil
        recordCompaction(ContextCompaction(outcome), conversationID: conversationID, promptIndex: messages.count)
        updateContextMeter()
    }

    /// The finished run's tool calls as stored with its reply, so the thread can show them collapsed later.
    private func finishedToolCalls() -> [ToolCall] {
        agentActivity.map { ToolCall(id: $0.callID.isEmpty ? $0.id.uuidString : $0.callID, name: $0.toolName, arguments: $0.argumentsJSON) }
    }

}
