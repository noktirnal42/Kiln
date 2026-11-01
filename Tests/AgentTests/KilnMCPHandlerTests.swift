import Foundation
import Testing
@testable import Kiln

@MainActor
struct KilnMCPHandlerTests {
    private struct EchoTool: ToolExecuting {
        let name: String
        let permission: ToolPermissionLevel
        var spec: ToolSpec {
            ToolSpec(name: name, summary: "echo", parameters: [ToolParam(name: "text")], permission: permission)
        }
        func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String { "ran:" + argumentsJSON }
    }

    /// An approval center that answers every question instantly so tests never hang.
    private func handler() throws -> (KilnMCPHandler, ApprovalCenter) {
        let registry = ToolRegistry(tools: [EchoTool(name: "peek", permission: .read), EchoTool(name: "poke", permission: .write)])
        let (center, watcher) = try makeTestApprovalCenter(autoResolve: nil)
        watcher.cancel()
        let orchestrator = AgentOrchestrator(toolRegistry: registry, approvalCenter: center)
        return (KilnMCPHandler(orchestrator: orchestrator, registry: registry), center)
    }

    private func raw(_ handler: KilnMCPHandler, _ method: String, id: Int = 1, params: [String: Any] = [:]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params] as [String: Any])
        return try #require(await handler.handle(body))
    }

    private func parse(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func call(_ handler: KilnMCPHandler, _ method: String, id: Int = 1, params: [String: Any] = [:]) async throws -> [String: Any] {
        try parse(await raw(handler, method, id: id, params: params))
    }

    @Test func initializeAdvertisesToolsAndEchoesTheRequestID() async throws {
        let (h, _) = try handler()
        let reply = try await call(h, "initialize", id: 7)
        #expect(reply["id"] as? Int == 7)
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == KilnMCPHandler.protocolVersion)
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
    }

    @Test func toolsListDescribesEveryRegisteredTool() async throws {
        let (h, _) = try handler()
        let result = try #require(try await call(h, "tools/list")["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["peek", "poke"])
        let schema = try #require(tools[0]["inputSchema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["text"])
    }

    @Test func aReadToolRunsWithoutAskingAnyone() async throws {
        let (h, _) = try handler()
        let result = try #require(try await call(h, "tools/call", params: ["name": "peek", "arguments": ["text": "hi"]])["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(text?.hasPrefix("ran:") == true)
    }

    @Test func aWriteToolWaitsForAHumanAndIsRefusedWhenTheyDecline() async throws {
        let (h, center) = try handler()
        let pending = Task { try await raw(h, "tools/call", params: ["name": "poke", "arguments": ["text": "x"]]) }
        // The call must be parked in the approval queue, not executed.
        for _ in 0..<200 where center.pending.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let request = try #require(center.pending.first)
        #expect(request.toolName == "poke")
        center.resolve(request.id, decision: .deny)

        let result = try #require(try parse(await pending.value)["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    @Test func unknownToolsAndMethodsAreProtocolErrors() async throws {
        let (h, _) = try handler()
        let unknownTool = try await call(h, "tools/call", params: ["name": "nope"])
        #expect((unknownTool["error"] as? [String: Any])?["code"] as? Int == -32602)
        let unknownMethod = try await call(h, "bogus")
        #expect((unknownMethod["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func notificationsGetNoReply() async throws {
        let (h, _) = try handler()
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(await h.handle(body) == nil)
    }
}
