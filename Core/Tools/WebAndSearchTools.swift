import Foundation

// MARK: - Web tools

public struct WebFetchTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var url: String
        public var maxBytes: Int?
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "web_fetch",
            summary: "Fetch a web page as text",
            detail: "The execution policy gates which hosts may be fetched; internal addresses are always refused.",
            parameters: [
                ToolParam(name: "url", type: "string", description: "The http(s) URL to fetch", required: true),
                ToolParam(name: "maxBytes", type: "integer", description: "Response size cap (default 200 KB)", required: false),
            ],
            permission: .execute
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        guard let url = URL(string: args.url), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw AgentRunError.permissionDenied("'\(args.url)' is not an http(s) URL.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Kiln/0.1 (Macintosh)", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AgentRunError.permissionDenied("Fetch failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AgentRunError.permissionDenied("Fetch failed: not an HTTP response.")
        }
        let cap = min(args.maxBytes ?? 200_000, 400_000)
        let slice = data.prefix(cap)
        let text = String(data: slice, encoding: .utf8)
            ?? (String(data: slice, encoding: .isoLatin1) ?? "(binary response)")
        var out = "[HTTP \(http.statusCode)]\n" + text
        if data.count > cap {
            out += "\n…[response truncated at \(cap) bytes of \(data.count)]…"
        }
        return ToolOutputCap.fit(out, from: "web_fetch")
    }
}

public struct WebSearchTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var query: String
        public var limit: Int?
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "web_search",
            summary: "Search the web",
            detail: "Requires a configured search backend (Tavily API key).",
            parameters: [
                ToolParam(name: "query", type: "string", description: "What to search for", required: true),
                ToolParam(name: "limit", type: "integer", description: "Max results (default 5)", required: false),
            ],
            permission: .execute
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        guard let keyProvider = context.services.webSearchKey, let key = keyProvider(),
              !key.isEmpty else {
            throw AgentRunError.permissionDenied(
                "Web search is not configured: no search backend API key is set. Configure a Tavily key in settings, or use web_fetch on a known URL."
            )
        }
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let payload: [String: Any] = [
            "api_key": key,
            "query": args.query,
            "max_results": min(args.limit ?? 5, 10),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AgentRunError.permissionDenied("Search failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AgentRunError.permissionDenied("Search failed: not an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentRunError.permissionDenied("Search backend returned HTTP \(http.statusCode).")
        }
        struct TavilyResponse: Decodable {
            struct Result: Decodable {
                var title: String?
                var url: String?
                var content: String?
            }
            var results: [Result]?
        }
        guard let decoded = try? JSONDecoder().decode(TavilyResponse.self, from: data),
              let results = decoded.results, !results.isEmpty else {
            return "No results for '\(args.query)'."
        }
        let lines = results.map { result -> String in
            let title = result.title ?? "(untitled)"
            let url = result.url ?? ""
            let snippet = (result.content ?? "").prefix(400)
            return "\(title)\n\(url)\n\(snippet)"
        }
        return ToolOutputCap.fit(lines.joined(separator: "\n\n"), from: "web_search")
    }
}

// MARK: - Workspace search tool

public struct SearchWorkspaceTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var query: String
        public var limit: Int?
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "search_workspace",
            summary: "Search the workspace for files by name",
            detail: "Uses the app's file index (FTS over names/paths) when available, falling back to a filename scan of the workspace root. Use grep_files to search file contents.",
            parameters: [
                ToolParam(name: "query", type: "string", description: "Search text", required: true),
                ToolParam(name: "limit", type: "integer", description: "Max results (default 30)", required: false),
            ],
            permission: .read,
            requiresWorkspace: true
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let limit = min(args.limit ?? 30, 100)

        if let index = context.services.fileIndex,
           await index.indexedRootPath() == root.path {
            let hits = await index.search(args.query, limit: limit, includeSpotlight: false)
            if !hits.isEmpty {
                let lines = hits.map { "\($0.file.path)\n  score \($0.score)" }
                return ToolOutputCap.fit(lines.joined(separator: "\n"), from: "search_workspace")
            }
            return "No matches for '\(args.query)' in the index."
        }

        // Fallback: filename scan under the workspace root.
        let needle = args.query.lowercased()
        var matches: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        while let next = enumerator?.nextObject() as? URL {
            if next.lastPathComponent.lowercased().contains(needle) {
                matches.append(WorkspacePathResolver.relativePath(of: next.path, under: root) ?? next.lastPathComponent)
                if matches.count >= limit { break }
            }
        }
        return matches.isEmpty
            ? "No indexed search available and no filename matched '\(args.query)'."
            : matches.sorted().joined(separator: "\n")
    }
}

// MARK: - Registration

public enum BuiltInTools {
    /// Registers every tool Kiln ships with. Call once at launch.
    public static func registerAll(into registry: ToolRegistry = .shared) {
        let tools: [any ToolExecuting] = [
            ReadFileTool(), WriteFileTool(), EditFileTool(), DeleteFileTool(),
            ListDirectoryTool(), GlobFilesTool(), GrepFilesTool(),
            RunCommandTool(), StreamCommandTool(), BackgroundCommandTool(), ReadCommandOutputTool(),
            GitStatusTool(), GitDiffTool(), GitCommitTool(), GitBranchTool(), GitLogTool(),
            WebFetchTool(), WebSearchTool(),
            SearchWorkspaceTool(),
            ListSkillsTool(), ReadSkillTool(), MCPListTools(), MCPCallTool(), ComputerUseTool(),
        ] + PlatformTools.all
        for tool in tools { registry.register(tool) }
    }
}
