import Foundation
import SwiftData

public struct ConversationSummary: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var modelID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int

    public init(id: UUID, title: String, modelID: String?, createdAt: Date, updatedAt: Date, messageCount: Int) {
        self.id = id
        self.title = title
        self.modelID = modelID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }
}

public struct MessageSnapshot: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var role: ChatMessage.Role
    public var content: String
    public var reasoning: String?
    public var tokenCount: Int
    public var order: Int
    public var toolCalls: [ToolCall]
    public var images: [ChatImage]
    public var modelID: String?
    public var createdAt: Date

    public init(
        id: UUID,
        role: ChatMessage.Role,
        content: String,
        reasoning: String? = nil,
        tokenCount: Int = 0,
        order: Int = 0,
        toolCalls: [ToolCall] = [],
        images: [ChatImage] = [],
        modelID: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.tokenCount = tokenCount
        self.order = order
        self.toolCalls = toolCalls
        self.images = images
        self.modelID = modelID
        self.createdAt = createdAt
    }
}

public struct MessagePage: Equatable, Sendable {
    public var messages: [MessageSnapshot]
    public var truncated: Bool
    public var total: Int

    public init(messages: [MessageSnapshot], truncated: Bool, total: Int) {
        self.messages = messages
        self.truncated = truncated
        self.total = total
    }
}

/// Conversation persistence over the shared SwiftData container. Actor-isolated
/// so message appends from streaming tasks can never interleave.
public actor ConversationStore {
    public static let defaultPageLimit = 10_000

    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
        context.autosaveEnabled = false
    }

    // MARK: Conversations

    public func createConversation(title: String, modelID: String? = nil) throws -> ConversationSummary {
        let conversation = Conversation(title: title, modelID: modelID)
        context.insert(conversation)
        try context.save()
        return Self.summary(of: conversation)
    }

    public func conversations(limit: Int = 500) throws -> [ConversationSummary] {
        var descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map(Self.summary(of:))
    }

    /// `touch: false` keeps the conversation where it sits in the history (used when titling old conversations).
    public func renameConversation(_ id: UUID, to title: String, touch: Bool = true) throws {
        guard let conversation = try Self.fetchConversation(id, in: context) else { return }
        conversation.title = title
        if touch { conversation.updatedAt = Date() }
        try context.save()
    }

    public func setConversationModel(_ id: UUID, modelID: String?) throws {
        guard let conversation = try Self.fetchConversation(id, in: context) else { return }
        conversation.modelID = modelID
        try context.save()
    }

    public func deleteConversation(_ id: UUID) throws {
        guard let conversation = try Self.fetchConversation(id, in: context) else { return }
        context.delete(conversation)
        try context.save()
    }

    /// Fork-from-message: creates a new conversation containing every message
    /// up to and including the fork point, preserving order.
    public func fork(conversationID: UUID, atMessageID forkPoint: UUID, newTitle: String) throws -> ConversationSummary? {
        guard let source = try Self.fetchConversation(conversationID, in: context) else { return nil }
        let ordered = source.messages.sorted { $0.order < $1.order }
        guard let index = ordered.firstIndex(where: { $0.id == forkPoint }) else { return nil }
        let fork = Conversation(title: newTitle, modelID: source.modelID)
        context.insert(fork)
        for (offset, message) in ordered[...index].enumerated() {
            let copy = Message(
                role: message.role,
                content: message.content,
                reasoning: message.reasoning,
                tokenCount: message.tokenCount,
                order: offset,
                toolCallsJSON: message.toolCallsJSON,
                imagesJSON: message.imagesJSON,
                modelID: message.modelID
            )
            copy.createdAt = message.createdAt
            copy.conversation = fork
            context.insert(copy)
        }
        try context.save()
        return Self.summary(of: fork)
    }

    // MARK: Messages

    public func messages(conversationID: UUID, limit: Int = ConversationStore.defaultPageLimit) throws -> MessagePage {
        guard let conversation = try Self.fetchConversation(conversationID, in: context) else {
            return MessagePage(messages: [], truncated: false, total: 0)
        }
        let ordered = conversation.messages.sorted { $0.order < $1.order }
        let total = ordered.count
        let truncated = total > limit
        let page = truncated ? ordered.suffix(limit) : ordered[...]
        return MessagePage(
            messages: try page.map(Self.snapshot(of:)),
            truncated: truncated,
            total: total
        )
    }

    @discardableResult
    public func appendMessage(
        conversationID: UUID,
        role: ChatMessage.Role,
        content: String,
        reasoning: String? = nil,
        tokenCount: Int = 0,
        toolCalls: [ToolCall] = [],
        modelID: String? = nil,
        images: [ChatImage] = []
    ) throws -> MessageSnapshot? {
        try appendMessages(conversationID: conversationID, items: [(role, content, reasoning, tokenCount, toolCalls, modelID)], imagePayloads: [images]).first
    }

    /// Bulk append: one fetch and one save regardless of item count.
    public func appendMessages(
        conversationID: UUID,
        items: [(role: ChatMessage.Role, content: String, reasoning: String?, tokenCount: Int, toolCalls: [ToolCall], modelID: String?)],
        imagePayloads: [[ChatImage]]? = nil
    ) throws -> [MessageSnapshot] {
        guard let conversation = try Self.fetchConversation(conversationID, in: context) else { return [] }
        var nextOrder = (conversation.messages.map(\.order).max() ?? -1) + 1
        var snapshots: [MessageSnapshot] = []
        snapshots.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let images = imagePayloads.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? []
            let message = Message(
                role: item.role.rawValue,
                content: item.content,
                reasoning: item.reasoning,
                tokenCount: item.tokenCount,
                order: nextOrder,
                toolCallsJSON: item.toolCalls.isEmpty ? nil : try JSONEncoder().encode(item.toolCalls),
                imagesJSON: images.isEmpty ? nil : try JSONEncoder().encode(images),
                modelID: item.modelID
            )
            message.conversation = conversation
            context.insert(message)
            snapshots.append(try Self.snapshot(of: message))
            nextOrder += 1
        }
        conversation.updatedAt = Date()
        try context.save()
        return snapshots
    }

    public func updateMessage(_ id: UUID, content: String, reasoning: String? = nil, tokenCount: Int = 0, toolCalls: [ToolCall]? = nil) throws {
        guard let message = try Self.fetchMessage(id, in: context) else { return }
        message.content = content
        if let reasoning { message.reasoning = reasoning }
        message.tokenCount = tokenCount
        if let toolCalls { message.toolCallsJSON = toolCalls.isEmpty ? nil : try JSONEncoder().encode(toolCalls) }
        message.conversation?.updatedAt = Date()
        try context.save()
    }

    public func deleteMessage(_ id: UUID) throws {
        guard let message = try Self.fetchMessage(id, in: context) else { return }
        message.conversation?.updatedAt = Date()
        context.delete(message)
        try context.save()
    }

    // MARK: Helpers

    private static func fetchConversation(_ id: UUID, in context: ModelContext) throws -> Conversation? {
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func fetchMessage(_ id: UUID, in context: ModelContext) throws -> Message? {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func summary(of conversation: Conversation) -> ConversationSummary {
        ConversationSummary(
            id: conversation.id,
            title: conversation.title,
            modelID: conversation.modelID,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            messageCount: conversation.messages.count
        )
    }

    private static func snapshot(of message: Message) throws -> MessageSnapshot {
        let role = ChatMessage.Role(rawValue: message.role) ?? .user
        let toolCalls = message.toolCallsJSON.flatMap { try? JSONDecoder().decode([ToolCall].self, from: $0) } ?? []
        let images = try message.imagesJSON.map { try JSONDecoder().decode([ChatImage].self, from: $0) } ?? []
        return MessageSnapshot(
            id: message.id,
            role: role,
            content: message.content,
            reasoning: message.reasoning,
            tokenCount: message.tokenCount,
            order: message.order,
            toolCalls: toolCalls,
            images: images,
            modelID: message.modelID,
            createdAt: message.createdAt
        )
    }
}
