import Foundation

// MARK: - File tools

public struct ReadFileTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var path: String
        public var offset: Int?
        public var limit: Int?
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "read_file",
            summary: "Read a text file from the workspace",
            detail: "Returns the file's text. Use offset/limit (line numbers, 1-based) to read a range of a long file.",
            parameters: [
                ToolParam(name: "path", type: "string", description: "File path, relative to the workspace root", required: true),
                ToolParam(name: "offset", type: "integer", description: "First line to read (1-based)", required: false),
                ToolParam(name: "limit", type: "integer", description: "How many lines to read", required: false),
            ],
            permission: .read,
            requiresWorkspace: true
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let url = try WorkspacePathResolver.resolve(args.path, in: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentRunError.permissionDenied("No file exists at '\(args.path)'.")
        }
        guard !SecretRedactor.isSensitiveFilename(url.lastPathComponent) else {
            throw AgentRunError.permissionDenied(
                "'\(url.lastPathComponent)' looks like a credentials file and is never sent to a model."
            )
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw AgentRunError.permissionDenied("'\(args.path)' is not a readable UTF-8 text file.")
        }
        var lines = text.components(separatedBy: "\n")
        let total = lines.count
        if let offset = args.offset, offset > 1 {
            lines = Array(lines.dropFirst(offset - 1))
        }
        if let limit = args.limit, limit > 0 {
            lines = Array(lines.prefix(limit))
        }
        var out = lines.joined(separator: "\n")
        if total > lines.count {
            out += "\n…[\(total - lines.count) more line(s) not shown; read with offset to continue]…"
        }
        return ToolOutputCap.fit(out, from: "read_file")
    }
}

public struct WriteFileTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var path: String
        public var content: String
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "write_file",
            summary: "Create or overwrite a file in the workspace",
            detail: "Writes the whole file. Read it first when changing existing code.",
            parameters: [
                ToolParam(name: "path", type: "string", description: "File path, relative to the workspace root", required: true),
                ToolParam(name: "content", type: "string", description: "The complete file content to write", required: true),
            ],
            permission: .write,
            requiresWorkspace: true
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let url = try WorkspacePathResolver.resolve(args.path, in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try args.content.data(using: .utf8)?.write(to: url, options: .atomic)
        return "Wrote \(args.content.utf8.count) bytes to \(args.path)."
    }
}

public struct EditFileTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var path: String
        public var find: String
        public var replace: String
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "edit_file",
            summary: "Replace one exact text occurrence in a file",
            detail: "Finds the exact `find` text and replaces it with `replace`. Fails if the text appears more than once or not at all.",
            parameters: [
                ToolParam(name: "path", type: "string", description: "File path, relative to the workspace root", required: true),
                ToolParam(name: "find", type: "string", description: "The exact text to find (must be unique in the file)", required: true),
                ToolParam(name: "replace", type: "string", description: "The replacement text", required: true),
            ],
            permission: .write,
            requiresWorkspace: true
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let url = try WorkspacePathResolver.resolve(args.path, in: root)
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            throw AgentRunError.permissionDenied("No readable text file exists at '\(args.path)'.")
        }
        let occurrences = original.components(separatedBy: args.find).count - 1
        guard occurrences == 1 else {
            throw AgentRunError.permissionDenied(
                occurrences == 0
                    ? "The text to find does not appear in '\(args.path)'."
                    : "The text to find appears \(occurrences) times in '\(args.path)'; make it unique or use write_file."
            )
        }
        let proposed = original.replacingOccurrences(of: args.find, with: args.replace)
        try proposed.data(using: .utf8)?.write(to: url, options: .atomic)
        return "Edited \(args.path)."
    }
}

public struct DeleteFileTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var path: String
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "delete_file",
            summary: "Delete a file or empty directory in the workspace",
            detail: "Removes the file permanently. Directories must be empty.",
            parameters: [
                ToolParam(name: "path", type: "string", description: "Path to delete, relative to the workspace root", required: true),
            ],
            permission: .write,
            isDestructive: true,
            requiresWorkspace: true
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let url = try WorkspacePathResolver.resolve(args.path, in: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Nothing exists at '\(args.path)' — already gone."
        }
        try FileManager.default.removeItem(at: url)
        return "Deleted \(args.path)."
    }
}

public struct ListDirectoryTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var path: String?
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "list_directory",
            summary: "List a directory's entries",
            detail: "Names with / for directories. Omit path for the workspace root.",
            parameters: [
                ToolParam(name: "path", type: "string", description: "Directory path, relative to the workspace root", required: false),
            ],
            permission: .read,
            requiresWorkspace: true
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let url = try WorkspacePathResolver.resolve(args.path ?? ".", in: root)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw AgentRunError.permissionDenied("No directory exists at '\(args.path ?? ".")'.")
        }
        let lines = entries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { entry -> String in
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return entry.lastPathComponent + (isDir ? "/" : "")
            }
        return lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n")
    }
}

public struct GlobFilesTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var pattern: String
        public var path: String?
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "glob_files",
            summary: "Find files by name pattern",
            detail: "Recursively matches a glob (e.g. \"Sources/**/*.swift\"). Path segments in the pattern must match real directories.",
            parameters: [
                ToolParam(name: "pattern", type: "string", description: "Glob pattern; * matches within a path segment, ** any depth", required: true),
                ToolParam(name: "path", type: "string", description: "Directory to search in; default the workspace root", required: false),
            ],
            permission: .read,
            requiresWorkspace: true
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let base = try WorkspacePathResolver.resolve(args.path ?? ".", in: root)

        // `**` in the pattern means descend; split at it and walk the fixed
        // prefix so a pattern with `**` does not need every intermediate
        // segment to match literally.
        var directory = base
        var pattern = args.pattern
        if let starRange = args.pattern.range(of: "**") {
            let prefix = String(args.pattern[..<starRange.lowerBound])
            if !prefix.isEmpty && prefix != "/" {
                directory = try WorkspacePathResolver.resolve(prefix, in: root)
            }
            pattern = String(args.pattern[starRange.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        guard let regex = PathWildcard.globRegex(pattern) else {
            throw AgentRunError.permissionDenied("Could not parse glob '\(args.pattern)'.")
        }
        var matches: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let next = enumerator?.nextObject() as? URL {
            let rel = WorkspacePathResolver.relativePath(of: next.path, under: root) ?? next.lastPathComponent
            let isDir = (try? next.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDir, regex.firstMatch(in: rel, range: NSRange(location: 0, length: (rel as NSString).length)) != nil {
                matches.append(rel)
            }
            if matches.count >= 400 { break }
        }
        return matches.isEmpty
            ? "No files matched '\(args.pattern)'."
            : matches.sorted().joined(separator: "\n")
    }
}

public struct GrepFilesTool: ToolExecuting {
    public struct Args: Decodable, Sendable {
        public var pattern: String
        public var path: String?
        public var isRegex: Bool?
    }

    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "grep_files",
            summary: "Search file contents for a pattern",
            detail: "Returns matching lines as \"path:line: text\". Plain text or regex.",
            parameters: [
                ToolParam(name: "pattern", type: "string", description: "Text or regex to search for", required: true),
                ToolParam(name: "path", type: "string", description: "Directory or file to search; default the workspace root", required: false),
                ToolParam(name: "isRegex", type: "boolean", description: "Treat the pattern as a regex", required: false),
            ],
            permission: .read,
            requiresWorkspace: true
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = try ToolArgs.decode(Args.self, from: argumentsJSON)
        let root = try WorkspacePathResolver.requireRoot(context)
        let target = try WorkspacePathResolver.resolve(args.path ?? ".", in: root)

        let regex: NSRegularExpression?
        if args.isRegex ?? false {
            regex = try? NSRegularExpression(pattern: args.pattern)
            if regex == nil {
                throw AgentRunError.permissionDenied("Could not parse regex '\(args.pattern)'.")
            }
        } else {
            regex = try? NSRegularExpression(
                pattern: NSRegularExpression.escapedTemplate(for: args.pattern)
            )
        }
        guard let regex else {
            throw AgentRunError.permissionDenied("Could not parse pattern '\(args.pattern)'.")
        }

        var files: [URL] = []
        let values = try? target.resourceValues(forKeys: [.isDirectoryKey])
        let isDir = values?.isDirectory ?? false
        if isDir {
            let enumerator = FileManager.default.enumerator(
                at: target, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            while let next = enumerator?.nextObject() as? URL {
                if !next.hasDirectoryPath { files.append(next) }
                if files.count >= 2_000 { break }
            }
        } else {
            files = [target]
        }

        var results: [String] = []
        for file in files {
            guard let name = try? String(contentsOf: file, encoding: .utf8) else { continue }
            guard !SecretRedactor.isSensitiveFilename(file.lastPathComponent) else { continue }
            let rel = WorkspacePathResolver.relativePath(of: file.path, under: root) ?? file.lastPathComponent
            for (i, line) in name.components(separatedBy: "\n").enumerated() where !line.isEmpty {
                let range = NSRange(location: 0, length: (line as NSString).length)
                if regex.firstMatch(in: line, range: range) != nil {
                    results.append("\(rel):\(i + 1): \(line.prefix(300))")
                    if results.count >= 200 { break }
                }
            }
            if results.count >= 200 { break }
        }
        if results.count >= 200 { results.append("…(result list capped at 200 lines; narrow the pattern)") }
        return results.isEmpty ? "No matches for '\(args.pattern)'." : results.joined(separator: "\n")
    }
}
