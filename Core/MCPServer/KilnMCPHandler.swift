import Foundation

/// Kiln as an MCP server: external agents list and call Kiln's tools over JSON-RPC.
///
/// This type is the protocol only (no sockets), so it can be tested directly. Every `tools/call`
/// goes through `AgentOrchestrator.callTool`, so an outside agent gets the same policy, approval,
/// monitor and audit treatment as Kiln's own agent. It can never reach a tool the profile hides.
public struct KilnMCPHandler: Sendable {
    public static let protocolVersion = "2025-03-26"

    let orchestrator: AgentOrchestrator
    let registry: ToolRegistry
    let workspaceRoot: @Sendable () -> URL?

    public init(orchestrator: AgentOrchestrator, registry: ToolRegistry = .shared,
                workspaceRoot: @escaping @Sendable () -> URL? = { nil }) {
        self.orchestrator = orchestrator
        self.registry = registry
        self.workspaceRoot = workspaceRoot
    }

    /// The identity external calls run under: reads are automatic, anything else asks the human.
    func profile(client: String) -> AgentProfile {
        AgentProfile(
            name: "External: \(client)",
            iconSymbol: "network",
            mode: .act,
            toolPermissions: ToolPermissionSet(
                enabledTools: Set(registry.allSpecs().map(\.name)),
                policyByLevel: ToolPermissionSet.conservativeDefaults
            ),
            redactSecrets: true
        )
    }

    /// Handles one JSON-RPC message. Returns nil for notifications, which get no reply.
    public func handle(_ body: Data, client: String = "mcp-client") async -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let method = object["method"] as? String else {
            return Self.error(id: nil, code: -32700, message: "Parse error")
        }
        guard let id = object["id"] else { return nil }
        let params = object["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return Self.result(id: id, [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "kiln", "version": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")],
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": registry.allSpecs().map(Self.describe)])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Self.error(id: id, code: -32602, message: "Missing tool name")
            }
            guard registry.tool(named: name) != nil else {
                return Self.error(id: id, code: -32602, message: "Unknown tool '\(name)'")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let json = (try? JSONSerialization.data(withJSONObject: arguments))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let record = await orchestrator.callTool(
                ToolCall(id: "mcp_\(UUID().uuidString)", name: name, arguments: json),
                profile: profile(client: client),
                workspaceRoot: workspaceRoot()
            )
            let ok = record.status == .succeeded
            let text = ok ? (record.resultText ?? "") : (record.errorText ?? "The call did not complete.")
            return Self.result(id: id, ["content": [["type": "text", "text": text]], "isError": !ok])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: Encoding

    static func describe(_ spec: ToolSpec) -> [String: Any] {
        var properties: [String: Any] = [:]
        for param in spec.parameters {
            var schema: [String: Any] = ["type": param.type]
            if !param.description.isEmpty { schema["description"] = param.description }
            properties[param.name] = schema
        }
        return [
            "name": spec.name,
            "description": spec.detail.isEmpty ? spec.summary : spec.summary + " — " + spec.detail,
            "inputSchema": [
                "type": "object", "properties": properties,
                "required": spec.parameters.filter(\.required).map(\.name),
            ] as [String: Any],
            "annotations": ["readOnlyHint": spec.permission == .read, "destructiveHint": spec.isDestructive],
        ]
    }

    static func result(id: Any, _ result: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: Any?, code: Int, message: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message],
        ] as [String: Any])
    }
}
