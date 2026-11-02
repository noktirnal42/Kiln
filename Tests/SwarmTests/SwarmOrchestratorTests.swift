import Foundation
import Testing
@testable import Kiln

struct SwarmGraphTests {
    private func task(_ id: String, after: [String] = [], role: SwarmRole = .researcher) -> SwarmTask {
        SwarmTask(id: id, title: id, role: role, dependsOn: after)
    }

    @Test func invalidPlansAreRejected() {
        #expect(throws: SwarmGraph.Invalid.empty) { try SwarmGraph(tasks: []) }
        #expect(throws: SwarmGraph.Invalid.invalidID("Bad ID")) { try SwarmGraph(tasks: [task("Bad ID")]) }
        #expect(throws: SwarmGraph.Invalid.duplicateID("a")) { try SwarmGraph(tasks: [task("a"), task("a")]) }
        #expect(throws: SwarmGraph.Invalid.unknownDependency(task: "a", missing: "zzz")) { try SwarmGraph(tasks: [task("a", after: ["zzz"])]) }
        #expect(throws: SwarmGraph.Invalid.cycle) { try SwarmGraph(tasks: [task("a", after: ["b"]), task("b", after: ["a"])]) }
        #expect(throws: SwarmGraph.Invalid.tooMany(SwarmGraph.maxTasks)) {
            try SwarmGraph(tasks: (0...SwarmGraph.maxTasks).map { task("t\($0)") })
        }
    }

    @Test func readyTasksAreTheOnesWhoseDependenciesAreDone() throws {
        var graph = try SwarmGraph(tasks: [task("a"), task("b"), task("c", after: ["a", "b"])])
        #expect(graph.ready.map(\.id) == ["a", "b"])
        graph.update("a") { $0.status = .done }
        #expect(graph.ready.map(\.id) == ["b"])
        graph.update("b") { $0.status = .done }
        #expect(graph.ready.map(\.id) == ["c"])
    }

    @Test func aBlockedTaskSkipsEverythingDownstreamOnly() throws {
        var graph = try SwarmGraph(tasks: [task("a"), task("b", after: ["a"]), task("c", after: ["b"]), task("d")])
        graph.update("a") { $0.status = .blocked }
        graph.skipDependents(of: "a")
        #expect(graph.task("b")?.status == .skipped)
        #expect(graph.task("c")?.status == .skipped)
        #expect(graph.task("d")?.status == .pending, "unrelated work continues")
    }

    @Test func aModelPlanIsUsedOnlyIfItIsAValidGraph() {
        let good = #"Sure: {"tasks":[{"id":"a","title":"Look","role":"researcher"},{"id":"b","title":"Do","role":"implementer","depends_on":["a"]}]}"#
        #expect(SwarmPlanner.parse(good)?.tasks.map(\.id) == ["a", "b"])
        #expect(SwarmPlanner.parse("no json here") == nil)
        #expect(SwarmPlanner.parse(#"{"tasks":[{"id":"a","title":"x","role":"wizard"}]}"#) == nil)
        #expect(SwarmPlanner.parse(#"{"tasks":[{"id":"a","title":"x","role":"reviewer","depends_on":["a"]}]}"#) == nil)
        #expect(SwarmPlanner.parse(#"{"tasks":[{"id":"a","title":"x","role":"reviewer","depends_on":"missing"}]}"#) == nil)
        #expect(SwarmPlanner.parse(#"{"tasks":[{"id":"Task 1","title":"x","role":"reviewer"}]}"#) == nil)
    }

    @Test func plannerFallsBackToResearchImplementReviewWhenTheModelFails() async {
        struct Down: Error {}
        let (graph, usedFallback) = await SwarmPlanner.plan(goal: "x") { _, _ in throw Down() }
        #expect(usedFallback)
        #expect(graph.tasks.map(\.id) == ["research", "implement", "review"])
        let (_, garbage) = await SwarmPlanner.plan(goal: "x") { _, _ in "I cannot help" }
        #expect(garbage)
    }
}

struct SwarmOrchestratorTests {
    private func collect(_ stream: AsyncStream<SwarmEvent>) async -> [SwarmEvent] {
        var events: [SwarmEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func finalGraph(_ events: [SwarmEvent]) -> SwarmGraph? {
        for event in events { if case .finished(let graph) = event { return graph } }
        return nil
    }

    private func graph() throws -> SwarmGraph {
        try SwarmGraph(tasks: [
            SwarmTask(id: "a", title: "A", role: .researcher),
            SwarmTask(id: "b", title: "B", role: .researcher),
            SwarmTask(id: "c", title: "C", role: .implementer, dependsOn: ["a", "b"]),
        ])
    }

    @Test func tasksRunInDependencyOrderAndPassResultsDownstream() async throws {
        let bus = CoordinationBus()
        let seen = Locked<[String: String]>([:])
        let swarm = SwarmOrchestrator(bus: bus) { task, prompt, _ in
            seen.withLock { $0[task.id] = prompt }
            return "result-\(task.id)"
        }
        let events = await collect(swarm.run(goal: "ship it", graph: try graph()))
        let final = try #require(finalGraph(events))
        #expect(final.tasks.allSatisfy { $0.status == .done })
        let prompt = try #require(seen.withLock { $0["c"] })
        #expect(prompt.contains("result-a") && prompt.contains("result-b") && prompt.contains("ship it"))
    }

    @Test func independentTasksOverlapUpToTheParallelLimit() async throws {
        let bus = CoordinationBus()
        let active = Locked<(now: Int, peak: Int)>((0, 0))
        let swarm = SwarmOrchestrator(bus: bus, maxParallel: 2) { task, _, _ in
            active.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
            try await Task.sleep(nanoseconds: 60_000_000)
            active.withLock { $0.now -= 1 }
            return "ok"
        }
        _ = await collect(swarm.run(goal: "g", graph: try graph()))
        #expect(active.withLock { $0.peak } == 2)
    }

    @Test func aFailedTaskIsRetriedOnceThenReportedAsABlockerAndDownstreamIsSkipped() async throws {
        struct Boom: Error {}
        let bus = CoordinationBus()
        let tries = Locked<Int>(0)
        let swarm = SwarmOrchestrator(bus: bus) { task, _, _ in
            if task.id == "a" { tries.withLock { $0 += 1 }; throw Boom() }
            return "ok"
        }
        let events = await collect(swarm.run(goal: "g", graph: try graph()))
        let final = try #require(finalGraph(events))
        #expect(tries.withLock { $0 } == 2)
        #expect(final.task("a")?.status == .blocked)
        #expect(final.task("b")?.status == .done)
        #expect(final.task("c")?.status == .skipped)
        let blockers = await bus.history(topic: "swarm").filter { $0.type == .blocker }
        #expect(blockers.count == 1)
    }

    @Test func aWorkerThatReportsABlockerIsNotRetried() async throws {
        let bus = CoordinationBus()
        let tries = Locked<Int>(0)
        let swarm = SwarmOrchestrator(bus: bus) { task, _, _ in
            if task.id == "a" { tries.withLock { $0 += 1 }; throw SwarmBlocked("needs the signing key") }
            return "ok"
        }
        let events = await collect(swarm.run(goal: "g", graph: try graph()))
        #expect(tries.withLock { $0 } == 1)
        #expect(finalGraph(events)?.task("a")?.result == "needs the signing key")
    }

    @Test func retryRegistersTheSameWorkerAfterCleanup() async throws {
        struct Transient: Error {}
        let bus = CoordinationBus()
        let tries = Locked(0)
        let swarm = SwarmOrchestrator(bus: bus) { _, _, _ in
            let count = tries.withLock { $0 += 1; return $0 }
            if count == 1 { throw Transient() }
            return "recovered"
        }
        let graph = try SwarmGraph(tasks: [SwarmTask(id: "a", title: "A", role: .researcher)])
        let final = try #require(finalGraph(await collect(swarm.run(goal: "g", graph: graph))))
        #expect(tries.withLock { $0 } == 2)
        #expect(final.task("a")?.result == "recovered")
        #expect(await bus.registeredAgents.isEmpty)
    }

    /// Opt-in live smoke test. It uses a disposable fixture and a local Ollama model only.
    @Test func liveLocalSwarmReadsAndReviewsAWorkspace() async throws {
        guard ProcessInfo.processInfo.environment["KILN_LIVE_SWARM_TEST"] == "1" else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-swarm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Project: Harbor\nBuild target: macOS\nRelease code: COBALT-731\n".write(
            to: root.appendingPathComponent("project.txt"), atomically: true, encoding: .utf8)
        let provider = OpenCodeProvider(scope: .local)
        let agent = AgentOrchestrator(toolRegistry: ToolRegistry(tools: [ReadFileTool()]))
        let swarm = SwarmOrchestrator(bus: CoordinationBus(), attemptsPerTask: 1,
            worker: SwarmWorkers.agent(base: agent, modelID: "ollama-qwen2.5-coder:3b", workspaceRoot: root,
                chat: { request in try await provider.streamChat(request, reasoning: nil) }))
        let graph = try SwarmGraph(tasks: [
            SwarmTask(id: "inspect", title: "Inspect project", details: "Use read_file to read project.txt. Report the release code exactly.", role: .researcher),
            SwarmTask(id: "review", title: "Review findings", details: "Use read_file to check project.txt independently and report the release code exactly.", role: .reviewer, dependsOn: ["inspect"]),
        ])
        let final = try #require(finalGraph(await collect(swarm.run(goal: "Verify the project's release code", graph: graph))))
        for task in final.tasks {
            #expect(task.status == .done, "\(task.id): \(task.result ?? "no result")")
            #expect(task.result?.contains("COBALT-731") == true, "\(task.id): \(task.result ?? "no result")")
        }
    }

    @Test func workersTalkOnlyThroughTheBusAsThemselves() async throws {
        let bus = CoordinationBus()
        let swarm = SwarmOrchestrator(bus: bus) { task, _, endpoint in
            try await endpoint.publish(topic: "task/\(task.id)", type: .progress, body: "hello from \(task.id)")
            return "ok"
        }
        _ = await collect(swarm.run(goal: "g", graph: try graph()))
        let notes = await bus.history(limit: 100).filter { $0.type == .progress }
        #expect(Set(notes.map(\.from)) == ["worker.a", "worker.b", "worker.c"])
    }

    @Test func busToolsActAsTheWorkerAndCanReportABlocker() async throws {
        let bus = CoordinationBus()
        let endpoint = try await bus.register(agent: "worker.x")
        let blocker = BlockerBox()
        let tools = SwarmBusTools.make(endpoint: endpoint, task: SwarmTask(id: "x", title: "X", role: .researcher), blocker: blocker)
        let context = ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())
        func run(_ name: String, _ json: String) async throws -> String {
            try await #require(tools.first { $0.spec.name == name }).execute(argumentsJSON: json, context: context)
        }
        _ = try await run("swarm_memory_set", #"{"key":"answer","value":"42"}"#)
        #expect(try await run("swarm_memory_get", #"{"key":"answer"}"#).contains("42"))
        _ = try await run("swarm_report_blocker", #"{"reason":"no access"}"#)
        #expect(blocker.reason == "no access")
        #expect(await bus.history(topic: "swarm").contains { $0.type == .blocker && $0.from == "worker.x" })
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

struct SwarmPolicyTests {
    @Test func everyRoleCanUseBusToolsButOnlyImplementersCanWrite() {
        let policy = ExecutionPolicy(mode: .review)
        #expect(policy.checkTool("swarm_post").verdict == .allow)
        for role in SwarmRole.allCases {
            let set = ToolPermissionSet(enabledTools: role.tools.union(["swarm_*"]))
            #expect(set.isEnabled("swarm_report_blocker"))
            #expect(set.isEnabled("write_file") == (role == .implementer))
            #expect(!set.isEnabled("delete_file"))
        }
    }
}

struct SwarmResultValidationTests {
    @Test func simulatedCallsAreBlocked() {
        #expect(throws: SwarmBlocked.self) {
            try SwarmWorkers.validateSummary(#"{"name":"calculate_total","arguments":{"total_cost":405}}"#)
        }
        #expect(throws: SwarmBlocked.self) { try SwarmWorkers.validateSummary("   ") }
    }

    @Test func plainResultsAndDataAreAccepted() throws {
        try SwarmWorkers.validateSummary("12 × 19 + 8 × 23 = 412. Independently checked each subtotal.")
        try SwarmWorkers.validateSummary(#"{"total":412}"#)
    }
}
