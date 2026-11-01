import Foundation
import Network
import Observation
import Security

/// Pure HTTP framing for the MCP endpoint, separate from sockets so it can be tested.
enum MCPHTTP {
    struct Request: Equatable {
        var method: String
        var headers: [String: String]
        var body: Data
    }

    enum Parse: Equatable {
        case needMore
        case request(Request)
        case malformed
    }

    static let maxBytes = 4 * 1024 * 1024

    static func parse(_ data: Data) -> Parse {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16 * 1024 ? .malformed : .needMore
        }
        guard let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return .malformed }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBytes else { return .malformed }
        let body = data[separator.upperBound...]
        guard body.count >= length else { return .needMore }
        return .request(Request(method: String(requestLine[0]), headers: headers, body: Data(body.prefix(length))))
    }

    /// Constant-time comparison so response timing does not leak how much of a token matched.
    static func authorized(_ header: String?, token: String) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let given = Array(header.dropFirst(7).utf8), expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func response(status: Int, reason: String, body: Data = Data()) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Serves `KilnMCPHandler` on loopback only, behind a bearer token. Off unless the user turns it on.
/// The port and token are written to `mcp-server.json` (owner-only) so a client can be configured.
@MainActor
@Observable
public final class KilnMCPListener {
    public private(set) var isRunning = false
    public private(set) var port: UInt16?
    public private(set) var lastError: String?
    public private(set) var token: String

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let handler: KilnMCPHandler
    @ObservationIgnored private let configURL: URL?

    public init(handler: KilnMCPHandler, directory: URL? = AgentPaths.makeDefault()) {
        self.handler = handler
        self.configURL = directory?.appendingPathComponent("mcp-server.json")
        self.token = MCPHTTP.randomToken()
    }

    public func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            let listener = try NWListener(using: parameters)
            let handler = handler
            let token = token
            listener.newConnectionHandler = { connection in
                Self.serve(connection, handler: handler, token: token)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.stateChanged(state) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            lastError = "Could not start the MCP server: \(error.localizedDescription)"
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = nil
        if let configURL { try? FileManager.default.removeItem(at: configURL) }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let value = listener?.port?.rawValue else { return }
            port = value
            isRunning = true
            lastError = nil
            writeConfig(port: value)
        case .failed(let error):
            lastError = "MCP server failed: \(error.localizedDescription)"
            stop()
        default: break
        }
    }

    private func writeConfig(port: UInt16) {
        guard let configURL else { return }
        let object: [String: Any] = ["url": "http://127.0.0.1:\(port)/mcp", "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: configURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    // MARK: Connections

    private nonisolated static func serve(_ connection: NWConnection, handler: KilnMCPHandler, token: String) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, buffer: Data(), handler: handler, token: token)
    }

    private nonisolated static func receive(_ connection: NWConnection, buffer: Data, handler: KilnMCPHandler, token: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch MCPHTTP.parse(buffer) {
            case .needMore:
                if isComplete || error != nil { connection.cancel() }
                else { receive(connection, buffer: buffer, handler: handler, token: token) }
            case .malformed:
                finish(connection, MCPHTTP.response(status: 400, reason: "Bad Request"))
            case .request(let request):
                guard MCPHTTP.authorized(request.headers["authorization"], token: token) else {
                    return finish(connection, MCPHTTP.response(status: 401, reason: "Unauthorized"))
                }
                guard request.method == "POST" else {
                    return finish(connection, MCPHTTP.response(status: 405, reason: "Method Not Allowed"))
                }
                let client = request.headers["user-agent"] ?? "mcp-client"
                Task {
                    if let reply = await handler.handle(request.body, client: client) {
                        finish(connection, MCPHTTP.response(status: 200, reason: "OK", body: reply))
                    } else {
                        finish(connection, MCPHTTP.response(status: 202, reason: "Accepted"))
                    }
                }
            }
        }
    }

    private nonisolated static func finish(_ connection: NWConnection, _ response: Data) {
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
