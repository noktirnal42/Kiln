import Foundation

/// One tool call as the thread shows it: enough to group and label, without the result.
public struct ToolActivityItem: Equatable, Sendable {
    public var name: String
    public var argumentsJSON: String
    public var failed: Bool

    public init(name: String, argumentsJSON: String, failed: Bool = false) {
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.failed = failed
    }
}

/// Turns a run's tool calls into the one compact line Codex and Claude Code show: "Ran 4 commands · edited 2 files".
public enum ToolActivitySummary {
    enum Category: Int, CaseIterable {
        case command, edit, read, search, git, web, other
    }

    static func category(of tool: String) -> Category {
        switch tool {
        case "run_command", "background_command", "stream_command", "read_command_output": return .command
        case "write_file", "edit_file", "delete_file": return .edit
        case "read_file", "read_skill", "list_skills": return .read
        case "list_directory", "glob_files", "grep_files", "search_workspace": return .search
        case "web_search", "web_fetch": return .web
        default: return tool.hasPrefix("git_") ? .git : .other
        }
    }

    private static func path(of item: ToolActivityItem) -> String? {
        guard let data = item.argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["path"] as? String
    }

    private static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : (many ?? one + "s"))"
    }

    /// "Ran 4 commands · edited 2 files · read 6 files". Files are counted once however often they were touched.
    public static func line(for items: [ToolActivityItem]) -> String {
        guard !items.isEmpty else { return "" }
        var parts: [String] = []
        for category in Category.allCases {
            let group = items.filter { category(of: $0.name) == category }
            guard !group.isEmpty else { continue }
            let distinctPaths = Set(group.compactMap(path(of:)))
            let fileCount = distinctPaths.isEmpty ? group.count : max(distinctPaths.count, 1)
            switch category {
            case .command: parts.append("Ran \(plural(group.count, "command"))")
            case .edit: parts.append("edited \(plural(fileCount, "file"))")
            case .read: parts.append("read \(plural(fileCount, "file"))")
            case .search: parts.append("searched \(plural(group.count, "time"))")
            case .git: parts.append("\(plural(group.count, "git operation"))")
            case .web: parts.append("\(plural(group.count, "web lookup"))")
            case .other: parts.append("used \(plural(group.count, "other tool"))")
            }
        }
        // The first part is capitalised whichever category leads ("Ran 2 commands", "Edited 1 file").
        if let first = parts.first { parts[0] = first.prefix(1).uppercased() + first.dropFirst() }
        let failures = items.filter(\.failed).count
        if failures > 0 { parts.append("\(failures) failed") }
        return parts.joined(separator: " · ")
    }
}
