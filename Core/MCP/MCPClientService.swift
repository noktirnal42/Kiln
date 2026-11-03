import Foundation

public struct MCPServerStatus: Identifiable, Equatable, Sendable {
    public var id: String { config.id }
    public var config: MCPServerConfig
    public var approved: Bool
    public var connected: Bool
    public var toolCount: Int
    public var lastError: String?
    /// Tools (Claude Code, Codex, OpenCode) that define this server; empty for Kiln's own configuration.
    public var sources: [String]

    public init(config: MCPServerConfig, approved: Bool, connected: Bool, toolCount: Int, lastError: String? = nil, sources: [String] = []) {
        self.sources = sources
        self.config = config
        self.approved = approved
        self.connected = connected
        self.toolCount = toolCount
        self.lastError = lastError
    }
}

/// Persisted approvals for MCP servers. An approval is bound to the server's
/// command fingerprint, so editing a server's command invalidates it.
public actor MCPApprovalStore {
    private struct StoreFile: Codable {
        var approved: [String: String] = [:]
    }

    private let url: URL
    private var approved: [String: String] = [:]

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.url = appSupport.appendingPathComponent("Kiln/mcp-approvals.json")
        } else {
            self.url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-approvals.json")
        }
        if let data = try? Data(contentsOf: self.url),
           let file = try? JSONDecoder().decode(StoreFile.self, from: data) {
            approved = file.approved
        }
    }

    public func isApproved(_ config: MCPServerConfig) -> Bool {
        guard config.requiresApproval else { return true }
        return approved[config.id] == config.approvalFingerprint
    }

    public func approve(_ config: MCPServerConfig) {
        approved[config.id] = config.approvalFingerprint
        persist()
    }

    public func revoke(_ serverID: String) {
        approved.removeValue(forKey: serverID)
        persist()
    }

    private func persist() {
        let file = StoreFile(approved: approved)
        do {
            let directory = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try JSONEncoder().encode(file).write(to: url, options: .atomic)
        } catch {
            ModuleLogger(moduleIdentifier: "com.kiln.mcp")
                .error("approval persist failed: \(String(describing: error))")
        }
    }
}

/// MCP client service: discovery, approval gate, connections, and the
/// aggregated tool/resource/prompt registries. Every connect requires explicit
/// user approval unless the server itself opted out AND was previously trusted.
public actor MCPClientService {
    public static let maxStderrLines = 64

    private var configs: [String: MCPServerConfig] = [:]
    private var connections: [String: any MCPConnection] = [:]
    private var tools: [String: [MCPTool]] = [:]
    private var resources: [String: [MCPResource]] = [:]
    private var prompts: [String: [MCPPrompt]] = [:]
    private var errors: [String: String] = [:]
    private let approvals: MCPApprovalStore

    public init(approvals: MCPApprovalStore = MCPApprovalStore()) {
        self.approvals = approvals
    }

    // MARK: Discovery

    @discardableResult
    public func discoverServers(extraDirectories: [URL] = []) -> [MCPServerConfig] {
        var directories: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        directories.append(home.appendingPathComponent(".config/mcp"))
        directories.append(home.appendingPathComponent(".cursor"))
        for extra in extraDirectories {
            directories.append(extra)
        }
        for directory in directories {
            loadServerFile(directory.appendingPathComponent("servers.json"))
        }
        // Servers already configured for Claude Code, Codex and OpenCode, merged so each appears once.
        // Anything with the same command line as a server loaded above is skipped, not duplicated.
        let known = Set(configs.values.map { ToolSourceImporter.identity(of: $0) })
        let hidden = hiddenServerIDs
        for imported in ToolSourceImporter.importServers(home: home) where !known.contains(ToolSourceImporter.identity(of: imported.config)) {
            guard configs[imported.config.id] == nil, !hidden.contains(imported.config.id) else { continue }
            configs[imported.config.id] = imported.config
            importedFrom[imported.config.id] = imported.sources
        }
        return Array(configs.values).sorted { $0.id < $1.id }
    }

    /// Imported servers the user chose not to see; kept across launches.
    public var hiddenServerIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "mcp.hiddenServers") ?? [])
    }

    public func hideServer(_ id: String) {
        var hidden = hiddenServerIDs
        hidden.insert(id)
        UserDefaults.standard.set(Array(hidden).sorted(), forKey: "mcp.hiddenServers")
        configs.removeValue(forKey: id)
        connections.removeValue(forKey: id)
        importedFrom.removeValue(forKey: id)
    }

    public func unhideAllServers() {
        UserDefaults.standard.removeObject(forKey: "mcp.hiddenServers")
    }

    /// Which tools (Claude Code, Codex, OpenCode) define each imported server.
    public private(set) var importedFrom: [String: [String]] = [:]

    public func loadProjectFile(at url: URL) -> [MCPServerConfig] {
        loadServerFile(url)
        return Array(configs.values).sorted { $0.id < $1.id }
    }

    private func loadServerFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        // Two accepted shapes: {"mcpServers": {id: {...}}} and {id: {...}}.
        let object: [String: ProviderJSON]?
        if let envelope = try? JSONDecoder().decode(ProviderJSON.self, from: data),
           case .object(let root) = envelope.value {
            if let servers = root["mcpServers"]?.objectValue {
                object = servers
            } else {
                object = root
            }
        } else {
            object = nil
        }
        guard let object else { return }
        for (id, entry) in object {
            guard case .object(let fields) = entry.value else { continue }
            guard configs[id] == nil else { continue }
            var command = ""
            var arguments: [String] = []
            var transport = MCPTransport.stdio
            if let type = fields["type"]?.stringValue {
                if type == "http" || type == "sse" {
                    transport = .http
                } else if type == "websocket" || type == "ws" {
                    transport = .websocket
                }
            }
            if let value = fields["command"]?.stringValue {
                command = value
            } else if let value = fields["url"]?.stringValue {
                command = value
                transport = transport == .stdio ? .http : transport
            }
            if let args = fields["args"], case .array(let entries) = args.value {
                arguments = entries.compactMap { $0.stringValue }
            }
            var environment: [String: String] = [:]
            if let env = fields["env"], case .object(let pairs) = env.value {
                for (key, value) in pairs {
                    if let stringValue = value.stringValue { environment[key] = stringValue }
                }
            }
            guard !command.isEmpty else { continue }
            configs[id] = MCPServerConfig(
                id: id,
                name: id,
                transport: transport,
                command: command,
                arguments: arguments,
                environment: environment
            )
        }
    }

    public func addServer(_ config: MCPServerConfig) {
        configs[config.id] = config
    }

    public func removeServer(_ serverID: String) {
        configs.removeValue(forKey: serverID)
        connections.removeValue(forKey: serverID)
        tools.removeValue(forKey: serverID)
        resources.removeValue(forKey: serverID)
        prompts.removeValue(forKey: serverID)
        errors.removeValue(forKey: serverID)
    }

    // MARK: Approval gate

    public func approvalStatus(_ config: MCPServerConfig) async -> Bool {
        await approvals.isApproved(config)
    }

    public func approve(_ config: MCPServerConfig) async {
        await approvals.approve(config)
    }

    public func revokeApproval(serverID: String) async {
        await approvals.revoke(serverID)
    }

    // MARK: Connections

    public func connect(_ serverID: String) async throws {
        guard let config = configs[serverID] else {
            throw MCPError.serverNotConnected(serverID)
        }
        guard await approvals.isApproved(config) else {
            throw MCPError.approvalRequired(serverID: serverID)
        }
        if connections[serverID] != nil { return }
        let connection: any MCPConnection
        switch config.transport {
        case .stdio:
            connection = StdioMCPConnection(config: config)
        case .http:
            connection = HTTPMCPConnection(config: config)
        case .websocket:
            connection = WebSocketMCPConnection(config: config)
        }
        do {
            try await connection.connect()
            connections[serverID] = connection
            errors.removeValue(forKey: serverID)
            try await refreshRegistries(for: serverID)
        } catch {
            errors[serverID] = String(describing: error)
            throw error
        }
    }

    public func disconnect(_ serverID: String) async {
        if let connection = connections[serverID] {
            await connection.disconnect()
        }
        connections.removeValue(forKey: serverID)
        tools.removeValue(forKey: serverID)
        resources.removeValue(forKey: serverID)
        prompts.removeValue(forKey: serverID)
    }

    public func disconnectAll() async {
        for serverID in Array(connections.keys) {
            await disconnect(serverID)
        }
    }

    private func refreshRegistries(for serverID: String) async throws {
        guard let connection = connections[serverID] else { return }
        let toolsResult = try? await connection.request(method: "tools/list", params: [:], timeout: 30)
        if let toolsResult, let array = toolsResult["tools"], case .array(let entries) = array.value {
            tools[serverID] = entries.compactMap { entry -> MCPTool? in
                guard case .object(let fields) = entry.value,
                      let name = fields["name"]?.stringValue else { return nil }
                let description = fields["description"]?.stringValue ?? ""
                var schema: [String: ProviderJSON] = [:]
                if let inputSchema = fields["inputSchema"], case .object(let pairs) = inputSchema.value {
                    schema = pairs
                }
                return MCPTool(serverID: serverID, name: name, description: description, inputSchema: schema)
            }
        }
        let resourcesResult = try? await connection.request(method: "resources/list", params: [:], timeout: 30)
        if let resourcesResult, let array = resourcesResult["resources"], case .array(let entries) = array.value {
            resources[serverID] = entries.compactMap { entry -> MCPResource? in
                guard case .object(let fields) = entry.value,
                      let uri = fields["uri"]?.stringValue else { return nil }
                return MCPResource(
                    serverID: serverID,
                    uri: uri,
                    name: fields["name"]?.stringValue ?? uri,
                    description: fields["description"]?.stringValue ?? ""
                )
            }
        }
        let promptsResult = try? await connection.request(method: "prompts/list", params: [:], timeout: 30)
        if let promptsResult, let array = promptsResult["prompts"], case .array(let entries) = array.value {
            prompts[serverID] = entries.compactMap { entry -> MCPPrompt? in
                guard case .object(let fields) = entry.value,
                      let name = fields["name"]?.stringValue else { return nil }
                return MCPPrompt(
                    serverID: serverID,
                    name: name,
                    description: fields["description"]?.stringValue ?? ""
                )
            }
        }
    }

    // MARK: Registries

    public func statuses() async -> [MCPServerStatus] {
        var result: [MCPServerStatus] = []
        for config in configs.values.sorted(by: { $0.id < $1.id }) {
            let approved = await approvals.isApproved(config)
            result.append(MCPServerStatus(
                config: config,
                approved: approved,
                connected: connections[config.id] != nil,
                toolCount: tools[config.id]?.count ?? 0,
                lastError: errors[config.id],
                sources: importedFrom[config.id] ?? []
            ))
        }
        return result
    }

    public func allTools() -> [MCPTool] {
        tools.values.flatMap { $0 }.sorted { $0.id < $1.id }
    }

    public func allResources() -> [MCPResource] {
        resources.values.flatMap { $0 }.sorted { $0.id < $1.id }
    }

    public func allPrompts() -> [MCPPrompt] {
        prompts.values.flatMap { $0 }.sorted { $0.id < $1.id }
    }

    @discardableResult
    public func callTool(qualifiedName: String, arguments: [String: ProviderJSON]) async throws -> MCPToolResult {
        guard let separator = qualifiedName.firstIndex(of: ":") else {
            throw MCPError.toolNotFound(serverID: "?", name: qualifiedName)
        }
        let serverID = String(qualifiedName[..<separator])
        let toolName = String(qualifiedName[qualifiedName.index(after: separator)...])
        guard let connection = connections[serverID] else {
            throw MCPError.serverNotConnected(serverID)
        }
        guard tools[serverID]?.contains(where: { $0.name == toolName }) == true else {
            throw MCPError.toolNotFound(serverID: serverID, name: toolName)
        }
        let result = try await connection.request(
            method: "tools/call",
            params: ["name": ProviderJSON(toolName), "arguments": ProviderJSON(arguments)],
            timeout: 60
        )
        var text = ""
        var isError = false
        if let content = result["content"], case .array(let entries) = content.value {
            for entry in entries {
                guard case .object(let fields) = entry.value else { continue }
                if fields["type"]?.stringValue == "text", let value = fields["text"]?.stringValue {
                    if !text.isEmpty { text += "\n" }
                    text += value
                }
            }
        }
        if let flag = result["isError"], case .bool(let value) = flag.value, value {
            isError = true
        }
        return MCPToolResult(text: text, isError: isError)
    }
}
