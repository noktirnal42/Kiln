import Foundation

// MARK: - Git tools (thin wrappers over Core/Git GitService)

public struct GitStatusTool: ToolExecuting {
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(
            name: "git_status",
            summary: "Show git working-copy status",
            parameters: [],
            permission: .read,
            requiresWorkspace: true
        )
    }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let root = try WorkspacePathResolver.requireRoot(context)
        let git = context.services.git ?? GitService()
        guard await git.isRepository(root.path) else { return "Not a git repository." }
        let statuses = try await git.status(root.path)
        guard !statuses.isEmpty else { return "Working copy clean." }
        return statuses
            .map { "\($0.statusCode)\t\($0.path)" }
            .joined(separator: "\n")
    }
}

public struct GitDiffTool: ToolExecuting {
    public struct Args: Decodable, Sendable { public var staged: Bool?; public var path: String? }
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(
            name: "git_diff",
            summary: "Show git changes as a unified diff",
            detail: "Omit path for the whole repository.",
            parameters: [
                ToolParam(name: "staged", type: "boolean", description: "Show staged (indexed) changes", required: false),
                ToolParam(name: "path", type: "string", description: "Limit to one path", required: false),
            ],
            permission: .read,
            requiresWorkspace: true
        )
    }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let git = context.services.git ?? GitService()
        guard await git.isRepository(root.path) else { return "Not a git repository." }
        let diff = try await git.diff(root.path, staged: args.staged ?? false, path: args.path)
        return diff.isEmpty ? "No changes." : ToolOutputCap.fit(diff, from: "git_diff")
    }
}

public struct GitCommitTool: ToolExecuting {
    public struct Args: Decodable, Sendable { public var message: String; public var paths: [String]? }
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(
            name: "git_commit",
            summary: "Stage paths and create a git commit",
            detail: "Nothing is ever pushed automatically.",
            parameters: [
                ToolParam(name: "message", type: "string", description: "Commit message", required: true),
                ToolParam(name: "paths", type: "array", description: "Paths to stage before committing; omit to commit what is already staged", required: false),
            ],
            permission: .write,
            requiresWorkspace: true
        )
    }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let git = context.services.git ?? GitService()
        guard await git.isRepository(root.path) else { return "Not a git repository." }
        if let paths = args.paths, !paths.isEmpty {
            try await git.stage(root.path, paths: paths)
        }
        let summary = try await git.commit(root.path, message: args.message)
        return summary
    }
}

public struct GitBranchTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var action: String?
        public var name: String?
    }
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(
            name: "git_branch",
            summary: "List, create, or check out git branches",
            detail: "action: list (default), create, checkout.",
            parameters: [
                ToolParam(name: "action", type: "string", description: "list | create | checkout", required: false),
                ToolParam(name: "name", type: "string", description: "Branch name for create/checkout", required: false),
            ],
            permission: .write,
            requiresWorkspace: true
        )
    }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let git = context.services.git ?? GitService()
        guard await git.isRepository(root.path) else { return "Not a git repository." }
        switch args.action ?? "list" {
        case "list":
            let (current, all) = try await git.branches(root.path)
            return all.map { $0 == current ? "* \($0)" : "  \($0)" }.joined(separator: "\n")
        case "create":
            guard let name = args.name, !name.isEmpty else { throw AgentRunError.permissionDenied("create needs a branch name.") }
            try await git.createBranch(root.path, name: name)
            return "Created branch \(name)."
        case "checkout":
            guard let name = args.name, !name.isEmpty else { throw AgentRunError.permissionDenied("checkout needs a branch name.") }
            try await git.checkout(root.path, branch: name)
            return "Checked out \(name)."
        default:
            throw AgentRunError.permissionDenied("Unknown action '\(args.action ?? "")' — use list, create, or checkout.")
        }
    }
}

public struct GitLogTool: ToolExecuting {
    public struct Args: Decodable, Sendable { public var limit: Int? }
    public init() {}
    public var spec: ToolSpec {
        ToolSpec(
            name: "git_log",
            summary: "Show recent commits",
            parameters: [
                ToolParam(name: "limit", type: "integer", description: "How many commits (default 20)", required: false),
            ],
            permission: .read,
            requiresWorkspace: true
        )
    }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let git = context.services.git ?? GitService()
        guard await git.isRepository(root.path) else { return "Not a git repository." }
        let commits = try await git.log(root.path, limit: min(args.limit ?? 20, 100))
        guard !commits.isEmpty else { return "No commits yet." }
        return commits
            .map { commit in
                let date = commit.date.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .none) } ?? "?"
                return "\(commit.hash.prefix(8)) \(date) \(commit.subject)"
            }
            .joined(separator: "\n")
    }
}
