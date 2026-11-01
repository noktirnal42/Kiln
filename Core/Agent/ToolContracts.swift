import Foundation

// MARK: - Permission levels

/// How much reach a tool has. Every tool declares one level; the execution
/// policy caps what may even be offered to the model (Gate A), and the
/// approval gate stops anything that got through anyway (Gate B).
public enum ToolPermissionLevel: String, Codable, CaseIterable, Identifiable, Sendable, Comparable {
    /// Observes without changing anything.
    case read
    /// Writes or modifies user files.
    case write
    /// Runs commands or reaches the network.
    case execute
    /// Acts beyond the workspace: another app, the screen, a real browser
    /// session. The highest tier — anything the user can act on.
    case admin

    public var id: String { rawValue }

    public var rank: Int {
        switch self {
        case .read: return 0
        case .write: return 1
        case .execute: return 2
        case .admin: return 3
        }
    }

    public static func < (a: ToolPermissionLevel, b: ToolPermissionLevel) -> Bool { a.rank < b.rank }

    public var displayName: String {
        switch self {
        case .read: return "Read"
        case .write: return "Write"
        case .execute: return "Execute"
        case .admin: return "Admin"
        }
    }

    public var symbolName: String {
        switch self {
        case .read: return "eye"
        case .write: return "square.and.pencil"
        case .execute: return "terminal"
        case .admin: return "cursorarrow.click.2"
        }
    }
}

/// How a tool at a given permission level is gated for one agent.
public enum ApprovalPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Never run; the tool is switched off for this agent.
    case denied
    /// Ask the human every single time.
    case always
    /// Ask once per conversation per tool, then remember the answer.
    case once
    /// Run without asking. Only sensible for read-level tools.
    case automatic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .denied: return "Never"
        case .always: return "Ask every time"
        case .once: return "Ask once per chat"
        case .automatic: return "Allow automatically"
        }
    }
}

/// Per-agent tool policy: which tools are enabled, and how each permission
/// level is gated. Codable as string-keyed payloads (Swift has no stable
/// coding for enum-keyed dictionaries out of the box).
public struct ToolPermissionSet: Codable, Equatable, Sendable {
    public var enabledTools: Set<String>
    public var policyByLevel: [ToolPermissionLevel: ApprovalPolicy]

    public init(
        enabledTools: Set<String> = [],
        policyByLevel: [ToolPermissionLevel: ApprovalPolicy] = ToolPermissionSet.conservativeDefaults
    ) {
        self.enabledTools = enabledTools
        self.policyByLevel = policyByLevel
    }

    public static let conservativeDefaults: [ToolPermissionLevel: ApprovalPolicy] = [
        .read: .automatic,
        .write: .always,
        .execute: .always,
        .admin: .always,
    ]

    public static let readOnlyDefaults: [ToolPermissionLevel: ApprovalPolicy] = [
        .read: .automatic,
        .write: .denied,
        .execute: .denied,
        .admin: .denied,
    ]

    public func policy(for level: ToolPermissionLevel) -> ApprovalPolicy {
        policyByLevel[level] ?? .always
    }

    /// An entry ending in `*` enables every tool with that prefix (`re_*`), so module tools that
    /// are registered at runtime need not be listed one by one.
    public func isEnabled(_ toolName: String) -> Bool {
        if enabledTools.contains(toolName) { return true }
        return enabledTools.contains { $0.hasSuffix("*") && toolName.hasPrefix($0.dropLast()) }
    }

    private enum CodingKeys: String, CodingKey { case enabledTools, policyByLevel }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabledTools = try c.decodeIfPresent(Set<String>.self, forKey: .enabledTools) ?? []
        let raw = try c.decodeIfPresent([String: String].self, forKey: .policyByLevel) ?? [:]
        var mapped: [ToolPermissionLevel: ApprovalPolicy] = [:]
        for (k, v) in raw {
            if let level = ToolPermissionLevel(rawValue: k), let policy = ApprovalPolicy(rawValue: v) {
                mapped[level] = policy
            }
        }
        policyByLevel = mapped.isEmpty ? ToolPermissionSet.conservativeDefaults : mapped
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabledTools, forKey: .enabledTools)
        var raw: [String: String] = [:]
        for (k, v) in policyByLevel { raw[k.rawValue] = v.rawValue }
        try c.encode(raw, forKey: .policyByLevel)
    }
}

// MARK: - Tool specification

/// One typed input parameter of a tool, flattened to the shape the shared
/// provider layer serializes for function-calling.
public struct ToolParam: Codable, Equatable, Sendable {
    public var name: String
    /// A JSON Schema type name: string, integer, number, boolean, array, object.
    public var type: String
    public var description: String
    public var required: Bool

    public init(name: String, type: String = "string", description: String = "", required: Bool = true) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

/// The declaration a provider sees: name, summary, typed parameters, and the
/// permission level the runtime enforces on every call.
public struct ToolSpec: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var summary: String
    public var detail: String
    public var parameters: [ToolParam]
    public var permission: ToolPermissionLevel
    /// Hard to undo (delete, force push, …). Approval sheets say so loudly.
    public var isDestructive: Bool
    /// Needs an open workspace to do anything; never offered without one.
    public var requiresWorkspace: Bool

    public var id: String { name }

    public init(
        name: String,
        summary: String,
        detail: String = "",
        parameters: [ToolParam] = [],
        permission: ToolPermissionLevel,
        isDestructive: Bool = false,
        requiresWorkspace: Bool = false
    ) {
        self.name = name
        self.summary = summary
        self.detail = detail
        self.parameters = parameters
        self.permission = permission
        self.isDestructive = isDestructive
        self.requiresWorkspace = requiresWorkspace
    }

    /// The provider-facing description of this tool.
    public var providerTool: ProviderTool {
        ProviderTool(
            name: name,
            description: detail.isEmpty ? summary : summary + " — " + detail,
            parameters: parameters.reduce(into: [String: ProviderJSON]()) { acc, param in
                var schema: [String: ProviderJSON] = ["type": ProviderJSON(param.type)]
                if !param.description.isEmpty { schema["description"] = ProviderJSON(param.description) }
                acc[param.name] = ProviderJSON(schema)
            },
            required: parameters.filter(\.required).map(\.name)
        )
    }
}

// MARK: - Tool call records

public enum ToolCallStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case awaitingApproval
    case running
    case succeeded
    case failed
    case denied
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .denied, .cancelled: return true
        case .pending, .awaitingApproval, .running: return false
        }
    }
}

public struct ToolCallRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var callID: String
    public var toolName: String
    public var argumentsJSON: String
    public var resultText: String?
    public var errorText: String?
    public var status: ToolCallStatus
    public var permission: ToolPermissionLevel
    public var startedAt: Date
    public var finishedAt: Date?
    /// Secret redactions applied before the result went back to a model.
    public var redactionCount: Int

    public init(
        id: UUID = UUID(),
        callID: String = "",
        toolName: String,
        argumentsJSON: String,
        resultText: String? = nil,
        errorText: String? = nil,
        status: ToolCallStatus = .pending,
        permission: ToolPermissionLevel = .read,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        redactionCount: Int = 0
    ) {
        self.id = id
        self.callID = callID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.resultText = resultText
        self.errorText = errorText
        self.status = status
        self.permission = permission
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.redactionCount = redactionCount
    }

    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }
}

// MARK: - Approval surface

/// A whole-file change a tool proposes, shown at the approval sheet so the
/// human can review exactly what would land.
public struct FileDiff: Equatable, Sendable {
    public var path: String
    public var originalText: String?
    public var proposedText: String
    public var isNewFile: Bool

    public init(path: String, originalText: String?, proposedText: String, isNewFile: Bool = false) {
        self.path = path
        self.originalText = originalText
        self.proposedText = proposedText
        self.isNewFile = isNewFile
    }
}

/// A request surfaced to the human before a gated tool runs.
public struct ApprovalRequest: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var toolName: String
    public var toolSummary: String
    public var argumentsJSON: String
    public var permission: ToolPermissionLevel
    public var isDestructive: Bool
    /// Human-readable preview: the command line, the path, the diff.
    public var preview: String
    /// The consequences spelled out — what this call actually does if approved.
    public var consequences: String
    /// When non-nil, "always allow" would persist a grant scoped to this
    /// value (a hostname, a command string) rather than the whole tool.
    public var grantValue: String?
    public var grantKind: AgentGrant.Kind?
    public var fileDiff: FileDiff?
    public var createdAt: Date
    /// A behavior-monitor hold, not a permission question. Always asked, never satisfied by an
    /// earlier "approve for session" or standing grant, and never creates one.
    public var isMonitorReview: Bool

    public init(
        id: UUID = UUID(),
        toolName: String,
        toolSummary: String,
        argumentsJSON: String,
        permission: ToolPermissionLevel,
        isDestructive: Bool = false,
        preview: String = "",
        consequences: String = "",
        grantValue: String? = nil,
        grantKind: AgentGrant.Kind? = nil,
        fileDiff: FileDiff? = nil,
        createdAt: Date = Date(),
        isMonitorReview: Bool = false
    ) {
        self.id = id
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.argumentsJSON = argumentsJSON
        self.permission = permission
        self.isDestructive = isDestructive
        self.preview = preview
        self.consequences = consequences
        self.grantValue = grantValue
        self.grantKind = grantKind
        self.fileDiff = fileDiff
        self.createdAt = createdAt
        self.isMonitorReview = isMonitorReview
    }
}

public enum ApprovalDecision: Codable, Equatable, Sendable {
    case approveOnce
    case approveForSession
    /// Approve and remember: persists a revocable grant.
    case alwaysAllow
    case deny

    public var auditName: String {
        switch self {
        case .approveOnce: return "approveOnce"
        case .approveForSession: return "approveForSession"
        case .alwaysAllow: return "alwaysAllow"
        case .deny: return "deny"
        }
    }

    public var isApproval: Bool {
        switch self {
        case .approveOnce, .approveForSession, .alwaysAllow: return true
        case .deny: return false
        }
    }
}

// MARK: - Errors

public enum AgentRunError: Error, Equatable, Sendable, CustomStringConvertible {
    case stopped
    case noProvider(String)
    case unknownTool(String)
    case permissionDenied(String)
    case toolTimedOut(String)
    case roundLimitReached(Int)
    case runTimedOut
    case budgetExhausted(String)

    public var description: String {
        switch self {
        case .stopped: return "The run was stopped."
        case .noProvider(let reason): return "No model provider is available: \(reason)"
        case .unknownTool(let name): return "Unknown tool '\(name)'."
        case .permissionDenied(let reason): return "Permission denied: \(reason)"
        case .toolTimedOut(let name): return "Tool '\(name)' exceeded its timeout."
        case .roundLimitReached(let limit): return "Stopped after \(limit) tool rounds without finishing."
        case .runTimedOut: return "The run exceeded its wall-clock timeout."
        case .budgetExhausted(let reason): return "Run budget exhausted: \(reason)"
        }
    }
}
