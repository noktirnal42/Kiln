import Foundation

/// The agent's own task list for a conversation, the way Claude Code's todo list works: the agent writes the whole list,
/// the thread shows it above the composer, and it survives only as long as the conversation is open.
public struct TodoItem: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, in_progress, completed }
    public var id: Int
    public var content: String
    public var status: Status
}

public final class TodoBoard: @unchecked Sendable {
    public static let shared = TodoBoard()
    private let lock = NSLock()
    private var lists: [UUID: [TodoItem]] = [:]
    private var observers: [@Sendable (UUID) -> Void] = []

    public init() {}

    public func items(for conversation: UUID) -> [TodoItem] { lock.withLock { lists[conversation] ?? [] } }

    public func set(_ items: [TodoItem], for conversation: UUID) {
        let listeners = lock.withLock { () -> [@Sendable (UUID) -> Void] in
            if items.isEmpty { lists[conversation] = nil } else { lists[conversation] = items }
            return observers
        }
        listeners.forEach { $0(conversation) }
    }

    public func clear(_ conversation: UUID) { set([], for: conversation) }

    /// Called (on any thread) whenever a conversation's list changes.
    public func observe(_ handler: @escaping @Sendable (UUID) -> Void) { lock.withLock { observers.append(handler) } }

    /// "3 of 5 done · now: Write the tests", for the status line and tests.
    public static func summary(_ items: [TodoItem]) -> String {
        let done = items.filter { $0.status == .completed }.count
        var text = "\(done) of \(items.count) done"
        if let current = items.first(where: { $0.status == .in_progress }) { text += " · now: \(current.content)" }
        return text
    }
}

public struct TodoWriteTool: ToolExecuting {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(
            name: "kiln_todo_write",
            summary: "Keep a visible task list for the current job",
            detail: "Use for work with three or more steps. Send the WHOLE list every time: items with content and status (pending, in_progress, completed). Keep exactly one item in_progress, mark it completed as soon as it is done, and do not batch up completions. The list is shown to the person above the message box. It changes nothing on disk.",
            parameters: [ToolParam(name: "todos", type: "array", description: "The full list: [{\"content\": \"...\", \"status\": \"pending|in_progress|completed\"}]", required: true)],
            permission: .read
        )
    }

    struct Args: Decodable, Sendable {
        /// A bare string is accepted as a pending item: the generated array schema only promises strings.
        struct Item: Decodable, Sendable {
            var content: String
            var status: String?
            private enum Keys: String, CodingKey { case content, status, task, text }
            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
                    content = text; status = nil; return
                }
                let keyed = try decoder.container(keyedBy: Keys.self)
                if let text = try? keyed.decode(String.self, forKey: .content) { content = text }
                else if let text = try? keyed.decode(String.self, forKey: .task) { content = text }
                else { content = try keyed.decode(String.self, forKey: .text) }
                status = try? keyed.decode(String.self, forKey: .status)
            }
        }
        var todos: [Item]
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let items = args.todos.prefix(40).enumerated().compactMap { index, item -> TodoItem? in
            let content = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return TodoItem(id: index + 1, content: String(content.prefix(200)), status: TodoItem.Status(rawValue: item.status ?? "pending") ?? .pending)
        }
        TodoBoard.shared.set(items, for: context.conversationID)
        return items.isEmpty ? "Task list cleared." : "Task list updated: " + TodoBoard.summary(items) + "."
    }
}
