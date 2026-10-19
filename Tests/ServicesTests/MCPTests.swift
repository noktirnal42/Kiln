import Foundation
import Testing
@testable import Kiln

struct MCPTests {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-mcp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A deterministic stdio MCP fixture server written as a shell script:
    /// answers initialize, tools/list, tools/call(echo).
    private func writeFixtureServer(in directory: URL) throws -> URL {
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"id"'*) ;;
            *) continue ;;
          esac
          id=$(printf '%s' "$line" | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\\1/')
          result=""
          case "$line" in
            *'"initialize"'*)
              result='{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1.0"}}'
              ;;
            *'"tools/list"'*)
              result='{"tools":[{"name":"echo","description":"Echo back the input","inputSchema":{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}}]}'
              ;;
            *'"tools/call"'*)
              result='{"content":[{"type":"text","text":"fixture-echo-ok"}],"isError":false}'
              ;;
            *'"resources/list"'*)
              result='{"resources":[{"uri":"fixture://doc","name":"Fixture Doc","description":"A document"}]}'
              ;;
            *'"prompts/list"'*)
              result='{"prompts":[{"name":"greet","description":"Greets the user"}]}'
              ;;
            *)
              printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"method not found"}}\\n' "$id"
              continue
              ;;
          esac
          printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$id" "$result"
        done
        """
        let url = directory.appendingPathComponent("fixture-mcp-server.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeService() -> MCPClientService {
        MCPClientService(approvals: MCPApprovalStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("approvals-\(UUID().uuidString).json")))
    }

    @Test func stdioHandshakeAndRegistries() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let serverPath = try writeFixtureServer(in: directory)
        let service = makeService()
        let config = MCPServerConfig(id: "fixture", transport: .stdio, command: "/bin/sh", arguments: [serverPath.path])
        await service.addServer(config)

        // Unapproved connect must fail with the approval reason.
        do {
            try await service.connect("fixture")
            Issue.record("expected approval failure")
        } catch let error as MCPError {
            #expect(error == .approvalRequired(serverID: "fixture"))
        }

        await service.approve(config)
        try await service.connect("fixture")

        let tools = await service.allTools()
        #expect(tools.map(\.name) == ["echo"])
        #expect(tools.first?.description == "Echo back the input")
        let resources = await service.allResources()
        #expect(resources.first?.uri == "fixture://doc")
        let prompts = await service.allPrompts()
        #expect(prompts.first?.name == "greet")

        let result = try await service.callTool(qualifiedName: "fixture:echo", arguments: ["message": ProviderJSON("hi")])
        #expect(result.text == "fixture-echo-ok")
        #expect(!result.isError)

        await service.disconnectAll()
    }

    @Test func toolCallOnDisconnectedServerFailsCleanly() async throws {
        let service = makeService()
        let config = MCPServerConfig(id: "ghost", transport: .stdio, command: "/bin/true")
        await service.addServer(config)
        await service.approve(config)
        do {
            _ = try await service.callTool(qualifiedName: "ghost:echo", arguments: [:])
            Issue.record("expected failure")
        } catch let error as MCPError {
            #expect(error == .serverNotConnected("ghost"))
        }
    }

    @Test func unknownToolFailsWithSpecificError() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let serverPath = try writeFixtureServer(in: directory)
        let service = makeService()
        let config = MCPServerConfig(id: "fixture", transport: .stdio, command: "/bin/sh", arguments: [serverPath.path])
        await service.addServer(config)
        await service.approve(config)
        try await service.connect("fixture")
        do {
            _ = try await service.callTool(qualifiedName: "fixture:nope", arguments: [:])
            Issue.record("expected failure")
        } catch let error as MCPError {
            #expect(error == .toolNotFound(serverID: "fixture", name: "nope"))
        }
        await service.disconnectAll()
    }

    @Test func discoveryReadsServersJSONAndProjectDotfile() async throws {
        let home = tempDirectory()
        let mcpDir = home.appendingPathComponent(".config/mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
        {"mcpServers": {"local-fs": {"command": "/usr/bin/true", "args": ["--flag"]}, "remote": {"url": "https://mcp.example.test/v1", "type": "http"}}}
        """.write(to: mcpDir.appendingPathComponent("servers.json"), atomically: true, encoding: .utf8)

        let project = tempDirectory()
        try """
        {"mcpServers": {"project-server": {"command": "/usr/bin/env"}}}
        """.write(to: project.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)

        let service = makeService()
        let found = await service.discoverServers(extraDirectories: [mcpDir])
        _ = await service.loadProjectFile(at: project.appendingPathComponent(".mcp.json"))
        let statuses = await service.statuses()
        let ids = Set(statuses.map(\.config.id))
        #expect(ids.contains("local-fs"))
        #expect(ids.contains("project-server"))
        #expect(found.count >= 2)

        let remote = statuses.first { $0.config.id == "local-fs" }?.config
        #expect(remote?.transport == .stdio)
        #expect(remote?.arguments == ["--flag"])
        let http = statuses.first { $0.config.id == "remote" }?.config
        #expect(http?.transport == .http)
    }

    @Test func approvalFingerprintChangesWithCommand() {
        let first = MCPServerConfig(id: "s", transport: .stdio, command: "/usr/bin/true", arguments: [])
        let second = MCPServerConfig(id: "s", transport: .stdio, command: "/usr/bin/true", arguments: ["--evil"])
        #expect(first.approvalFingerprint != second.approvalFingerprint)
    }

    @Test func jsonRPCEncodeDecodeRoundTrip() throws {
        let payload = MCPJSONRPC.request(id: 7, method: "tools/list", params: ["extra": ProviderJSON(1)])
        let data = try #require(payload)
        let decoded = try #require(MCPJSONRPC.decode(data))
        #expect(decoded.id == 7)
        #expect(decoded.method == "tools/list")

        let errorPayload = MCPJSONRPC.decode(Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-1,"message":"bad"}}"#.utf8))
        #expect(errorPayload?.error?.message == "bad")
        #expect(errorPayload?.result == nil)

        let notification = MCPJSONRPC.decode(try #require(MCPJSONRPC.notification(method: "notifications/initialized")))
        #expect(notification?.id == nil)
        #expect(notification?.method == "notifications/initialized")
    }
}
