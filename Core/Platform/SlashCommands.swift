import Foundation

/// A command typed as `/name arguments` in the composer. Built-ins act on the app; custom ones are Markdown files in
/// `.kiln/commands/` (project) or `~/.kiln/commands/` (user) whose text becomes the prompt. Kiln also reads
/// `.claude/commands/` so a project set up for Claude Code works unchanged (read, never copied).
public struct SlashCommand: Identifiable, Equatable, Sendable {
    public enum Source: String, Sendable { case builtIn, project, user }
    public var id: String { "\(source.rawValue):\(name)" }
    public var name: String
    public var summary: String
    public var argumentHint: String?
    /// The prompt template of a custom command; empty for built-ins.
    public var body: String
    public var source: Source
    /// Where the file lives; nil for built-ins.
    public var path: String?
    /// A model the command asks for (frontmatter `model:`). Honoured only when that model exists; never widens permissions.
    public var model: String?
}

public enum BuiltInCommand: String, CaseIterable, Sendable {
    case compact, clear, model, memory, commands, help

    public var summary: String {
        switch self {
        case .compact: return "Summarise the conversation to free context"
        case .clear: return "Start a new conversation"
        case .model: return "Show or switch the model"
        case .memory: return "Open the memory files (KILN.md, AGENTS.md, CLAUDE.md)"
        case .commands: return "List and edit custom commands"
        case .help: return "List every command"
        }
    }
    public var argumentHint: String? {
        switch self {
        case .model: return "<model id or part of its name>"
        default: return nil
        }
    }
}

public enum SlashResolution: Equatable, Sendable {
    /// Not a slash command: send the text as written.
    case plainMessage
    /// A custom command: send this expanded text as the prompt.
    case prompt(String, command: String, model: String?)
    case builtIn(BuiltInCommand, arguments: String)
    case unknown(String)
}

public enum SlashCommands {
    /// `/name rest` → (name, rest). Nil unless the text starts with `/` followed by a name; `/usr/bin` and `//` are not commands.
    public static func parse(_ text: String) -> (name: String, arguments: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        let body = trimmed.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }) else { return nil }
        let rest = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(name), rest)
    }

    public static var builtIns: [SlashCommand] {
        BuiltInCommand.allCases.map {
            SlashCommand(name: $0.rawValue, summary: $0.summary, argumentHint: $0.argumentHint, body: "", source: .builtIn, path: nil, model: nil)
        }
    }

    /// Custom commands: user files first, then project, so a project command replaces a user one of the same name.
    public static func loadCustom(workspaceRoot: URL?, home: URL?) -> [SlashCommand] {
        var byName: [String: SlashCommand] = [:]
        var dirs: [(URL, SlashCommand.Source)] = []
        if let home {
            dirs.append((home.appendingPathComponent(".claude/commands"), .user))
            dirs.append((home.appendingPathComponent(".kiln/commands"), .user))
        }
        if let workspaceRoot {
            dirs.append((workspaceRoot.appendingPathComponent(".claude/commands"), .project))
            dirs.append((workspaceRoot.appendingPathComponent(".kiln/commands"), .project))
        }
        for (dir, source) in dirs {
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                var relative = url.resolvingSymlinksInPath().deletingPathExtension().path.replacingOccurrences(of: dir.resolvingSymlinksInPath().path + "/", with: "")
                relative = relative.replacingOccurrences(of: "/", with: ":")
                let (front, body) = Frontmatter.split(text)
                let firstLine = body.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? ""
                byName[relative] = SlashCommand(
                    name: relative,
                    summary: front["description"] ?? String(firstLine.prefix(90)),
                    argumentHint: front["argument-hint"],
                    body: body, source: source, path: url.path, model: front["model"]
                )
            }
        }
        // A custom command never shadows a built-in: `/clear` must always mean clear.
        let reserved = Set(BuiltInCommand.allCases.map(\.rawValue))
        return byName.values.filter { !reserved.contains($0.name) }.sorted { $0.name < $1.name }
    }

    public static func all(workspaceRoot: URL?, home: URL?) -> [SlashCommand] {
        builtIns + loadCustom(workspaceRoot: workspaceRoot, home: home)
    }

    /// `$ARGUMENTS` is the whole argument text, `$1`…`$9` its words. A template with no placeholder gets the arguments appended.
    public static func expand(_ command: SlashCommand, arguments: String) -> String {
        var text = command.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        var used = text.contains("$ARGUMENTS")
        text = text.replacingOccurrences(of: "$ARGUMENTS", with: arguments)
        for index in stride(from: 9, through: 1, by: -1) {
            let token = "$\(index)"
            if text.contains(token) { used = true; text = text.replacingOccurrences(of: token, with: index <= words.count ? words[index - 1] : "") }
        }
        if !used, !arguments.isEmpty { text += "\n\nARGUMENTS: \(arguments)" }
        return text
    }

    public static func resolve(_ text: String, commands: [SlashCommand]) -> SlashResolution {
        guard let (name, arguments) = parse(text) else { return .plainMessage }
        if let builtIn = BuiltInCommand(rawValue: name.lowercased()) { return .builtIn(builtIn, arguments: arguments) }
        if let custom = commands.first(where: { $0.source != .builtIn && $0.name == name }) {
            return .prompt(expand(custom, arguments: arguments), command: custom.name, model: custom.model)
        }
        return .unknown(name)
    }

    /// Commands whose name starts with what has been typed after the slash, for completion. Empty once an argument is being typed.
    public static func completions(for input: String, commands: [SlashCommand], limit: Int = 8) -> [SlashCommand] {
        guard input.hasPrefix("/"), !input.contains(where: \.isWhitespace) else { return [] }
        let prefix = input.dropFirst().lowercased()
        let matches = commands.filter { prefix.isEmpty || $0.name.lowercased().hasPrefix(prefix) }
        let rest = commands.filter { !prefix.isEmpty && !$0.name.lowercased().hasPrefix(prefix) && $0.name.lowercased().contains(prefix) }
        return Array((matches + rest).prefix(limit))
    }

    /// A new command file's text.
    public static func template(description: String) -> String {
        "---\ndescription: \(description)\nargument-hint: [what to work on]\n---\n\nDescribe what to do. Use $ARGUMENTS for what is typed after the command.\n"
    }

    /// Where a new command is written. Name is reduced to letters, digits, `-` and `_`.
    public static func fileURL(name: String, scope: SlashCommand.Source, workspaceRoot: URL?, home: URL?) -> URL? {
        let clean = String(name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        guard !clean.isEmpty, !BuiltInCommand.allCases.map(\.rawValue).contains(clean.lowercased()) else { return nil }
        switch scope {
        case .project: return workspaceRoot?.appendingPathComponent(".kiln/commands/\(clean).md")
        case .user: return home?.appendingPathComponent(".kiln/commands/\(clean).md")
        case .builtIn: return nil
        }
    }
}

/// The `---` block at the top of a Markdown file. Only flat `key: value` lines, which is all commands and skills use.
public enum Frontmatter {
    public static func split(_ text: String) -> (fields: [String: String], body: String) {
        guard text.hasPrefix("---\n") else { return ([:], text) }
        let rest = text.dropFirst(4)
        guard let end = rest.range(of: "\n---") else { return ([:], text) }
        var fields: [String: String] = [:]
        for line in rest[..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
            fields[key] = value
        }
        var body = rest[end.upperBound...]
        if body.hasPrefix("\n") { body = body.dropFirst() }
        return (fields, String(body))
    }
}
