import AppKit
import Foundation

// MARK: - Persisted grants

/// A standing "always allow" the human granted — scoped: a single tool, a
/// single egress host, or a single command string. Persisted and revocable
/// on their own, never written into the policy itself.
public struct AgentGrant: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case tool
        case egressHost
        case shellCommand
    }

    public var id: UUID
    public var kind: Kind
    public var value: String
    public var profileID: UUID?
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, value: String, profileID: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.value = value
        self.profileID = profileID
        self.createdAt = createdAt
    }
}

/// JSON-backed store of standing grants. Written only by the approval
/// center; read by the orchestrator at policy-check time so an "always
/// allow this host" answer survives relaunches — and so "revoke" is a
/// single call.
public final class GrantStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var grants: [AgentGrant]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([AgentGrant].self, from: data) {
            grants = decoded
        } else {
            grants = []
        }
    }

    public func all() -> [AgentGrant] {
        lock.lock(); defer { lock.unlock() }
        return grants
    }

    public func has(kind: AgentGrant.Kind, value: String, profileID: UUID? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return grants.contains {
            $0.kind == kind && $0.value == value && ($0.profileID == nil || $0.profileID == profileID)
        }
    }

    public func values(kind: AgentGrant.Kind) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(grants.filter { $0.kind == kind }.map(\.value))
    }

    @discardableResult
    public func add(kind: AgentGrant.Kind, value: String, profileID: UUID? = nil) -> AgentGrant {
        lock.lock(); defer { lock.unlock() }
        if let existing = grants.first(where: { $0.kind == kind && $0.value == value && $0.profileID == profileID }) {
            return existing
        }
        let grant = AgentGrant(kind: kind, value: value, profileID: profileID)
        grants.append(grant)
        persistLocked()
        return grant
    }

    public func revoke(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        grants.removeAll { $0.id == id }
        persistLocked()
    }

    public func revoke(kind: AgentGrant.Kind, value: String) {
        lock.lock(); defer { lock.unlock() }
        grants.removeAll { $0.kind == kind && $0.value == value }
        persistLocked()
    }

    public func revokeAll() {
        lock.lock(); defer { lock.unlock() }
        grants.removeAll()
        persistLocked()
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(grants) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Approval log

public struct ApprovalLogEntry: Codable, Identifiable, Sendable {
    public var id: UUID
    public var conversationID: UUID
    public var toolName: String
    public var permission: ToolPermissionLevel
    public var decision: String
    public var preview: String
    public var decidedAt: Date
    /// How the answer arrived: "mouse", "keyboard", "programmatic" (an accessibility or scripted press: no real click or
    /// key event), "remote" (a paired device), or nil for a decision made without asking (standing grant, session approval).
    public var via: String?
    /// How long the question was open before it was answered, in milliseconds.
    public var waitedMs: Int?

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        toolName: String,
        permission: ToolPermissionLevel,
        decision: String,
        preview: String,
        decidedAt: Date = Date(),
        via: String? = nil,
        waitedMs: Int? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.toolName = toolName
        self.permission = permission
        self.decision = decision
        self.preview = preview
        self.decidedAt = decidedAt
        self.via = via
        self.waitedMs = waitedMs
    }
}

/// Append-only JSONL log of every approval decision, for anyone auditing
/// what an agent was allowed to do.
public final class ApprovalLogStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func record(request: ApprovalRequest, decision: ApprovalDecision, conversationID: UUID, via: String? = nil, waitedMs: Int? = nil) {
        let entry = ApprovalLogEntry(
            conversationID: conversationID,
            toolName: request.toolName,
            permission: request.permission,
            decision: decision.auditName,
            preview: request.preview,
            via: via,
            waitedMs: waitedMs
        )
        guard let data = try? JSONEncoder().encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
            try? handle.close()
        } else {
            try? (line + "\n").data(using: .utf8)?.write(to: fileURL, options: .atomic)
        }
    }

    public func readAll() -> [ApprovalLogEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(ApprovalLogEntry.self, from: Data($0.utf8))
        }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Approval modes

/// How the approval gate answers when a tool call needs a human. A mode only answers on the person's behalf; it never
/// creates a standing grant, never answers a behavior-monitor hold, and never lifts a hard policy block (those refuse the
/// call before any approval is asked). It resets to `ask` whenever Kiln starts.
public enum ApprovalMode: String, CaseIterable, Identifiable, Sendable {
    /// Every call that needs approval waits for you.
    case ask
    /// Routine work is approved for you: reads, edits and commands that are not destructive, not outside the project,
    /// and not flagged by the policy. Anything risky still asks.
    case auto
    /// Everything that is not hard-blocked is approved without asking, including destructive and outside-the-project work.
    case bypass

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ask: return "Ask"
        case .auto: return "Auto"
        case .bypass: return "Bypass"
        }
    }

    public var summary: String {
        switch self {
        case .ask: return "Ask before every write, command and network call."
        case .auto: return "Approve routine work automatically; still ask for anything destructive, outside the project, new to the network, or flagged risky."
        case .bypass: return "Approve everything without asking. Hard blocks (like rm -rf /) and behavior-monitor holds still apply. Resets when Kiln quits."
        }
    }

    /// The audit label for decisions this mode made.
    public var auditVia: String { rawValue + "-mode" }

    /// Whether this mode answers `request` itself. Monitor reviews are always asked.
    public func approves(_ request: ApprovalRequest) -> Bool {
        guard !request.isMonitorReview else { return false }
        switch self {
        case .ask: return false
        case .bypass: return true
        case .auto: return !request.isDestructive && request.permission != .admin && request.policyFlag == nil
        }
    }
}

// MARK: - The center (GATE B)

/// The bridge between a tool call awaiting approval (running on a background
/// task) and the human looking at the approval sheet (on the main actor).
///
/// A tool call that needs approval blocks on `requestApproval` until the UI
/// resolves it. There is no timeout: an unanswered approval holds that one
/// tool call — the rest of the app stays responsive.
///
/// This is Gate B. Gate A (the execution policy) already filtered the tool
/// list before the model saw it; this gate stops execution *anyway*, even
/// for a tool call the model hallucinated that was never on the list.
@MainActor
public final class ApprovalCenter: ObservableObject {
    public static let shared = ApprovalCenter()

    @Published public private(set) var pending: [ApprovalRequest] = []
    private var continuations: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]
    private var askedAt: [UUID: Date] = [:]
    private var answeredVia: [UUID: String] = [:]

    /// "Ask once per chat" answers, keyed by conversation so they do not
    /// leak across chats.
    private var sessionApprovals: [UUID: Set<String>] = [:]

    public let grants: GrantStore
    public let log: ApprovalLogStore

    /// The current approval mode. Not saved: Kiln always starts in `ask`.
    @Published public private(set) var mode: ApprovalMode = .ask

    public func setMode(_ newMode: ApprovalMode) {
        guard newMode != mode else { return }
        mode = newMode
        modeLog?("approval mode set to \(newMode.rawValue)")
    }
    /// Receives a line whenever the mode changes (the app writes it to the audit chain).
    public var modeLog: ((String) -> Void)?

    public init(
        grants: GrantStore = GrantStore(fileURL: AgentPaths.makeDefault().appendingPathComponent("agent-grants.json")),
        log: ApprovalLogStore = ApprovalLogStore(
            fileURL: AgentPaths.makeDefault().appendingPathComponent("logs").appendingPathComponent("approvals.jsonl")
        )
    ) {
        self.grants = grants
        self.log = log
    }

    public func isApprovedForSession(conversationID: UUID, toolName: String) -> Bool {
        sessionApprovals[conversationID]?.contains(toolName) ?? false
    }

    public func hasStandingGrant(_ request: ApprovalRequest) -> Bool {
        guard let value = request.grantValue, let kind = request.grantKind else { return false }
        return grants.has(kind: kind, value: value)
    }

    /// Blocks the calling tool call until the human answers.
    public func requestApproval(_ request: ApprovalRequest, conversationID: UUID) async -> ApprovalDecision {
        // Fast paths that do not involve the human at all.
        if let value = request.grantValue, let kind = request.grantKind,
           grants.has(kind: kind, value: value) {
            log.record(request: request, decision: .alwaysAllow, conversationID: conversationID)
            return .alwaysAllow
        }
        if isApprovedForSession(conversationID: conversationID, toolName: request.toolName) {
            log.record(request: request, decision: .approveForSession, conversationID: conversationID)
            return .approveForSession
        }

        if mode.approves(request) {
            // Answered by the mode, once: no grant, no session approval.
            log.record(request: request, decision: .approveOnce, conversationID: conversationID, via: mode.auditVia, waitedMs: 0)
            return .approveOnce
        }

        pending.append(request)
        askedAt[request.id] = Date()
        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalDecision, Never>) in
            continuations[request.id] = continuation
        }
        let via = answeredVia.removeValue(forKey: request.id)
        let waited = askedAt.removeValue(forKey: request.id).map { Int(Date().timeIntervalSince($0) * 1000) }
        switch decision {
        case .approveForSession:
            sessionApprovals[conversationID, default: []].insert(request.toolName)
        case .alwaysAllow:
            if let value = request.grantValue, let kind = request.grantKind {
                grants.add(kind: kind, value: value)
            } else {
                grants.add(kind: .tool, value: request.toolName)
            }
        case .approveOnce, .deny:
            break
        }
        log.record(request: request, decision: decision, conversationID: conversationID, via: via, waitedMs: waited)
        return decision
    }

    /// A one-off human review for a behavior-monitor hold.
    ///
    /// Unlike `requestApproval`, no earlier answer can satisfy it: a standing grant or an
    /// "approve for session" for the same tool does not skip the question, because the monitor is
    /// asking about THIS call. And no answer creates a permission: "approve for session" and
    /// "always allow" both mean "allow this one call", so a review can never broaden what an agent
    /// may do later.
    public func requestReview(_ request: ApprovalRequest, conversationID: UUID) async -> ApprovalDecision {
        pending.append(request)
        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalDecision, Never>) in
            continuations[request.id] = continuation
        }
        let effective: ApprovalDecision = decision.isApproval ? .approveOnce : .deny
        log.record(request: request, decision: effective, conversationID: conversationID)
        return effective
    }

    /// The UI calls this with the human's answer.
    public func resolve(_ requestID: UUID, decision: ApprovalDecision, via: String = ApprovalCenter.currentInputKind()) {
        answeredVia[requestID] = via
        pending.removeAll { $0.id == requestID }
        continuations.removeValue(forKey: requestID)?.resume(returning: decision)
    }

    /// What kind of event is being handled right now: a real click or key, or neither (an accessibility press or a script).
    public static func currentInputKind() -> String {
        switch NSApp.currentEvent?.type {
        case .leftMouseUp, .leftMouseDown, .rightMouseUp, .rightMouseDown: return "mouse"
        case .keyDown, .keyUp: return "keyboard"
        case nil: return "programmatic"
        default: return "other"
        }
    }

    /// Deny everything still outstanding (used when a run is cancelled).
    public func denyAllPending() {
        let ids = Array(continuations.keys)
        for id in ids {
            pending.removeAll { $0.id == id }
            continuations.removeValue(forKey: id)?.resume(returning: .deny)
        }
    }

    public func clearSessionApprovals(conversationID: UUID) {
        sessionApprovals.removeValue(forKey: conversationID)
    }
}
