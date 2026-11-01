import Foundation
import Testing
@testable import Kiln

struct MCPHTTPTests {
    private func raw(_ headers: String, body: String = "") -> Data {
        Data("POST /mcp HTTP/1.1\r\n\(headers)\r\n\r\n\(body)".utf8)
    }

    @Test func aCompleteRequestParsesWithItsBody() {
        let result = MCPHTTP.parse(raw("Content-Length: 2\r\nAuthorization: Bearer abc", body: "{}"))
        guard case .request(let request) = result else { Issue.record("expected a request"); return }
        #expect(request.method == "POST")
        #expect(request.body == Data("{}".utf8))
        #expect(request.headers["authorization"] == "Bearer abc")
    }

    @Test func aShortBodyWaitsForTheRest() {
        #expect(MCPHTTP.parse(raw("Content-Length: 10", body: "{}")) == .needMore)
        #expect(MCPHTTP.parse(Data("POST /mcp HTTP/1.1\r\nContent-Le".utf8)) == .needMore)
    }

    @Test func oversizedOrGarbageRequestsAreRejected() {
        #expect(MCPHTTP.parse(raw("Content-Length: 99999999")) == .malformed)
        #expect(MCPHTTP.parse(Data("nonsense\r\n\r\n".utf8)) == .malformed)
    }

    @Test func onlyTheExactBearerTokenIsAccepted() {
        #expect(MCPHTTP.authorized("Bearer secret", token: "secret"))
        #expect(!MCPHTTP.authorized("Bearer secreT", token: "secret"))
        #expect(!MCPHTTP.authorized("Bearer secret2", token: "secret"))
        #expect(!MCPHTTP.authorized("secret", token: "secret"))
        #expect(!MCPHTTP.authorized(nil, token: "secret"))
    }

    @Test func tokensAreLongAndDifferEveryTime() {
        let a = MCPHTTP.randomToken(), b = MCPHTTP.randomToken()
        #expect(a.count == 64)
        #expect(a != b)
    }
}

@MainActor
struct KilnMCPListenerTests {
    @Test func theLiveEndpointRequiresTheTokenAndAnswersJSONRPC() async throws {
        let registry = ToolRegistry(tools: [])
        let (center, watcher) = try makeTestApprovalCenter(autoResolve: nil)
        watcher.cancel()
        let handler = KilnMCPHandler(orchestrator: AgentOrchestrator(toolRegistry: registry, approvalCenter: center), registry: registry)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-mcp-\(UUID().uuidString)")
        let listener = KilnMCPListener(handler: handler, directory: dir)
        listener.start()
        defer { listener.stop() }
        for _ in 0..<300 where !listener.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        let port = try #require(listener.port, Comment(rawValue: listener.lastError ?? "listener did not start"))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)

        let (_, denied) = try await URLSession.shared.data(for: request)
        #expect((denied as? HTTPURLResponse)?.statusCode == 401)

        request.setValue("Bearer \(listener.token)", forHTTPHeaderField: "Authorization")
        let (data, ok) = try await URLSession.shared.data(for: request)
        #expect((ok as? HTTPURLResponse)?.statusCode == 200)
        let reply = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((reply["result"] as? [String: Any])?["protocolVersion"] as? String == KilnMCPHandler.protocolVersion)

        let config = dir.appendingPathComponent("mcp-server.json")
        let mode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        listener.stop()
        #expect(!FileManager.default.fileExists(atPath: config.path))
    }
}
