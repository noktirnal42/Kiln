import Foundation

public enum MCPTransport: String, Codable, Sendable, CaseIterable {
    case stdio
    case http
    case websocket

    public var displayName: String {
        switch self {
        case .stdio: return "stdio (subprocess)"
        case .http: return "HTTP"
        case .websocket: return "WebSocket"
        }
    }
}

public struct MCPServerConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var transport: MCPTransport
    /// stdio: executable path (argv[0]). http/ws: endpoint URL.
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var headers: [String: String]
    public var requiresApproval: Bool

    public init(
        id: String,
        name: String? = nil,
        transport: MCPTransport,
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        headers: [String: String] = [:],
        requiresApproval: Bool = true
    ) {
        self.id = id
        self.name = name ?? id
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.headers = headers
        self.requiresApproval = requiresApproval
    }

    /// Stable fingerprint of what will actually be launched/connected, so a
    /// persisted approval cannot silently apply to a changed command line.
    public var approvalFingerprint: String {
        let parts = [transport.rawValue, command, arguments.joined(separator: " ")]
        return KeychainService.fingerprint(of: parts.joined(separator: "\n"))
    }
}

public struct MCPTool: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(serverID):\(name)" }
    public var serverID: String
    public var name: String
    public var description: String
    public var inputSchema: [String: ProviderJSON]

    public init(serverID: String, name: String, description: String = "", inputSchema: [String: ProviderJSON] = [:]) {
        self.serverID = serverID
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPResource: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(serverID):\(uri)" }
    public var serverID: String
    public var uri: String
    public var name: String
    public var description: String

    public init(serverID: String, uri: String, name: String, description: String = "") {
        self.serverID = serverID
        self.uri = uri
        self.name = name
        self.description = description
    }
}

public struct MCPPrompt: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(serverID):\(name)" }
    public var serverID: String
    public var name: String
    public var description: String

    public init(serverID: String, name: String, description: String = "") {
        self.serverID = serverID
        self.name = name
        self.description = description
    }
}

public struct MCPToolResult: Equatable, Sendable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

public enum MCPError: Error, Equatable, Sendable {
    case approvalRequired(serverID: String)
    case transportFailed(String)
    case protocolError(String)
    case requestFailed(method: String, detail: String)
    case serverNotConnected(String)
    case toolNotFound(serverID: String, name: String)
    case launchFailed(String)
    case timeout(method: String)
}

public enum MCPJSONRPC {
    public static let protocolVersion = "2024-11-05"
    public static let clientName = "SuperMetaApp"
    public static let clientVersion = "0.1.0"

    public static func request(id: Int, method: String, params: [String: ProviderJSON] = [:]) -> Data? {
        var payload: [String: ProviderJSON] = [
            "jsonrpc": ProviderJSON("2.0"),
            "id": ProviderJSON(id),
            "method": ProviderJSON(method),
        ]
        if !params.isEmpty {
            payload["params"] = ProviderJSON(params)
        }
        return unescapedSlashes(try? JSONEncoder().encode(ProviderJSON(payload)))
    }

    public static func notification(method: String, params: [String: ProviderJSON] = [:]) -> Data? {
        var payload: [String: ProviderJSON] = [
            "jsonrpc": ProviderJSON("2.0"),
            "method": ProviderJSON(method),
        ]
        if !params.isEmpty {
            payload["params"] = ProviderJSON(params)
        }
        return unescapedSlashes(try? JSONEncoder().encode(ProviderJSON(payload)))
    }

    /// JSONEncoder escapes "/" as "\/"; that is valid JSON but needlessly
    /// breaks line-based servers. Normalize to plain "/".
    static func unescapedSlashes(_ data: Data?) -> Data? {
        guard var text = data.flatMap({ String(data: $0, encoding: .utf8) }) else { return data }
        text = text.replacingOccurrences(of: "\\/", with: "/")
        return Data(text.utf8)
    }

    /// Decodes a newline-delimited JSON-RPC message into its parts.
    public static func decode(_ data: Data) -> (id: Int?, method: String?, result: [String: ProviderJSON]?, error: (code: Int, message: String)?)? {
        guard let envelope = try? JSONDecoder().decode(ProviderJSON.self, from: data), case .object(let object) = envelope.value else {
            return nil
        }
        var id: Int?
        if let rawID = object["id"] {
            if case .int(let value) = rawID.value { id = value }
            if case .double(let value) = rawID.value { id = Int(value) }
        }
        var method: String?
        if let rawMethod = object["method"] { method = rawMethod.stringValue }
        var result: [String: ProviderJSON]?
        if let rawResult = object["result"] { result = rawResult.objectValue }
        var error: (code: Int, message: String)?
        if let rawError = object["error"], let fields = rawError.objectValue {
            var code = 0
            var message = ""
            if let rawCode = fields["code"], case .int(let c) = rawCode.value { code = c }
            if let rawMessage = fields["message"], case .string(let m) = rawMessage.value { message = m }
            error = (code, message)
        }
        return (id, method, result, error)
    }
}
