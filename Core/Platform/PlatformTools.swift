import Foundation

/// Every platform feature (memory, commands, hooks, checkpoints, sessions, usage) is a tool too, so the in-app
/// agent and external MCP clients can use what the person can. All are named `kiln_*`.
public enum PlatformTools {
    public static var all: [any ToolExecuting] {
        [MemoryReadTool(), MemoryWriteTool(), CommandListTool(), CommandExpandTool(), CommandWriteTool(), HooksListTool(), CheckpointListTool(), UsageReportTool(), ScheduleListTool(), ScheduleWriteTool(), TodoWriteTool(), RoundLimitReadTool(), RoundLimitWriteTool()]
    }
}

public struct RoundLimitReadTool: ToolExecuting {
    let limits: AgentRoundLimits
    public init() { limits = .shared }
    init(limits: AgentRoundLimits) { self.limits = limits }
    public var spec: ToolSpec {
        ToolSpec(name: "kiln_round_limit_read", summary: "Read a profile's agent step limit", detail: "Reads the maximum model rounds for the named agent profile.", parameters: [ToolParam(name: "profile", type: "string", description: "Agent profile name", required: true)], permission: .read)
    }
    struct Args: Decodable, Sendable { var profile: String }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        guard AgentProfile.builtIns.contains(where: { $0.name == args.profile }) else { throw AgentRunError.permissionDenied("Unknown agent profile.") }
        return "\(args.profile): \(limits.limit(for: args.profile)) steps per run."
    }
}

public struct RoundLimitWriteTool: ToolExecuting {
    let limits: AgentRoundLimits
    public init() { limits = .shared }
    init(limits: AgentRoundLimits) { self.limits = limits }
    public var spec: ToolSpec {
        ToolSpec(name: "kiln_round_limit_set", summary: "Set a profile's agent step limit", detail: "Changes the limit for future runs, not one already in progress. Requires approval; budget and approval rules still apply.", parameters: [ToolParam(name: "profile", type: "string", description: "Agent profile name", required: true), ToolParam(name: "steps", type: "integer", description: "Maximum model rounds, 1–10000", required: true)], permission: .write)
    }
    struct Args: Decodable, Sendable { var profile: String; var steps: Int }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        guard AgentProfile.builtIns.contains(where: { $0.name == args.profile }), limits.set(args.steps, for: args.profile) else { throw AgentRunError.permissionDenied("Choose a known profile and a limit from 1 to 10000.") }
        await context.services.audit?.record("agent.round_limit_changed", ["profile": .string(args.profile), "steps": .int(args.steps), "source": .string("tool")])
        return "\(args.profile) will pause after \(args.steps) steps on its next run."
    }
}

public struct MemoryReadTool: ToolExecuting {
    var home: URL? = FileManager.default.homeDirectoryForCurrentUser
    public init() {}
    init(home: URL?) { self.home = home }

    public var spec: ToolSpec {
        ToolSpec(
            name: "kiln_memory_read",
            summary: "Show the memory files (KILN.md, AGENTS.md, CLAUDE.md) in use",
            detail: "Lists the user and project memory files, which are in the system prompt, how many tokens each costs, and their text.",
            parameters: [], permission: .read
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let snapshot = MemoryLoader.load(workspaceRoot: context.workspaceRoot, home: home)
        let present = snapshot.files.filter(\.exists)
        if present.isEmpty { return "No memory files. KILN.md, AGENTS.md or CLAUDE.md in the project (or ~/.kiln/KILN.md, ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md) would be read at the start of a run." }
        return present.map { file in
            let state = file.duplicateOf != nil ? "same text as \(file.duplicateOf!), not sent twice" : "\(file.tokens) tokens"
            return "## \(file.name) [\(file.scope.rawValue)] \(file.path) — \(state)\n\(file.content)"
        }.joined(separator: "\n\n")
    }
}

public struct MemoryWriteTool: ToolExecuting {
    var home: URL? = FileManager.default.homeDirectoryForCurrentUser
    public init() {}
    init(home: URL?) { self.home = home }

    public var spec: ToolSpec {
        ToolSpec(
            name: "kiln_memory_write",
            summary: "Write a memory file (KILN.md, AGENTS.md or CLAUDE.md)",
            detail: "Replaces the whole file at `path`, which must be one of the known memory files. Read it first with kiln_memory_read and keep what should stay.",
            parameters: [
                ToolParam(name: "path", type: "string", description: "Absolute path of the memory file", required: true),
                ToolParam(name: "content", type: "string", description: "The full new text", required: true),
            ],
            permission: .write
        )
    }

    struct Args: Decodable, Sendable { var path: String; var content: String }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let existed = FileManager.default.fileExists(atPath: args.path)
        do { try MemoryLoader.save(args.content, path: args.path, workspaceRoot: context.workspaceRoot, home: home) }
        catch { throw AgentRunError.permissionDenied(String(describing: error)) }
        await context.services.audit?.record("memory.saved", [
            "path": .string(args.path), "bytes": .int(args.content.utf8.count), "created": .bool(!existed), "source": .string("tool"),
        ])
        return "Saved \(args.path) (\(args.content.utf8.count) bytes). It is read at the start of the next run."
    }
}

// MARK: - Commands

public struct CommandListTool: ToolExecuting {
    var home: URL? = FileManager.default.homeDirectoryForCurrentUser
    public init() {}
    init(home: URL?) { self.home = home }
    public var spec: ToolSpec {
        ToolSpec(name: "kiln_command_list", summary: "List slash commands (built-in and custom)",
                 detail: "Custom commands live in .kiln/commands/*.md in the project or ~/.kiln/commands. Use kiln_command_expand to get one's prompt.",
                 parameters: [], permission: .read)
    }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        SlashCommands.all(workspaceRoot: context.workspaceRoot, home: home).map {
            "/\($0.name)\($0.argumentHint.map { " \($0)" } ?? "") [\($0.source.rawValue)] — \($0.summary)"
        }.joined(separator: "\n")
    }
}

public struct CommandExpandTool: ToolExecuting {
    var home: URL? = FileManager.default.homeDirectoryForCurrentUser
    public init() {}
    init(home: URL?) { self.home = home }
    public var spec: ToolSpec {
        ToolSpec(name: "kiln_command_expand", summary: "Expand a custom slash command into its prompt",
                 detail: "Returns the prompt text of a custom command with its arguments filled in. Follow it as if the user had typed it; it grants no extra permissions.",
                 parameters: [ToolParam(name: "name", type: "string", description: "Command name without the slash", required: true),
                              ToolParam(name: "arguments", type: "string", description: "Text typed after the command", required: false)],
                 permission: .read)
    }
    struct Args: Decodable, Sendable { var name: String; var arguments: String? }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let commands = SlashCommands.loadCustom(workspaceRoot: context.workspaceRoot, home: home)
        guard let command = commands.first(where: { $0.name == args.name }) else {
            throw AgentRunError.permissionDenied("No custom command '/\(args.name)'. Use kiln_command_list.")
        }
        await context.services.audit?.record("command.invoked", ["name": .string(command.name), "source": .string("tool")])
        return SlashCommands.expand(command, arguments: args.arguments ?? "")
    }
}

public struct CommandWriteTool: ToolExecuting {
    var home: URL? = FileManager.default.homeDirectoryForCurrentUser
    public init() {}
    init(home: URL?) { self.home = home }
    public var spec: ToolSpec {
        ToolSpec(name: "kiln_command_write", summary: "Create or replace a custom slash command",
                 detail: "Writes .kiln/commands/<name>.md in the project (scope project) or ~/.kiln/commands (scope user). Content may start with frontmatter (description, argument-hint, model).",
                 parameters: [ToolParam(name: "name", type: "string", description: "Command name (letters, digits, - and _); built-in names are refused", required: true),
                              ToolParam(name: "content", type: "string", description: "Markdown prompt template", required: true),
                              ToolParam(name: "scope", type: "string", description: "project (default) or user", required: false)],
                 permission: .write)
    }
    struct Args: Decodable, Sendable { var name: String; var content: String; var scope: String? }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let scope: SlashCommand.Source = args.scope == "user" ? .user : .project
        guard let url = SlashCommands.fileURL(name: args.name, scope: scope, workspaceRoot: context.workspaceRoot, home: home) else {
            throw AgentRunError.permissionDenied("Cannot create command '\(args.name)': invalid or built-in name, or no project open.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: url.path)
        try args.content.write(to: url, atomically: true, encoding: .utf8)
        await context.services.audit?.record("command.saved", ["path": .string(url.path), "created": .bool(!existed), "source": .string("tool")])
        return "Saved \(url.path)"
    }
}

public struct HooksListTool: ToolExecuting {
    var home: URL? = FileManager.default.homeDirectoryForCurrentUser
    public init() {}
    init(home: URL?) { self.home = home }
    public var spec: ToolSpec {
        ToolSpec(name: "kiln_hooks_list", summary: "List the hooks configured for this project and user",
                 detail: "Hooks run scripts at pre_tool, post_tool, prompt_submit and stop. They can block or annotate, never grant.",
                 parameters: [], permission: .read)
    }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let hooks = HookRunner.load(workspaceRoot: context.workspaceRoot, home: home)
        if hooks.isEmpty { return "No hooks configured (.kiln/hooks/hooks.json)." }
        return hooks.map { "\($0.scope ?? "project") \($0.event.rawValue)\($0.match.map { " [\($0)]" } ?? "") → \($0.command)" }.joined(separator: "\n")
    }
}

public struct CheckpointListTool: ToolExecuting {
    let store: CheckpointStore
    public init() { store = .default }
    init(store: CheckpointStore) { self.store = store }
    public var spec: ToolSpec {
        ToolSpec(name: "kiln_checkpoint_list", summary: "List checkpoints of file changes in this project",
                 detail: "Before the agent changes a file Kiln saves the old contents. Each checkpoint lists the files it can restore and the commands whose effects it cannot undo. Rewinding is done by the person from the conversation.",
                 parameters: [], permission: .read)
    }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let root = context.workspaceRoot?.path
        let list = store.all().filter { root == nil || $0.workspace == root }
        if list.isEmpty { return "No checkpoints for this project." }
        return list.suffix(30).map { m in
            "\(m.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(m.files.count) file(s): \(m.files.prefix(5).map(\.path).joined(separator: ", "))"
                + (m.unrestorable.isEmpty ? "" : " · not restorable: \(m.unrestorable.prefix(3).joined(separator: "; "))") + (m.rewound ? " · rewound" : "")
        }.joined(separator: "\n")
    }
}

public struct UsageReportTool: ToolExecuting {
    let ledger: UsageLedger
    public init() { ledger = .default }
    init(ledger: UsageLedger) { self.ledger = ledger }
    public var spec: ToolSpec {
        ToolSpec(name: "kiln_usage_report", summary: "Tokens and estimated cost by provider, model and day",
                 detail: "Costs are estimates from prices the user entered; unpriced hosted models and local models are labelled. Also shows the daily budget.",
                 parameters: [], permission: .read)
    }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        func line(_ l: UsageLine) -> String {
            "\(l.key): \(l.tokens.formatted()) tokens, \(l.runs) runs, " + String(format: "$%.4f", l.costUSD) + (l.unpricedTokens > 0 ? " (+\(l.unpricedTokens.formatted()) tokens unpriced)" : "")
        }
        let today = ledger.today()
        var text = "Today: " + line(today).replacingOccurrences(of: "today: ", with: "")
        let budget = ledger.budget
        text += budget.isSet ? "\nBudget: \(budget.dailyTokens > 0 ? "\(budget.dailyTokens.formatted()) tokens" : "no token cap")" + (budget.dailyUSD > 0 ? String(format: ", $%.2f", budget.dailyUSD) : "") + " per day" : "\nNo daily budget set."
        text += "\n\nBy provider:\n" + (ledger.byProvider().map(line).joined(separator: "\n"))
        text += "\n\nBy model:\n" + (ledger.byModel().prefix(15).map(line).joined(separator: "\n"))
        text += "\n\nDaily:\n" + ledger.daily(limit: 14).map(line).joined(separator: "\n")
        return text
    }
}

public struct ScheduleListTool: ToolExecuting {
    let store: ScheduleStore
    public init() { store = .default }
    init(store: ScheduleStore) { self.store = store }
    public var spec: ToolSpec {
        ToolSpec(name: "kiln_schedule_list", summary: "List scheduled agent tasks", detail: "Each task runs a prompt with an agent profile on a schedule, as a normal run with approvals.",
                 parameters: [], permission: .read)
    }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let tasks = store.all
        if tasks.isEmpty { return "No scheduled tasks." }
        return tasks.map { "\($0.name) — \($0.describe), profile \($0.profileName), \($0.enabled ? "on" : "off")\($0.lastRun.map { ", last run \($0.formatted())" } ?? "")" }.joined(separator: "\n")
    }
}

public struct ScheduleWriteTool: ToolExecuting {
    let store: ScheduleStore
    public init() { store = .default }
    init(store: ScheduleStore) { self.store = store }
    public var spec: ToolSpec {
        ToolSpec(name: "kiln_schedule_write", summary: "Create, change or remove a scheduled agent task",
                 detail: "Give every_minutes (minimum 5) or daily_at as HH:mm. Scheduled runs use the named profile and still ask for approvals. action: save (default) or remove.",
                 parameters: [
                    ToolParam(name: "name", type: "string", description: "Task name (identifies it)", required: true),
                    ToolParam(name: "prompt", type: "string", description: "What the agent should do", required: false),
                    ToolParam(name: "profile", type: "string", description: "Agent profile name, default Coding Agent", required: false),
                    ToolParam(name: "every_minutes", type: "integer", description: "Repeat interval, at least 5", required: false),
                    ToolParam(name: "daily_at", type: "string", description: "HH:mm", required: false),
                    ToolParam(name: "enabled", type: "boolean", description: "Default true", required: false),
                    ToolParam(name: "action", type: "string", description: "save or remove", required: false),
                 ], permission: .write)
    }
    struct Args: Decodable, Sendable {
        var name: String; var prompt: String?; var profile: String?; var every_minutes: Int?; var daily_at: String?; var enabled: Bool?; var action: String?
    }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let existing = store.all.first { $0.name == args.name }
        if args.action == "remove" {
            guard let existing else { throw AgentRunError.permissionDenied("No scheduled task named '\(args.name)'.") }
            store.remove(existing.id)
            await context.services.audit?.record("schedule.saved", ["name": .string(args.name), "removed": .bool(true)])
            return "Removed \(args.name)."
        }
        let repeats: ScheduledTask.Repeat
        if let minutes = args.every_minutes {
            guard minutes >= 5 else { throw AgentRunError.permissionDenied("every_minutes must be at least 5.") }
            repeats = .everyMinutes(minutes)
        } else if let at = args.daily_at, let parts = Optional(at.split(separator: ":").compactMap { Int($0) }), parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) {
            repeats = .daily(hour: parts[0], minute: parts[1])
        } else if let existing { repeats = existing.repeats } else {
            throw AgentRunError.permissionDenied("Give every_minutes (≥5) or daily_at (HH:mm).")
        }
        guard let prompt = args.prompt ?? existing?.prompt, !prompt.isEmpty else { throw AgentRunError.permissionDenied("A prompt is required.") }
        var task = existing ?? ScheduledTask(name: args.name, prompt: prompt, profileName: args.profile ?? "Coding Agent", repeats: repeats)
        task.prompt = prompt; task.repeats = repeats
        if let profile = args.profile { task.profileName = profile }
        if let enabled = args.enabled { task.enabled = enabled }
        store.upsert(task)
        await context.services.audit?.record("schedule.saved", ["name": .string(task.name), "schedule": .string(task.describe), "profile": .string(task.profileName), "enabled": .bool(task.enabled)])
        return "Saved \(task.name): \(task.describe)."
    }
}
