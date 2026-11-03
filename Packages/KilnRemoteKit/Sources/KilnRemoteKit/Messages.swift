import Foundation

/// Bumped when a message changes shape incompatibly; the Mac refuses a client that announces a different major.
public let kilnRemoteProtocolVersion = 1
/// Bonjour service the Mac advertises while remote control is on.
public let kilnRemoteServiceType = "_kiln-remote._tcp"

public struct ConversationSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var updatedAt: Date
    public init(id: String, title: String, updatedAt: Date) { self.id = id; self.title = title; self.updatedAt = updatedAt }
}

public struct RemoteMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: String
    public var role: Role
    public var text: String
    public var createdAt: Date
    public init(id: String, role: Role, text: String, createdAt: Date) { self.id = id; self.role = role; self.text = text; self.createdAt = createdAt }
}

public struct ApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var tool: String
    /// "read", "write", "execute" or "network": what the call can do.
    public var permission: String
    /// What the call would do, as the Mac shows it in its own approval sheet.
    public var preview: String
    public init(id: String, tool: String, permission: String, preview: String) { self.id = id; self.tool = tool; self.permission = permission; self.preview = preview }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case allowOnce, deny
    // "Always allow" is deliberately not offered remotely: standing grants are made at the Mac.
}

/// Phone or watch → Mac.
public enum RemoteCommand: Codable, Equatable, Sendable {
    case hello(deviceName: String, protocolVersion: Int)
    case listConversations
    case openConversation(id: String)
    case newConversation
    /// Sends a message into the open conversation, as if typed at the Mac (`spoken` marks it as dictated).
    case send(text: String, spoken: Bool)
    case stop
    case decide(approvalID: String, decision: ApprovalDecision)
    case ping
}

/// Mac → phone or watch.
public enum RemoteEvent: Codable, Equatable, Sendable {
    case welcome(hostName: String, protocolVersion: Int)
    case conversations([ConversationSummary])
    /// The open conversation and its saved messages (newest last).
    case opened(conversation: ConversationSummary, messages: [RemoteMessage], isStreaming: Bool)
    /// More of the reply being written.
    case delta(text: String)
    /// A finished message, user or assistant.
    case message(RemoteMessage)
    case activity(tool: String, status: String)
    case approvalRequested(ApprovalRequest)
    case approvalResolved(approvalID: String)
    case streaming(Bool)
    case error(String)
    case pong
}

/// JSON with ISO dates, the same on every platform.
public enum RemoteCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
