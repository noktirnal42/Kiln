import Foundation

public enum SwarmRole: String, Codable, Sendable, CaseIterable {
    case researcher, implementer, reviewer

    /// Tool names each role may use. Researchers and reviewers cannot write or run anything.
    var tools: Set<String> {
        let read: Set<String> = ["read_file", "list_directory", "glob_files", "grep_files", "search_workspace",
                                 "git_status", "git_diff", "git_log", "re_*", "lab_*"]
        switch self {
        case .researcher: return read.union(["web_fetch", "web_search"])
        case .reviewer: return read
        case .implementer:
            return read.union(["write_file", "edit_file", "run_command", "git_commit", "git_branch"])
        }
    }

    var instructions: String {
        switch self {
        case .researcher: "You gather facts. Read, search and report what you found with the file or source for each claim. You cannot change anything."
        case .implementer: "You make the change. Read before you edit, keep the change small, and verify it. Say exactly what you changed."
        case .reviewer: "You check the work of others. Read what was produced, look for bugs and gaps, and say plainly what is wrong or that it looks right. You cannot change anything."
        }
    }
}

public enum SwarmTaskStatus: String, Codable, Sendable {
    case pending, running, done, blocked, skipped
}

public struct SwarmTask: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var details: String
    public var role: SwarmRole
    public var dependsOn: [String]
    public var status: SwarmTaskStatus = .pending
    public var result: String?
    public var attempts = 0
    /// Artifacts the task must leave behind (`file:<path>`, `nonempty:<path>`), checked on disk after it finishes.
    public var expects: [String] = []
    /// One line of what the worker actually did (tools executed, files written, commands run).
    public var evidence: String?

    public init(id: String, title: String, details: String = "", role: SwarmRole, dependsOn: [String] = [], expects: [String] = []) {
        self.id = id; self.title = title; self.details = details; self.role = role; self.dependsOn = dependsOn; self.expects = expects
    }
}

/// The dependency graph of a swarm run. Pure: scheduling decisions are made here and nowhere else.
public struct SwarmGraph: Sendable, Equatable {
    public private(set) var tasks: [SwarmTask]

    public enum Invalid: Error, Equatable, CustomStringConvertible {
        case empty, tooMany(Int), invalidID(String), duplicateID(String), unknownDependency(task: String, missing: String), cycle

        public var description: String {
            switch self {
            case .empty: "The plan has no tasks."
            case .tooMany(let limit): "The plan has more than \(limit) tasks."
            case .invalidID(let id): "Task id '\(id)' must use lowercase letters, numbers, dots, underscores or hyphens and be at most 57 characters."
            case .duplicateID(let id): "Two tasks share the id '\(id)'."
            case .unknownDependency(let task, let missing): "Task '\(task)' depends on unknown task '\(missing)'."
            case .cycle: "The plan's dependencies form a cycle."
            }
        }
    }

    public static let maxTasks = 12

    public init(tasks: [SwarmTask]) throws {
        guard !tasks.isEmpty else { throw Invalid.empty }
        guard tasks.count <= Self.maxTasks else { throw Invalid.tooMany(Self.maxTasks) }
        var seen = Set<String>()
        // Worker IDs are registered as "worker.<id>" on the bus (64-character limit).
        let validID = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9._-]{0,56}$")
        for task in tasks where validID.firstMatch(in: task.id, range: NSRange(task.id.startIndex..., in: task.id)) == nil {
            throw Invalid.invalidID(task.id)
        }
        for task in tasks where !seen.insert(task.id).inserted { throw Invalid.duplicateID(task.id) }
        for task in tasks {
            for dependency in task.dependsOn where !seen.contains(dependency) {
                throw Invalid.unknownDependency(task: task.id, missing: dependency)
            }
        }
        self.tasks = tasks
        if hasCycle() { throw Invalid.cycle }
    }

    private func hasCycle() -> Bool {
        var remaining = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, Set($0.dependsOn)) })
        while true {
            let free = remaining.filter { $0.value.isEmpty }.map(\.key)
            if free.isEmpty { return !remaining.isEmpty }
            for id in free { remaining.removeValue(forKey: id) }
            for key in remaining.keys { remaining[key]?.subtract(free) }
        }
    }

    public func task(_ id: String) -> SwarmTask? { tasks.first { $0.id == id } }

    /// Pending tasks whose dependencies are all done, in plan order.
    public var ready: [SwarmTask] {
        let done = Set(tasks.filter { $0.status == .done }.map(\.id))
        return tasks.filter { $0.status == .pending && Set($0.dependsOn).isSubset(of: done) }
    }

    public var isFinished: Bool { !tasks.contains { $0.status == .pending || $0.status == .running } }

    public mutating func update(_ id: String, _ change: (inout SwarmTask) -> Void) {
        if let index = tasks.firstIndex(where: { $0.id == id }) { change(&tasks[index]) }
    }

    /// After a task is blocked, everything that needs it (directly or not) can never run.
    public mutating func skipDependents(of blocked: String) {
        var doomed: Set<String> = [blocked]
        var grew = true
        while grew {
            grew = false
            for task in tasks where task.status == .pending && !doomed.contains(task.id) && !doomed.isDisjoint(with: task.dependsOn) {
                doomed.insert(task.id); grew = true
            }
        }
        for id in doomed where id != blocked { update(id) { $0.status = .skipped } }
    }
}

public enum SwarmPlanner {
    /// What happens when no usable plan comes back from a model: research, then implement, then review.
    public static func fallback(goal: String) -> SwarmGraph {
        // Three fixed tasks with known ids cannot be invalid.
        try! SwarmGraph(tasks: [
            SwarmTask(id: "research", title: "Research", details: "Find what is relevant to: \(goal)", role: .researcher),
            SwarmTask(id: "implement", title: "Implement", details: "Carry out: \(goal)", role: .implementer, dependsOn: ["research"]),
            SwarmTask(id: "review", title: "Review", details: "Check the result against: \(goal)", role: .reviewer, dependsOn: ["implement"]),
        ])
    }

    public static let prompt = """
    Break the user's goal into at most 8 tasks for a small team. Reply with JSON only:
    {"tasks":[{"id":"short-id","title":"...","details":"...","role":"researcher|implementer|reviewer","depends_on":["other-id"],"expects":["file:relative/path"]}]}
    "expects" is optional: list the files an implementer must leave behind ("file:path" must exist, "nonempty:path" must have content); the team lead checks them on disk.
    IDs must be lowercase and use only letters, digits, dots, underscores or hyphens, at most 57 characters.
    Tasks with no dependency on each other run in parallel. Use researcher for reading, implementer for changes, reviewer for checking.
    """

    /// Parses a model's reply. Any problem returns nil so the caller can fall back; a plan is only
    /// ever used if it is a valid graph.
    public static func parse(_ reply: String) -> SwarmGraph? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8))) as? [String: Any],
              let rows = object["tasks"] as? [[String: Any]] else { return nil }
        var tasks: [SwarmTask] = []
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty, let title = row["title"] as? String,
                  let role = (row["role"] as? String).flatMap(SwarmRole.init(rawValue:)) else { return nil }
            if row["depends_on"] != nil && !(row["depends_on"] is [String]) { return nil }
            tasks.append(SwarmTask(id: id, title: title, details: row["details"] as? String ?? "", role: role,
                                   dependsOn: row["depends_on"] as? [String] ?? [],
                                   expects: (row["expects"] as? [String] ?? []).filter { TaskExpectation($0) != nil }))
        }
        return try? SwarmGraph(tasks: tasks)
    }

    public static func plan(goal: String, ask: @Sendable (String, String) async throws -> String) async -> (graph: SwarmGraph, usedFallback: Bool) {
        if let reply = try? await ask(prompt, goal), let graph = parse(reply) { return (graph, false) }
        return (fallback(goal: goal), true)
    }
}
