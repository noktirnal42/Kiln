import Foundation
import Testing
@testable import Kiln

/// Verifies the orchestrator hands its `ToolServices` to tool executions:
/// a `search_workspace` call against a real indexed directory returns the
/// index's ranked result rather than the filename-scan fallback.
struct ToolServicesInjectionTests {
    @Test func injectedFileIndexIsUsedBySearchWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The index is over names/paths; both this and the fallback scan
        // find the name — the index's ranked output ("score N") proves the
        // injected service ran rather than the fallback.
        let target = root.appendingPathComponent("quokka-survey.md")
        try Data("x".utf8).write(to: target)

        let index = FileIndexService()
        try await index.index(root: root.path)

        let registry = ToolRegistry(tools: [SearchWorkspaceTool()])
        let orchestrator = AgentOrchestrator(
            toolRegistry: registry,
            services: ToolServices(git: nil, fileIndex: index, webSearchKey: nil)
        )
        let profile = AgentProfile(
            name: "researcher",
            mode: .review,
            toolPermissions: ToolPermissionSet(
                enabledTools: ["search_workspace"],
                policyByLevel: [.read: .automatic]
            )
        )
        let chat = ScriptedChat(turns: [
            ScriptedTurn(text: "searching", toolCalls: [
                ToolCall(id: "c1", name: "search_workspace", arguments: #"{"query": "quokka"}"#)
            ]),
            ScriptedTurn(text: "found it"),
        ])
        let (events, error) = await collectRun(
            orchestrator, profile: profile, prompt: "find quokka notes",
            workspaceRoot: root, chat: chat.factory
        )
        #expect(error == nil)

        let results = events.compactMap { ev -> String? in
            if case .toolCallFinished(let record) = ev { return record.resultText }
            return nil
        }
        #expect(results.count == 1)
        guard results.count == 1 else { return }
        #expect(results[0].contains("quokka-survey.md"), "index hit expected, got: \(results[0].prefix(200))")
        #expect(results[0].contains("score "), "ranked index output expected, got: \(results[0].prefix(200))")
    }

    @Test func missingIndexFallsBackToFilenameScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Filename matches the query: the fallback path finds it.
        try Data("x".utf8).write(to: root.appendingPathComponent("quokka-report.txt"))

        let registry = ToolRegistry(tools: [SearchWorkspaceTool()])
        let orchestrator = AgentOrchestrator(toolRegistry: registry) // no services injected
        let profile = AgentProfile(
            name: "researcher",
            mode: .review,
            toolPermissions: ToolPermissionSet(
                enabledTools: ["search_workspace"],
                policyByLevel: [.read: .automatic]
            )
        )
        let chat = ScriptedChat(turns: [
            ScriptedTurn(text: "searching", toolCalls: [
                ToolCall(id: "c1", name: "search_workspace", arguments: #"{"query": "quokka"}"#)
            ]),
            ScriptedTurn(text: "found it"),
        ])
        let (events, error) = await collectRun(
            orchestrator, profile: profile, prompt: "find the report",
            workspaceRoot: root, chat: chat.factory
        )
        #expect(error == nil)
        let results = events.compactMap { ev -> String? in
            if case .toolCallFinished(let record) = ev { return record.resultText }
            return nil
        }
        #expect(results.count == 1)
        guard results.count == 1 else { return }
        #expect(results[0].contains("quokka-report.txt"))
    }
}
