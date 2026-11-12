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
        for kind in Category.allCases {
            let group = items.filter { category(of: $0.name) == kind }
            guard !group.isEmpty else { continue }
            let distinctPaths = Set(group.compactMap(path(of:)))
            let fileCount = distinctPaths.isEmpty ? group.count : max(distinctPaths.count, 1)
            switch kind {
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
        // As a sentence, the way Claude Code writes it: "Ran 4 commands, edited 2 files and read 6 files".
        guard parts.count > 1, let last = parts.last else { return parts.joined() }
        return parts.dropLast().joined(separator: ", ") + (failures > 0 ? ", " : " and ") + last
    }
}

/// How a finished run's collapsed line reads: Claude Code's sentence, or Codex's "Worked for 42s".
public enum ToolSummaryStyle: String, CaseIterable, Identifiable, Sendable {
    case sentence, worked
    public static let defaultsKey = "chat.toolSummaryStyle"
    public var id: String { rawValue }
    public var label: String { self == .sentence ? "What it did" : "How long it worked" }

    /// "42s", "1m 26s", "1h 05m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
    }

    /// The line for a run of `items` that took `seconds` (unknown when nil). The sentence is the fallback when no duration is known.
    public func line(for items: [ToolActivityItem], seconds: TimeInterval?) -> String {
        let sentence = ToolActivitySummary.line(for: items)
        guard self == .worked, let seconds, seconds >= 1 else { return sentence }
        let failures = items.filter(\.failed).count
        return "Worked for \(Self.duration(seconds))" + (failures > 0 ? " · \(failures) failed" : "")
    }
}

/// How one tool call reads in the thread: a verb and what it acted on ("Ran" `swift test`), and the live status line text.
public enum ToolPhrase {
    public struct Title: Equatable, Sendable {
        public var verb: String
        public var object: String
    }

    static func argument(_ json: String, _ keys: [String]) -> String? {
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in keys { if let value = object[key] as? String, !value.isEmpty { return value.replacingOccurrences(of: "\n", with: " ") } }
        return nil
    }

    private static func short(_ path: String) -> String { (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent }

    /// "Ran" + `swift test`, "Edited" + `Pagination.swift`, "Read" + ... Unknown tools read as "Used" + the tool name.
    public static func title(name: String, argumentsJSON json: String) -> Title {
        let path = argument(json, ["path", "file", "file_path"])
        switch name {
        case "run_command", "background_command", "stream_command": return Title(verb: "Ran", object: argument(json, ["command"]) ?? "a command")
        case "read_command_output": return Title(verb: "Read", object: "command output")
        case "read_file": return Title(verb: "Read", object: path.map(short) ?? "a file")
        case "write_file": return Title(verb: "Wrote", object: path.map(short) ?? "a file")
        case "edit_file": return Title(verb: "Edited", object: path.map(short) ?? "a file")
        case "delete_file": return Title(verb: "Deleted", object: path.map(short) ?? "a file")
        case "list_directory": return Title(verb: "Listed", object: path.map(short) ?? "a folder")
        case "glob_files", "grep_files", "search_workspace": return Title(verb: "Searched for", object: argument(json, ["pattern", "query"]) ?? "files")
        case "web_search": return Title(verb: "Searched the web for", object: argument(json, ["query"]) ?? "something")
        case "web_fetch": return Title(verb: "Fetched", object: argument(json, ["url"]).map { URL(string: $0)?.host ?? $0 } ?? "a page")
        case "read_skill", "list_skills": return Title(verb: "Read", object: argument(json, ["name"]) ?? "a skill")
        case "kiln_todo_write": return Title(verb: "Updated", object: "the task list")
        case "mcp_call_tool": return Title(verb: "Called", object: argument(json, ["tool", "name"]) ?? "an MCP tool")
        case "computer_use": return Title(verb: "Used", object: "an app on your computer")
        default:
            if name.hasPrefix("git_") { return Title(verb: "Ran git", object: String(name.dropFirst(4)).replacingOccurrences(of: "_", with: " ")) }
            return Title(verb: "Used", object: name)
        }
    }

    /// The one line shown while a step is running: "Running swift test", "Waiting for your approval to edit a.swift".
    public static func liveStatus(name: String, argumentsJSON json: String, awaitingApproval: Bool = false) -> String {
        let t = title(name: name, argumentsJSON: json)
        let progressive: [String: String] = ["Ran": "Running", "Read": "Reading", "Wrote": "Writing", "Edited": "Editing", "Deleted": "Deleting",
                                             "Listed": "Listing", "Searched for": "Searching for", "Searched the web for": "Searching the web for",
                                             "Fetched": "Fetching", "Updated": "Updating", "Called": "Calling", "Used": "Using", "Ran git": "Running git"]
        let phrase = (progressive[t.verb] ?? t.verb) + " " + t.object
        return awaitingApproval ? "Waiting for your approval: " + phrase.prefix(1).lowercased() + phrase.dropFirst() : phrase
    }

    /// True when a reply is nothing but JSON that looks like a tool call: a model wrote the call as text instead of making it.
    public static func looksLikeToolCallText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("```") else { return false }
        return trimmed.contains("\"arguments\"") && trimmed.contains("\"name\"")
    }
}
