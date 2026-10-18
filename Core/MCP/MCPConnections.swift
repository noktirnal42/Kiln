import Foundation

/// One connected MCP server over a specific transport. Sends newline-delimited
/// JSON-RPC (stdio) or JSON POST frames (http/ws) and correlates responses by
/// id. Actor-isolated per connection.
public protocol MCPConnection: Sendable {
    var serverID: String { get }
    func connect() async throws
    func disconnect() async
    func request(method: String, params: [String: ProviderJSON], timeout: TimeInterval) async throws -> [String: ProviderJSON]
}

public actor StdioMCPConnection: MCPConnection {
    public let serverID: String

    private let config: MCPServerConfig
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var pending: [Int: CheckedContinuation<[String: ProviderJSON], Error>] = [:]
    private var nextRequestID = 1
    private var partialLine = Data()
    private let stderrBuffer = BoundedLineBuffer(limit: 64)

    public init(config: MCPServerConfig) {
        self.serverID = config.id
        self.config = config
    }

    public func connect() async throws {
        guard process == nil else { return }
        let executable = URL(fileURLWithPath: config.command)
        guard FileManager.default.isExecutableFile(atPath: config.command) else {
            throw MCPError.launchFailed("'\(config.command)' is not an executable file")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = config.arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in config.environment {
            env[key] = value
        }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw MCPError.launchFailed("could not launch '\(config.command)': \(error.localizedDescription)")
        }
        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self else { return }
            Task { await self.consume(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [stderrBuffer] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            stderrBuffer.append(text)
        }

        _ = try await request(
            method: "initialize",
            params: [
                "protocolVersion": ProviderJSON(MCPJSONRPC.protocolVersion),
                "capabilities": ProviderJSON([:]),
                "clientInfo": ProviderJSON(["name": ProviderJSON(MCPJSONRPC.clientName), "version": ProviderJSON(MCPJSONRPC.clientVersion)]),
            ]
        )
        if let notification = MCPJSONRPC.notification(method: "notifications/initialized") {
            stdinHandle?.write(notification)
            stdinHandle?.write(Data("\n".utf8))
        }
    }

    public func disconnect() async {
        stdoutHandle?.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError.transportFailed("connection closed"))
        }
        pending.removeAll()
    }

    public func request(method: String, params: [String: ProviderJSON], timeout: TimeInterval = 30) async throws -> [String: ProviderJSON] {
        guard let stdinHandle, process?.isRunning == true else {
            throw MCPError.transportFailed("stdio transport for '\(serverID)' is not running")
        }
        let id = nextRequestID
        nextRequestID += 1
        guard let payload = MCPJSONRPC.request(id: id, method: method, params: params) else {
            throw MCPError.protocolError("could not encode \(method)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            stdinHandle.write(payload)
            stdinHandle.write(Data("\n".utf8))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                if let stale = await self.takePending(id) {
                    stale.resume(throwing: MCPError.timeout(method: method))
                }
            }
        }
    }

    fileprivate func takePending(_ id: Int) -> CheckedContinuation<[String: ProviderJSON], Error>? {
        pending.removeValue(forKey: id)
    }

    private func consume(_ data: Data) {
        partialLine.append(data)
        while let newline = partialLine.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = partialLine[..<newline]
            partialLine = Data(partialLine[partialLine.index(after: newline)...])
            guard !lineData.isEmpty,
                  let decoded = MCPJSONRPC.decode(Data(lineData)) else { continue }
            guard let id = decoded.id else { continue }
            guard let continuation = pending.removeValue(forKey: id) else { continue }
            if let error = decoded.error {
                continuation.resume(throwing: MCPError.requestFailed(method: "rpc", detail: "[\(error.code)] \(error.message)"))
            } else {
                continuation.resume(returning: decoded.result ?? [:])
            }
        }
    }

    public func recentStderr() -> [String] {
        stderrBuffer.currentLines
    }
}

public actor HTTPMCPConnection: MCPConnection {
    public let serverID: String

    private let config: MCPServerConfig
    private let session: URLSession
    private var nextRequestID = 1
    private var sessionEndpoint: URL?

    public init(config: MCPServerConfig, session: URLSession = ProviderSessions.shared) {
        self.serverID = config.id
        self.config = config
        self.session = session
    }

    public func connect() async throws {
        guard let url = URL(string: config.command), url.scheme == "http" || url.scheme == "https" else {
            throw MCPError.launchFailed("'\(config.command)' is not a valid HTTP(S) endpoint")
        }
        _ = try await request(method: "initialize", params: [
            "protocolVersion": ProviderJSON(MCPJSONRPC.protocolVersion),
            "capabilities": ProviderJSON([:]),
            "clientInfo": ProviderJSON(["name": ProviderJSON(MCPJSONRPC.clientName), "version": ProviderJSON(MCPJSONRPC.clientVersion)]),
        ])
    }

    public func disconnect() async {
        sessionEndpoint = nil
    }

    public func request(method: String, params: [String: ProviderJSON], timeout: TimeInterval = 30) async throws -> [String: ProviderJSON] {
        guard let url = URL(string: config.command) else {
            throw MCPError.launchFailed("invalid endpoint")
        }
        let id = nextRequestID
        nextRequestID += 1
        guard let payload = MCPJSONRPC.request(id: id, method: method, params: params) else {
            throw MCPError.protocolError("could not encode \(method)")
        }
        var wire = URLRequest(url: url)
        wire.httpMethod = "POST"
        wire.timeoutInterval = timeout
        wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
        wire.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        wire.setValue(MCPJSONRPC.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        for (name, value) in config.headers {
            wire.setValue(value, forHTTPHeaderField: name)
        }
        wire.httpBody = payload

        let (data, response) = try await session.data(for: wire)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transportFailed("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.requestFailed(method: method, detail: "HTTP \(http.statusCode): \(String(decoding: data.prefix(512), as: UTF8.self))")
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            return try Self.decodeSSE(data, expecting: id, method: method)
        }
        guard let decoded = MCPJSONRPC.decode(data) else {
            throw MCPError.protocolError("unparseable response to \(method)")
        }
        if let error = decoded.error {
            throw MCPError.requestFailed(method: method, detail: "[\(error.code)] \(error.message)")
        }
        return decoded.result ?? [:]
    }

    static func decodeSSE(_ data: Data, expecting id: Int, method: String) throws -> [String: ProviderJSON] {
        let text = String(decoding: data, as: UTF8.self)
        for event in text.components(separatedBy: "\n\n") {
            for line in event.components(separatedBy: "\n") where line.hasPrefix("data:") {
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, let jsonData = payload.data(using: .utf8),
                      let decoded = MCPJSONRPC.decode(jsonData), decoded.id == id else { continue }
                if let error = decoded.error {
                    throw MCPError.requestFailed(method: method, detail: "[\(error.code)] \(error.message)")
                }
                return decoded.result ?? [:]
            }
        }
        throw MCPError.protocolError("SSE response did not carry a result for \(method)")
    }
}

public actor WebSocketMCPConnection: MCPConnection {
    public let serverID: String

    private let config: MCPServerConfig
    private var task: URLSessionWebSocketTask?
    private var nextRequestID = 1

    public init(config: MCPServerConfig, session: URLSession = ProviderSessions.shared) {
        self.serverID = config.id
        self.config = config
    }

    public func connect() async throws {
        guard let url = URL(string: config.command), url.scheme == "ws" || url.scheme == "wss" else {
            throw MCPError.launchFailed("'\(config.command)' is not a valid ws:// or wss:// endpoint")
        }
        let webSocket = ProviderSessions.shared.webSocketTask(with: url)
        webSocket.resume()
        task = webSocket
        _ = try await request(method: "initialize", params: [
            "protocolVersion": ProviderJSON(MCPJSONRPC.protocolVersion),
            "capabilities": ProviderJSON([:]),
            "clientInfo": ProviderJSON(["name": ProviderJSON(MCPJSONRPC.clientName), "version": ProviderJSON(MCPJSONRPC.clientVersion)]),
        ])
    }

    public func disconnect() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    public func request(method: String, params: [String: ProviderJSON], timeout: TimeInterval = 30) async throws -> [String: ProviderJSON] {
        guard let task else {
            throw MCPError.transportFailed("websocket for '\(serverID)' is not open")
        }
        let id = nextRequestID
        nextRequestID += 1
        guard let payload = MCPJSONRPC.request(id: id, method: method, params: params),
              let text = String(data: payload, encoding: .utf8) else {
            throw MCPError.protocolError("could not encode \(method)")
        }
        try await task.send(.string(text))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                guard let decoded = MCPJSONRPC.decode(Data(text.utf8)), decoded.id == id else { continue }
                if let error = decoded.error {
                    throw MCPError.requestFailed(method: method, detail: "[\(error.code)] \(error.message)")
                }
                return decoded.result ?? [:]
            case .data(let data):
                guard let decoded = MCPJSONRPC.decode(data), decoded.id == id else { continue }
                if let error = decoded.error {
                    throw MCPError.requestFailed(method: method, detail: "[\(error.code)] \(error.message)")
                }
                return decoded.result ?? [:]
            @unknown default:
                continue
            }
        }
        throw MCPError.timeout(method: method)
    }
}

/// Bounded stderr capture: keeps the last N lines for diagnostics.
final class BoundedLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var tail = ""
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        tail += text
        let parts = tail.components(separatedBy: "\n")
        guard parts.count > 1 else { return }
        tail = parts.last ?? ""
        lines.append(contentsOf: parts.dropLast())
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
    }

    var currentLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
