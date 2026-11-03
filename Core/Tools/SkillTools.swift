import Foundation

/// Lets the agent use the skills already installed for Claude Code, Codex and OpenCode.
public struct ListSkillsTool: ToolExecuting {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "list_skills",
            summary: "List the skills available on this Mac",
            detail: "Skills installed for Claude Code, Codex and OpenCode, merged so each appears once. Read one with read_skill before doing work it covers.",
            parameters: [ToolParam(name: "query", type: "string", description: "Optional text to filter by name or description", required: false)],
            permission: .read
        )
    }

    struct Args: Decodable, Sendable { var query: String? }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let query = args.query?.lowercased() ?? ""
        let skills = SkillCatalog.scan().filter {
            query.isEmpty || $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query)
        }
        if skills.isEmpty { return "No skills found." }
        return skills.map { "\($0.name) — \($0.description.prefix(160))" }.joined(separator: "\n")
    }
}

public struct ReadSkillTool: ToolExecuting {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "read_skill",
            summary: "Read a skill's instructions (SKILL.md)",
            detail: "Returns the skill's SKILL.md and the folder it lives in, so bundled scripts and references can be found.",
            parameters: [ToolParam(name: "name", type: "string", description: "Skill name from list_skills", required: true)],
            permission: .read
        )
    }

    struct Args: Decodable, Sendable { var name: String }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        guard let skill = SkillCatalog.scan().first(where: { $0.name == args.name }) else {
            throw AgentRunError.permissionDenied("No skill named '\(args.name)'. Use list_skills.")
        }
        let text = (try? String(contentsOf: skill.file, encoding: .utf8)) ?? ""
        let capped = text.count > 60_000 ? String(text.prefix(60_000)) + "\n[truncated]" : text
        return "Skill folder: \(skill.directory.path)\n\n\(capped)"
    }
}
