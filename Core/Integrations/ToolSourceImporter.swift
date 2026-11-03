import Foundation

/// Reads the MCP servers other tools on this Mac already know about (Claude Code, Codex, OpenCode) so Kiln does not
/// need a fourth copy of the same list. Nothing is written anywhere: definitions are parsed at launch, merged by what
/// they would actually run, and handed to `MCPClientService`, which still asks for approval before starting any of them.
/// Environment values (often API keys) stay in memory and are never displayed or persisted by Kiln.
public enum ToolSourceImporter {
    public struct ImportedServer: Equatable, Sendable {
        public var config: MCPServerConfig
        /// Every tool that defines this server, in priority order.
        public var sources: [String]
    }

    /// Priority decides whose name and environment win when several tools define the same server.
    public static let sourceOrder = ["Claude Code", "Codex", "OpenCode"]

    public static func importServers(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ImportedServer] {
        var found: [(source: String, config: MCPServerConfig)] = []
        found += claudeServers(home: home).map { ("Claude Code", $0) }
        found += codexServers(home: home).map { ("Codex", $0) }
        found += openCodeServers(home: home).map { ("OpenCode", $0) }
        return merge(found)
    }

    // MARK: Merge

    /// Servers that launch the same thing are one server, however each tool names it.
    public static func merge(_ entries: [(source: String, config: MCPServerConfig)]) -> [ImportedServer] {
        var byKey: [String: Int] = [:]
        var merged: [ImportedServer] = []
        var usedIDs = Set<String>()
        for entry in entries {
            let key = identity(of: entry.config)
            if let index = byKey[key] {
                if !merged[index].sources.contains(entry.source) { merged[index].sources.append(entry.source) }
                for (name, value) in entry.config.environment where merged[index].config.environment[name] == nil {
                    merged[index].config.environment[name] = value
                }
                for (name, value) in entry.config.headers where merged[index].config.headers[name] == nil {
                    merged[index].config.headers[name] = value
                }
                continue
            }
            var config = entry.config
            // Same name, different command: keep both, disambiguated, rather than silently dropping one.
            if usedIDs.contains(config.id) {
                config.id = "\(config.id)-\(entry.source.lowercased().replacingOccurrences(of: " ", with: "-"))"
                config.name = config.id
            }
            usedIDs.insert(config.id)
            byKey[key] = merged.count
            merged.append(ImportedServer(config: config, sources: [entry.source]))
        }
        return merged.sorted { $0.config.id < $1.config.id }
    }

    static func identity(of config: MCPServerConfig) -> String {
        switch config.transport {
        case .stdio:
            let executable = (config.command as NSString).lastPathComponent
            return (["stdio", executable] + config.arguments).joined(separator: "\u{1}")
        default:
            var url = config.command.trimmingCharacters(in: .whitespaces).lowercased()
            while url.hasSuffix("/") { url.removeLast() }
            return "\(config.transport.rawValue)\u{1}\(url)"
        }
    }

    // MARK: Claude Code

    static func claudeServers(home: URL) -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted().compactMap { name in
            guard let fields = servers[name] as? [String: Any] else { return nil }
            return config(name: name, fields: fields, commandIsArray: false)
        }
    }

    // MARK: OpenCode

    static func openCodeServers(home: URL) -> [MCPServerConfig] {
        let url = home.appendingPathComponent(".config/opencode/opencode.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let mcp = root["mcp"] as? [String: Any] else { return [] }
        let servers = (mcp["servers"] as? [String: Any]) ?? mcp
        return servers.keys.sorted().compactMap { name in
            guard let fields = servers[name] as? [String: Any] else { return nil }
            if fields["enabled"] as? Bool == false { return nil }
            return config(name: name, fields: fields, commandIsArray: true)
        }
    }

    /// Shared JSON shape: `command` is a string (+ `args`) or an array whose first element is the executable;
    /// remote servers have `url`; environment is `env` or `environment`.
    static func config(name: String, fields: [String: Any], commandIsArray: Bool) -> MCPServerConfig? {
        var command = ""
        var arguments: [String] = []
        var transport = MCPTransport.stdio
        if let list = fields["command"] as? [String], let first = list.first {
            command = first
            arguments = Array(list.dropFirst())
        } else if let value = fields["command"] as? String {
            command = value
        } else if let value = fields["url"] as? String {
            command = value
            transport = .http
        }
        if let extra = fields["args"] as? [String] { arguments += extra }
        let type = (fields["type"] as? String)?.lowercased()
        if type == "websocket" || type == "ws" { transport = .websocket }
        else if type == "http" || type == "sse" || type == "remote" || type == "streamable-http" { transport = .http }
        guard !command.isEmpty else { return nil }
        var environment: [String: String] = [:]
        for key in ["env", "environment"] {
            for (name, value) in (fields[key] as? [String: Any]) ?? [:] {
                if let text = value as? String { environment[name] = text }
            }
        }
        var headers: [String: String] = [:]
        for (name, value) in (fields["headers"] as? [String: Any]) ?? [:] {
            if let text = value as? String { headers[name] = text }
        }
        return MCPServerConfig(id: name, name: name, transport: transport, command: command,
                               arguments: arguments, environment: environment, headers: headers)
    }

    // MARK: Codex (TOML)

    static func codexServers(home: URL) -> [MCPServerConfig] {
        guard let text = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) else { return [] }
        return parseCodexTOML(text)
    }

    /// Just enough TOML for `[mcp_servers.NAME]` tables: string values, string arrays (possibly spanning lines),
    /// booleans, and the `[mcp_servers.NAME.env]` sub-table.
    static func parseCodexTOML(_ text: String) -> [MCPServerConfig] {
        struct Draft { var fields: [String: Any] = [:]; var env: [String: String] = [:] }
        var drafts: [String: Draft] = [:]
        var order: [String] = []
        var current: (name: String, isEnv: Bool)?
        var pending: (key: String, buffer: String)?

        func parseValue(_ raw: String) -> Any? {
            let value = raw.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("[") {
                let inner = value.dropFirst().dropLast()
                return inner.split(separator: ",").compactMap { piece -> String? in
                    let item = piece.trimmingCharacters(in: .whitespaces)
                    guard item.count >= 2, let q = item.first, q == "\"" || q == "'" else { return nil }
                    return String(item.dropFirst().dropLast())
                }
            }
            if value == "true" { return true }
            if value == "false" { return false }
            if let q = value.first, q == "\"" || q == "'", value.count >= 2, value.last == q {
                return String(value.dropFirst().dropLast())
            }
            return nil
        }

        func assign(_ key: String, _ raw: String) {
            guard let current, let value = parseValue(raw) else { return }
            if current.isEnv {
                if let text = value as? String { drafts[current.name, default: Draft()].env[key] = text }
            } else {
                drafts[current.name, default: Draft()].fields[key] = value
            }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if pending == nil, let hash = line.firstIndex(of: "#"), !line[..<hash].contains("\"") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if var open = pending {
                open.buffer += " " + line
                if line.contains("]") { assign(open.key, open.buffer); pending = nil } else { pending = open }
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let header = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                let parts = header.split(separator: ".", omittingEmptySubsequences: true).map {
                    String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                }
                if parts.count >= 2, parts[0] == "mcp_servers" {
                    let name = parts[1]
                    current = (name, parts.count >= 3 && parts[2] == "env")
                    if drafts[name] == nil { drafts[name] = Draft(); order.append(name) }
                } else {
                    current = nil
                }
                continue
            }
            guard current != nil, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            let value = String(line[line.index(after: equals)...])
            if value.trimmingCharacters(in: .whitespaces).hasPrefix("["), !value.contains("]") {
                pending = (key, value)
            } else {
                assign(key, value)
            }
        }
        return order.compactMap { name in
            guard let draft = drafts[name], draft.fields["enabled"] as? Bool != false else { return nil }
            var fields = draft.fields
            fields["env"] = draft.env
            return config(name: name, fields: fields, commandIsArray: false)
        }
    }
}
