import Foundation
import SwiftData

@Model
public final class Workspace {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var rootPath: String
    public var securityScopedBookmark: Data?
    public var createdAt: Date
    public var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \ModuleState.workspace)
    public var moduleStates: [ModuleState] = []
    @Relationship(deleteRule: .cascade, inverse: \Conversation.workspace)
    public var conversations: [Conversation] = []
    @Relationship(deleteRule: .cascade, inverse: \Artifact.workspace)
    public var artifacts: [Artifact] = []

    public init(id: UUID = UUID(), name: String, rootPath: String = "", securityScopedBookmark: Data? = nil) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.securityScopedBookmark = securityScopedBookmark
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
public final class ModuleState {
    @Attribute(.unique) public var id: UUID
    public var moduleID: String
    public var isActive: Bool
    public var configuration: Data?
    public var lastUsed: Date
    public var workspace: Workspace?

    public init(moduleID: String, isActive: Bool = false, configuration: Data? = nil) {
        self.id = UUID()
        self.moduleID = moduleID
        self.isActive = isActive
        self.configuration = configuration
        self.lastUsed = Date()
    }
}

@Model
public final class Conversation {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var workspace: Workspace?
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    public var messages: [Message] = []

    public init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
public final class Message {
    @Attribute(.unique) public var id: UUID
    public var role: String
    public var content: String
    public var reasoning: String?
    public var tokenCount: Int
    public var createdAt: Date
    public var conversation: Conversation?

    public init(role: String, content: String, reasoning: String? = nil, tokenCount: Int = 0) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.tokenCount = tokenCount
        self.createdAt = Date()
    }
}

@Model
public final class Artifact {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var kind: String
    public var content: Data
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var workspace: Workspace?

    public init(title: String, kind: String, content: Data, version: Int = 1) {
        self.id = UUID()
        self.title = title
        self.kind = kind
        self.content = content
        self.version = version
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
public final class SettingsEntry {
    @Attribute(.unique) public var key: String
    public var value: Data
    public var updatedAt: Date

    public init(key: String, value: Data) {
        self.key = key
        self.value = value
        self.updatedAt = Date()
    }
}
