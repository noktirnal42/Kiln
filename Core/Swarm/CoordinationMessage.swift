import Foundation

public enum CoordinationMessageType: String, Codable, Sendable, CaseIterable {
    case plan, progress, result, blocker, question, approval
    case capabilityRequest, capabilityGrant
    case sync, heartbeat, shutdown
}

/// One message on the coordination bus. Everything in it is human-readable: a text body and optional
/// structured data, never an opaque blob. The bus is the ONLY channel agents have to each other, so
/// an operator reading the log sees everything they said.
public struct CoordinationMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    /// Position in the bus's total order. Assigned by the bus, never by a sender.
    public let seq: Int
    public let topic: String
    /// Stamped by the sender's endpoint, so one agent cannot publish as another.
    public let from: String
    /// nil = broadcast to the topic's subscribers; otherwise only that agent (and observers).
    public let to: String?
    public let type: CoordinationMessageType
    public let body: String
    public let data: [String: AuditValue]
    public let timestamp: Date
    public let replyTo: UUID?
    /// Secret-shaped values removed from `body` and `data` before anyone saw them.
    public let redactions: Int
}

public struct SharedValue: Codable, Sendable, Equatable {
    public let value: AuditValue
    public let version: Int
    public let updatedBy: String
    public let updatedAt: Date
}

public struct CoordinationLimits: Sendable, Equatable {
    /// Messages kept for reading. Older ones fall off; the count of dropped ones is exposed.
    public var historyLimit = 5_000
    /// Undelivered messages one subscriber may have queued before its oldest are dropped.
    public var mailboxLimit = 256
    public var maxBodyCharacters = 8_192
    public var maxDataCharacters = 8_192
    public var maxMemoryKeys = 1_024
    public var maxMemoryValueCharacters = 16_384

    public init() {}
}

public enum CoordinationError: LocalizedError, Equatable {
    case invalidAgentID(String)
    case reservedAgentID(String)
    case duplicateAgent(String)
    case unknownRecipient(String)
    case invalidTopic(String)
    case bodyTooLarge(Int)
    case dataTooLarge(Int)
    case invalidKey(String)
    case valueTooLarge(Int)
    case tooManyKeys(Int)
    case versionConflict(key: String, expected: Int, current: Int)
    case closed

    public var errorDescription: String? {
        switch self {
        case .invalidAgentID(let id): "Agent id '\(id)' is invalid. Use lowercase letters, digits, '.', '_' or '-' (max 64)."
        case .reservedAgentID(let id): "Agent id '\(id)' is reserved for the orchestrator or the operator."
        case .duplicateAgent(let id): "An agent named '\(id)' is already registered."
        case .unknownRecipient(let id): "There is no registered agent '\(id)'."
        case .invalidTopic(let topic): "Topic '\(topic)' is invalid. Use lowercase letters, digits, '.', '_', '-' or '/' (max 96)."
        case .bodyTooLarge(let limit): "Message body is over the \(limit)-character limit."
        case .dataTooLarge(let limit): "Message data is over the \(limit)-character limit."
        case .invalidKey(let key): "Memory key '\(key)' is invalid."
        case .valueTooLarge(let limit): "Memory value is over the \(limit)-character limit."
        case .tooManyKeys(let limit): "Shared memory is full (\(limit) keys)."
        case .versionConflict(let key, let expected, let current):
            "'\(key)' changed: expected version \(expected), it is at \(current). Read it again and retry."
        case .closed: "The coordination bus is closed."
        }
    }
}
