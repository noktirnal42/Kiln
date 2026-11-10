import Foundation

/// Every platform feature (memory, commands, hooks, checkpoints, sessions, usage) is a tool too, so the in-app
/// agent and external MCP clients can use what the person can. All are named `kiln_*`.
public enum PlatformTools {
    public static var all: [any ToolExecuting] {
        [MemoryReadTool(), MemoryWriteTool()]
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
