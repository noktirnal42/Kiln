import Foundation
import Testing
@testable import Kiln

/// End-to-end QA with a real hosted model doing real tasks. Opt-in (`TEST_RUNNER_KILN_LIVE=1`): it spends
/// network calls and takes minutes. Each test prints what happened so a failure can be read, not guessed.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE"] == "1"), .serialized)
struct LiveQATests {
    // MARK: Harness

    private struct Model {
        let provider: any ModelProvider
        let id: String   // the bare model name the provider wants
        var label: String { "\(provider.id)/\(id)" }
    }

    /// GLM 5.3 Flash on NVIDIA NIM (the model the user chose), falling back to a listed free OpenRouter model.
    private func model() async throws -> Model {
        let keychain = KeychainService()
        let nim = NVIDIANIMProvider(secretProvider: keychain.secretProvider(module: providersKeychainModule, key: "nvidia-nim"))
        if let models = try? await nim.fetchModels(),
           let glm = models.first(where: { $0.id.hasSuffix("glm-5.3-flash") }) {
            return Model(provider: nim, id: String(glm.id.dropFirst("nvidia-nim-".count)))
        }
        throw QAError.noModel
    }

    private enum QAError: Error { case noModel }

    private func workspace(files: [String: String] = [:]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-qa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return dir
    }

    private struct Outcome {
        var text = ""
        var calls: [(tool: String, status: ToolCallStatus)] = []
        var denied = 0
        var succeeded: Set<String> { Set(calls.filter { $0.status == .succeeded }.map(\.tool)) }
    }

    private struct Rig {
        let orchestrator: AgentOrchestrator
        let center: ApprovalCenter
        let watcher: Task<Void, Never>
        let chain: AuditChain
        let registry: ToolRegistry
    }

    private func rig(registry: ToolRegistry, autoApprove: Bool) throws -> Rig {
        let (center, watcher) = try makeTestApprovalCenter(autoResolve: autoApprove ? .approveOnce : nil)
        let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-qa-audit-\(UUID().uuidString)")
        let chain = AuditChain(directory: logDir, headDirectory: logDir.deletingLastPathComponent().appendingPathComponent("head-\(UUID().uuidString)"))
        let orchestrator = AgentOrchestrator(toolRegistry: registry, approvalCenter: center, auditChain: chain)
        return Rig(orchestrator: orchestrator, center: center, watcher: watcher, chain: chain, registry: registry)
    }

    private func run(_ rig: Rig, model: Model, profile name: String, prompt: String, root: URL) async throws -> Outcome {
        var profile = try #require(AgentProfile.builtIns.first { $0.name == name })
        profile.modelID = model.id
        profile.runTimeoutSeconds = 420
        let provider = model.provider
        var outcome = Outcome()
        for try await event in rig.orchestrator.run(profile: profile, prompt: prompt, workspaceRoot: root,
                                                    chat: { request in try await provider.streamChat(request, reasoning: nil) }) {
            switch event {
            case .toolCallFinished(let record):
                outcome.calls.append((record.toolName, record.status))
                if record.status == .failed { print("QA FAIL \(record.toolName) args=\(record.argumentsJSON.prefix(160)) error=\((record.errorText ?? "").prefix(300))") }
            case .policyDenied: outcome.denied += 1
            case .finished(let summary): outcome.text = summary.finalText
            default: break
            }
        }
        return outcome
    }

    private func report(_ title: String, _ model: Model, _ outcome: Outcome) {
        print("QA \(title) [\(model.label)] calls=\(outcome.calls.map { "\($0.tool):\($0.status.rawValue)" }) denied=\(outcome.denied)")
        print("QA \(title) answer: \(outcome.text.replacingOccurrences(of: "\n", with: " ").prefix(400))")
    }

    private func builtins() -> ToolRegistry {
        let registry = ToolRegistry()
        BuiltInTools.registerAll(into: registry)
        return registry
    }

    // MARK: Tasks

    @Test func theAgentBuildsAndRunsASmallApp() async throws {
        let model = try await model()
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(registry: builtins(), autoApprove: true)
        defer { rig.watcher.cancel() }

        let outcome = try await run(rig, model: model, profile: "Coding Agent", prompt: """
            Build a small command-line Python app in this folder. wordcount.py takes a file path as its first \
            argument and prints the number of words in that file. Create sample.txt containing exactly: \
            the quick brown fox jumps over the lazy dog — then run the app on sample.txt and tell me what it printed.
            """, root: root)
        report("app", model, outcome)

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("wordcount.py").path), "no wordcount.py")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sample.txt").path), "no sample.txt")
        #expect(outcome.succeeded.contains("write_file") || outcome.succeeded.contains("edit_file"))
        #expect(outcome.succeeded.contains("run_command") || outcome.succeeded.contains("stream_command"), "never ran the app")
        #expect(outcome.text.contains("9"), "did not report the 9 words")
        let verification = try await rig.chain.verify()
        #expect(verification.ok, "audit chain not intact")
        #expect(verification.checked > 4)
    }

    @Test func theAgentReverseEngineersASystemBinary() async throws {
        let model = try await model()
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = builtins()
        let module = REModule()
        REAgentTools.register(module: module, into: registry)
        let rig = try rig(registry: registry, autoApprove: true)
        defer { rig.watcher.cancel() }

        let outcome = try await run(rig, model: model, profile: "Workstation Agent", prompt: """
            Use the reverse engineering tools to import /bin/ls and analyze it. Tell me its file format and \
            CPU architecture(s), and quote one line of its usage message from the strings you find.
            """, root: root)
        report("re", model, outcome)

        #expect(outcome.succeeded.contains("re_import_binary"), "never imported the binary")
        #expect(outcome.succeeded.contains("re_search_strings") || outcome.succeeded.contains("re_get_disassembly"),
                "imported but did not inspect it")
        #expect(outcome.text.lowercased().contains("mach-o"), "format not reported")
        #expect(outcome.text.lowercased().contains("usage"), "no usage line quoted")
        #expect(module.projects.count == 1, "the import did not land in the RE module")
    }

    @Test func externalAgentsGetTheSameToolsAndTheSameGates() async throws {
        let root = try workspace(files: ["note.txt": "kiln mcp qa\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = builtins()
        let module = REModule()
        REAgentTools.register(module: module, into: registry)
        ModelLabAgentTools.register(module: ModelLabModule(), into: registry)
        let rig = try rig(registry: registry, autoApprove: false)
        defer { rig.watcher.cancel() }
        let handler = KilnMCPHandler(orchestrator: rig.orchestrator, registry: registry, workspaceRoot: { root })
        let listener = KilnMCPListener(handler: handler, directory: root.appendingPathComponent("cfg"))
        listener.start()
        defer { listener.stop() }
        for _ in 0..<300 where !listener.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        let port = try #require(listener.port)
        let token = listener.token

        func raw(_ method: String, _ params: [String: Any] = [:], id: Int = 1) async throws -> Data {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params] as [String: Any])
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        }
        func parse(_ data: Data) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func call(_ method: String, _ params: [String: Any] = [:], id: Int = 1) async throws -> [String: Any] {
            try parse(try await raw(method, params, id: id))
        }
        func text(_ reply: [String: Any]) -> (String, Bool) {
            let result = reply["result"] as? [String: Any] ?? [:]
            let content = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            return (content, result["isError"] as? Bool ?? true)
        }

        // The tool list an outside agent sees: files, shell, reverse engineering, model lab.
        let listed = try await call("tools/list")
        let names = ((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        print("QA mcp tools: \(names.count) \(names.prefix(40))")
        for expected in ["read_file", "write_file", "run_command", "re_import_binary", "re_scan_crypto", "lab_hardware"] {
            #expect(names.contains(expected), "missing \(expected)")
        }

        // A read runs without asking anyone.
        let read = text(try await call("tools/call", ["name": "read_file", "arguments": ["path": "note.txt"]]))
        #expect(read.1 == false && read.0.contains("kiln mcp qa"), "read failed: \(read.0)")

        // Model Lab answers from the real hardware.
        let hardware = text(try await call("tools/call", ["name": "lab_hardware"]))
        print("QA mcp lab_hardware: \(hardware.0)")
        #expect(hardware.1 == false && hardware.0.contains("GB"))

        // A write waits for a human. Declined: nothing written. Approved: written.
        let target = root.appendingPathComponent("out.txt")
        let declined = Task { try await raw("tools/call", ["name": "write_file", "arguments": ["path": "out.txt", "content": "x"]], id: 2) }
        for _ in 0..<400 where rig.center.pending.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let firstRequest = try #require(rig.center.pending.first, "the write was not held for approval")
        #expect(firstRequest.toolName == "write_file")
        rig.center.resolve(firstRequest.id, decision: .deny)
        let declinedText = text(try parse(await declined.value))
        #expect(declinedText.1 == true)
        #expect(!FileManager.default.fileExists(atPath: target.path), "wrote despite a decline")

        let approved = Task { try await raw("tools/call", ["name": "write_file", "arguments": ["path": "out.txt", "content": "approved"]], id: 3) }
        for _ in 0..<400 where rig.center.pending.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let secondRequest = try #require(rig.center.pending.first)
        rig.center.resolve(secondRequest.id, decision: .approveOnce)
        let approvedText = text(try parse(await approved.value))
        #expect(approvedText.1 == false, "approved write failed: \(approvedText.0)")
        #expect((try? String(contentsOf: target, encoding: .utf8)) == "approved")

        // Reverse engineering over MCP: import is a write-level tool, so it asks too.
        let importing = Task { try await raw("tools/call", ["name": "re_import_binary", "arguments": ["path": "/bin/ls"]], id: 4) }
        for _ in 0..<400 where rig.center.pending.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let importRequest = try #require(rig.center.pending.first, "import was not held for approval")
        rig.center.resolve(importRequest.id, decision: .approveOnce)
        let imported = text(try parse(await importing.value))
        print("QA mcp re_import_binary: \(imported.0.prefix(200))")
        #expect(imported.1 == false)
        #expect(module.projects.count == 1)

        // The shell is gated too, and a destructive command is refused outright.
        let rm = Task { try await raw("tools/call", ["name": "run_command", "arguments": ["command": "rm -rf /"]], id: 5) }
        for _ in 0..<150 where rig.center.pending.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        for request in rig.center.pending { rig.center.resolve(request.id, decision: .deny) }
        let rmText = text(try parse(await rm.value))
        #expect(rmText.1 == true, "rm -rf / was not stopped")

        // Everything above is in a verifiable audit chain.
        let verification = try await rig.chain.verify()
        #expect(verification.ok && verification.checked > 8, "audit chain: ok=\(verification.ok) checked=\(verification.checked)")
        print("QA mcp audit events: \(verification.checked)")
    }

    @Test func aSwarmOfRealAgentsFinishesAJob() async throws {
        let model = try await model()
        let root = try workspace(files: [
            "readme.txt": "Kiln is an agentic workstation. It has an agent, a swarm, reverse engineering and a model lab.\n",
            "todo.txt": "1. ship notarized build\n2. write more tests\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(registry: builtins(), autoApprove: true)
        defer { rig.watcher.cancel() }
        let provider = model.provider
        let modelID = model.id

        let planned = await SwarmPlanner.plan(goal: "Read the files here and write summary.md with one paragraph covering both.") { system, goal in
            try await provider.streamChat(ChatRequest(messages: [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: goal)],
                                                      model: modelID, temperature: 0, maxTokens: 800), reasoning: nil).reduce(into: "") { $0 += $1.delta?.content ?? "" }
        }
        print("QA swarm plan (fallback=\(planned.usedFallback)): \(planned.graph.tasks.map { "\($0.id)[\($0.role.rawValue)]" })")

        let bus = CoordinationBus()
        let swarm = SwarmOrchestrator(bus: bus, maxParallel: 2, worker: SwarmWorkers.agent(
            base: rig.orchestrator, modelID: modelID, workspaceRoot: root,
            chat: { request in try await provider.streamChat(request, reasoning: nil) }))
        var final: SwarmGraph?
        for await event in swarm.run(goal: "Read the files here and write summary.md with one paragraph covering both.",
                                     graph: planned.graph, usedFallback: planned.usedFallback) {
            if case .finished(let graph) = event { final = graph }
        }
        let graph = try #require(final)
        print("QA swarm result: \(graph.tasks.map { "\($0.id)=\($0.status.rawValue)" })")
        let summary = try? String(contentsOf: root.appendingPathComponent("summary.md"), encoding: .utf8)
        print("QA swarm summary.md: \(summary?.prefix(300) ?? "<none>")")
        #expect(graph.tasks.contains { $0.status == .done }, "nothing completed")
        #expect(!graph.tasks.contains { $0.status == .blocked }, "a task was blocked: \(graph.tasks.filter { $0.status == .blocked }.map { $0.result ?? "" })")
        #expect(summary != nil, "summary.md was never written")
        let messages = await bus.history(limit: 200)
        #expect(!messages.isEmpty, "the team never used the bus")
        let verification = try await rig.chain.verify()
        #expect(verification.ok)
    }

    /// Tool use on the providers the other tests do not cover: Ollama Cloud, a custom OpenAI-compatible endpoint
    /// (Ollama's own /v1 stands in), and local Ollama. The prompt names no tool.
    @Test func everyOtherProviderCanUseToolsOnARealTask() async throws {
        let keychain = KeychainService()
        let cases: [(label: String, provider: any ModelProvider, pick: ([ModelDescriptor]) -> [String])] = [
            ("ollama-cloud",
             OpenCodeProvider(scope: .cloud, secretProvider: keychain.secretProvider(module: providersKeychainModule, key: "ollama-cloud")),
             { models in ["glm-5.2", "gemma4:31b", "deepseek-v4.1-flash"].compactMap { n in models.first { $0.id.hasSuffix(n) }?.id } }),
            ("custom(ollama /v1)",
             CustomEndpointProvider(baseURL: "http://localhost:11434/v1", secretProvider: { nil }),
             { models in models.filter { $0.id.contains("qwen2.5-coder") }.map(\.id) }),
            ("ollama-local",
             OpenCodeProvider(scope: .local),
             { models in models.filter { $0.id.contains("qwen2.5-coder") }.map(\.id) }),
        ]
        var failures: [String] = []
        for testCase in cases {
            guard let catalog = try? await testCase.provider.fetchModels() else { failures.append("\(testCase.label): catalog did not load"); continue }
            var passed = false
            var last = "no suitable model"
            for id in testCase.pick(catalog) {
                let bare = ModelRegistry.bareModelID(id, providerID: testCase.provider.id)
                let model = Model(provider: testCase.provider, id: bare)
                let root = try workspace(files: ["notes.txt": "The secret word is \"marmalade\".\n"])
                defer { try? FileManager.default.removeItem(at: root) }
                let rig = try rig(registry: builtins(), autoApprove: false)
                defer { rig.watcher.cancel() }
                do {
                    let outcome = try await run(rig, model: model, profile: "Research Assistant",
                                                prompt: "What is the secret word in notes.txt?", root: root)
                    report(testCase.label, model, outcome)
                    last = outcome.text
                    if outcome.text.lowercased().contains("marmalade") { passed = true; break }
                } catch { last = String(describing: error); print("QA \(testCase.label) \(bare): \(last.prefix(160))") }
            }
            if !passed { failures.append("\(testCase.label): \(last.prefix(140))") }
        }
        #expect(failures.isEmpty, "providers that could not use a tool: \(failures)")
    }
}
