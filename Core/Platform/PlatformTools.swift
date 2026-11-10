import Foundation

/// Every platform feature (memory, commands, hooks, checkpoints, sessions, usage) is a tool too, so the in-app
/// agent and external MCP clients can use what the person can. All are named `kiln_*`.
public enum PlatformTools {
    public static var all: [any ToolExecuting] {
        [MemoryReadTool(), MemoryWriteTool(), CommandListTool(), CommandExpandTool(), CommandWriteTool(), HooksListTool(), CheckpointListTool()]
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
