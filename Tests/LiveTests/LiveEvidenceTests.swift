import Foundation
import Testing
@testable import Kiln

/// Repeatable, opt-in evidence run (`TEST_RUNNER_KILN_LIVE=1`): the same two swarm tasks against each configured model, with what
/// each model really did (tools offered/executed, files written, verdict, failure class) written to `docs/qa/model-evidence.json`.
/// Models that cannot be reached are recorded as unavailable, never as passing. Keys are read from the Keychain and never printed.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE"] == "1"), .serialized)
struct LiveEvidenceTests {
    struct Target { let label: String; let provider: any ModelProvider; let model: String; let runtime: String }

    private struct Row: Codable {
        var model: String, runtime: String, date: String, build: String
        var status: String               // done | blocked | unavailable
        var failureClass: String?
        var toolsExecuted: [String]
        var filesWritten: [String]
        var verified: Bool               // the expected artifact exists with the expected content
        var note: String
    }

    private func targets() -> [Target] {
        let keychain = KeychainService()
        return [
            // Small local models are the interesting cases: they chat well and often fail tool use. Edit this list for your machine.
            Target(label: "ollama/gemma4:e4b", provider: OpenCodeProvider(scope: .local), model: "gemma4:e4b", runtime: "native Ollama"),
            Target(label: "ollama/gemma3:4b", provider: OpenCodeProvider(scope: .local), model: "gemma3:4b", runtime: "native Ollama"),
            Target(label: "ollama/SiliconBasedWorld/Qwen2.5-7B-Instruct-1M", provider: OpenCodeProvider(scope: .local),
                   model: "SiliconBasedWorld/Qwen2.5-7B-Instruct-1M:latest", runtime: "native Ollama"),
            Target(label: "ollama-cloud/gemma4:31b",
                   provider: OpenCodeProvider(scope: .cloud, secretProvider: keychain.secretProvider(module: providersKeychainModule, key: "ollama-cloud")),
                   model: "gemma4:31b", runtime: "Ollama Cloud (hosted)"),
        ]
    }

    private func run(_ target: Target) async throws -> Row {
        let date = ISO8601DateFormatter().string(from: Date())
        let build = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
        let baseRow = Row(model: target.label, runtime: target.runtime, date: date, build: build, status: "unavailable", failureClass: nil,
                          toolsExecuted: [], filesWritten: [], verified: false, note: "")
        guard await target.provider.checkAvailability().isAvailable else {
            var row = baseRow; row.note = "provider unavailable (not running, or no key configured)"; return row
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Project: Harbor\nRelease code: COBALT-731\n".write(to: root.appendingPathComponent("project.txt"), atomically: true, encoding: .utf8)

        let (center, watcher) = try makeTestApprovalCenter(autoResolve: .approveOnce)
        defer { watcher.cancel() }
        let base = AgentOrchestrator(toolRegistry: ToolRegistry(tools: [ReadFileTool(), WriteFileTool(), EditFileTool()]), approvalCenter: center)
        let provider = target.provider
        let model = target.model
        let swarm = SwarmOrchestrator(bus: CoordinationBus(), attemptsPerTask: 1, worker: SwarmWorkers.agent(
            base: base, modelID: model, workspaceRoot: root,
            chat: { request in
                var forProvider = request; forProvider.model = model
                return try await provider.streamChat(forProvider, reasoning: nil)
            }))
        let graph = try SwarmGraph(tasks: [
            SwarmTask(id: "write", title: "Write the release note",
                      details: "Use read_file to read project.txt, then use write_file to create release.md containing the release code exactly.",
                      role: .implementer, expects: ["nonempty:release.md"]),
        ])
        var final: SwarmGraph?
        for await event in swarm.run(goal: "Record the release code in release.md", graph: graph) { if case .finished(let g) = event { final = g } }
        let task = try #require(final?.task("write"))
        let written = (try? String(contentsOf: root.appendingPathComponent("release.md"), encoding: .utf8)) ?? ""
        let result = task.result ?? ""
        var row = baseRow
        row.status = task.status == .done ? "done" : "blocked"
        row.verified = written.contains("COBALT-731")
        row.note = String(result.prefix(300))
        if task.status != .done {
            let classes = ["Provider/transport", "Model limitation", "Tool failure", "Unverified"]
            let text = classes.contains { result.hasPrefix($0) } ? result : RunFailure.classify(errorMessage: result)
            row.failureClass = classes.first { text.hasPrefix($0) }
        }
        if let range = result.range(of: "[evidence: tools: ") {
            let line = result[range.upperBound...].prefix { $0 != "·" && $0 != "]" }
            row.toolsExecuted = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let range = result.range(of: "files written: ") { row.filesWritten = result[range.upperBound...].prefix { $0 != "·" && $0 != "]" }.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return row
    }

    @Test func recordsPerModelEvidenceToDocsQA() async throws {
        var rows: [Row] = []
        for target in targets() { rows.append(try await run(target)) }
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/qa/model-evidence.json")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: out)
        for row in rows { print("EVIDENCE \(row.model): \(row.status) verified=\(row.verified) class=\(row.failureClass ?? "-")") }
        // A model that says it succeeded must have produced the artifact: "done" without the file is a defect in Kiln's checks.
        for row in rows where row.status == "done" { #expect(row.verified, "\(row.model) was marked done without release.md containing the code") }
    }
}
