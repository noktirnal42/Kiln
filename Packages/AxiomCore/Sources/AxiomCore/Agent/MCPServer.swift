import Foundation

/// MCP (2025-06-18) server core, transport-independent: feed it one JSON-RPC line at a time, it answers through `send`.
///
/// - `tools/call` runs on a concurrent queue so a long operation never blocks `ping`, `tools/list` or another call;
/// - every call gets an operation id (returned in the result's `_meta` and in the audit log);
/// - `notifications/cancelled` (and the `cancel_operation` tool) stop the operation: its engine processes are terminated and,
///   per the MCP spec, no response is sent for a cancelled request;
/// - a client `_meta.progressToken` receives throttled `notifications/progress`;
/// - closing the input (`shutdown`) cancels everything still running.
public final class MCPServer: @unchecked Sendable {
    public struct Options: Sendable {
        public var proposeOnly = false
        public var transport = "mcp"
        public var audit: AuditLog? = AuditLog.shared
        public var registry: OperationRegistry = .shared
        public init(proposeOnly: Bool = false, transport: String = "mcp", audit: AuditLog? = AuditLog.shared, registry: OperationRegistry = .shared) {
            self.proposeOnly = proposeOnly; self.transport = transport; self.audit = audit; self.registry = registry
        }
    }

    public static let supportedVersions = ["2025-06-18", "2024-11-05"]
    private let options: Options
    private let send: @Sendable ([String: Any]) -> Void
    private let lock = NSLock()
    private var initialized = false
    private var client: String?
    private var inflight: [String: OperationContext] = [:]   // request id (type-tagged) -> operation
    private let queue = DispatchQueue(label: "axiom.mcp.tools", qos: .userInitiated, attributes: .concurrent)
    private let group = DispatchGroup()

    public init(options: Options = Options(), send: @escaping @Sendable ([String: Any]) -> Void) { self.options = options; self.send = send }

    private static func key(_ id: Any) -> String { (id is String ? "s:" : "n:") + String(describing: id) }
    private func error(_ id: Any?, _ code: Int, _ message: String) { send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]) }

    /// Handles one incoming line. Returns immediately; tool calls complete asynchronously.
    public func handle(line: String) {
        guard line.utf8.count <= 1_048_576 else { return error(nil, -32600, "Request exceeds 1 MiB.") }
        guard let data = line.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { return error(nil, -32700, "Invalid JSON.") }
        guard let request = value as? [String: Any], request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else { return error(nil, -32600, "Invalid JSON-RPC request.") }
        let params = request["params"] as? [String: Any] ?? [:]
        guard let id = request["id"] else { notification(method, params); return }
        switch method {
        case "initialize":
            guard let requested = params["protocolVersion"] as? String, !requested.isEmpty else { return error(id, -32602, "initialize requires a protocolVersion string.") }
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            let info = params["clientInfo"] as? [String: Any]
            lock.lock(); initialized = true
            if let name = info?["name"] as? String { client = name + ((info?["version"] as? String).map { "/" + $0 } ?? "") }
            lock.unlock()
            send(["jsonrpc": "2.0", "id": id, "result": ["protocolVersion": version, "capabilities": ["tools": [:]], "serverInfo": ["name": "axiom-re", "version": "0.1.0"]]])
        case "ping": send(["jsonrpc": "2.0", "id": id, "result": [:]])
        case "tools/list":
            guard isInitialized else { return error(id, -32601, "Initialize the MCP session first.") }
            let tools = AgentTools.definitions.map { name, description, fields, required -> [String: Any] in
                ["name": name, "description": description, "inputSchema": ["type": "object", "properties": fields.mapValues { ["type": $0] }, "required": required, "additionalProperties": false],
                 "annotations": ["readOnlyHint": AgentTools.isReadOnly(name), "destructiveHint": false, "openWorldHint": false]]
            }
            send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
        case "tools/call":
            guard isInitialized else { return error(id, -32601, "Initialize the MCP session first.") }
            callTool(id: id, params: params)
        default: error(id, -32601, isInitialized ? "Method not found." : "Initialize the MCP session first.")
        }
    }

    private var isInitialized: Bool { lock.lock(); defer { lock.unlock() }; return initialized }

    private func notification(_ method: String, _ params: [String: Any]) {
        if method == "notifications/cancelled", let requestId = params["requestId"] {
            lock.lock(); let context = inflight[Self.key(requestId)]; lock.unlock()
            context?.cancel(reason: (params["reason"] as? String) ?? "cancelled by client")
        }
    }

    private func callTool(id: Any, params: [String: Any]) {
        guard let name = params["name"] as? String, !name.isEmpty else { return error(id, -32602, "tools/call requires a tool name.") }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let token = (params["_meta"] as? [String: Any])?["progressToken"]
        let throttle = ProgressThrottle()
        let send = self.send
        let context = OperationContext(tool: name, transport: options.transport, progress: token.map { token in
            { @Sendable fraction, message in
                guard throttle.allow(fraction) else { return }
                var p: [String: Any] = ["progressToken": token, "progress": fraction, "total": 1.0]
                if let message { p["message"] = message }
                send(["jsonrpc": "2.0", "method": "notifications/progress", "params": p])
            }
        })
        lock.lock(); inflight[Self.key(id)] = context; let clientName = client; lock.unlock()
        let options = self.options
        group.enter()
        queue.async { [self] in
            defer { group.leave() }
            let outcome = AgentRuntime.execute(tool: name, arguments: arguments, context: context, client: clientName, policy: .init(proposeOnly: options.proposeOnly), audit: options.audit, registry: options.registry)
            lock.lock(); inflight[Self.key(id)] = nil; lock.unlock()
            // MCP: a cancelled request gets no response (the client has already moved on).
            guard !outcome.cancelled else { return }
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": outcome.text]], "isError": outcome.isError, "_meta": ["axiom/operationId": outcome.operationId]]])
        }
    }

    /// Ends the session. In-flight calls get `grace` seconds to finish normally (so a batch piped into `axiom mcp` still receives every answer);
    /// anything still running after that is cancelled, its engine processes terminated, and the workers awaited.
    public func shutdown(grace: TimeInterval = 0, timeout: TimeInterval = 10) {
        if grace > 0, group.wait(timeout: .now() + grace) == .success { return }
        lock.lock(); let all = Array(inflight.values); lock.unlock()
        for context in all { context.cancel(reason: "session closed") }
        _ = group.wait(timeout: .now() + timeout)
    }

    /// Waits for in-flight calls to finish without cancelling them (tests, orderly drain).
    public func waitUntilIdle(timeout: TimeInterval = 10) { _ = group.wait(timeout: .now() + timeout) }
}

/// At most about ten progress notifications a second (and always a final 100%).
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock(); private var last = Date.distantPast
    func allow(_ fraction: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard fraction >= 1 || now.timeIntervalSince(last) >= 0.1 else { return false }
        last = now; return true
    }
}
