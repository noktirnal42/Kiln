import Foundation

public enum SwarmEvent: Sendable {
    case planned(SwarmGraph, usedFallback: Bool)
    case taskStarted(String)
    case taskFinished(id: String, summary: String)
    case taskBlocked(id: String, reason: String)
    case finished(SwarmGraph)
}

/// A worker found it could not continue and said so. Surfaced to the operator, never retried silently.
public struct SwarmBlocked: Error, Equatable, Sendable {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// Runs a goal as a graph of tasks, several at once, talking only through the coordination bus.
/// The worker is injected: production uses real agent runs (every tool call still passes the same
/// gates), tests use scripted workers.
public final class SwarmOrchestrator: Sendable {
    public typealias Worker = @Sendable (_ task: SwarmTask, _ prompt: String, _ endpoint: BusEndpoint) async throws -> String

    let bus: CoordinationBus
    let worker: Worker
    let maxParallel: Int
    /// A failed task is tried once more before it is reported as a blocker.
    let attemptsPerTask: Int

    public init(bus: CoordinationBus, maxParallel: Int = 3, attemptsPerTask: Int = 2, worker: @escaping Worker) {
        self.bus = bus
        self.maxParallel = max(1, maxParallel)
        self.attemptsPerTask = max(1, attemptsPerTask)
        self.worker = worker
    }

    /// What a worker is told: the goal, its task, and what the tasks it depends on produced.
    static func prompt(goal: String, task: SwarmTask, graph: SwarmGraph) -> String {
        var text = "Overall goal: \(goal)\n\nYour task (\(task.id)): \(task.title)\n\(task.details)"
        let inputs = task.dependsOn.compactMap { graph.task($0) }.filter { $0.result != nil }
        if !inputs.isEmpty {
            text += "\n\nResults from earlier tasks:\n" + inputs.map { "• \($0.title): \(String(($0.result ?? "").prefix(2_000)))" }.joined(separator: "\n")
        }
        return text
    }

    public func run(goal: String, graph initial: SwarmGraph, usedFallback: Bool = false) -> AsyncStream<SwarmEvent> {
        AsyncStream { continuation in
            let task = Task {
                let lead = try? await bus.registerSystem("orchestrator")
                var graph = initial
                continuation.yield(.planned(graph, usedFallback: usedFallback))
                _ = try? await lead?.publish(topic: "swarm", type: .plan, body: "Plan: \(graph.tasks.map(\.title).joined(separator: " → "))")

                await withTaskGroup(of: (String, Result<String, Error>).self) { group in
                    var running = 0
                    while !Task.isCancelled {
                        for next in graph.ready where running < maxParallel {
                            graph.update(next.id) { $0.status = .running; $0.attempts += 1 }
                            running += 1
                            continuation.yield(.taskStarted(next.id))
                            let prompt = Self.prompt(goal: goal, task: next, graph: graph)
                            let bus = bus, worker = worker
                            group.addTask {
                                let agentID = "worker.\(next.id)"
                                do {
                                    let endpoint = try await bus.register(agent: agentID)
                                    defer { Task { await bus.unregister(agent: agentID) } }
                                    return (next.id, .success(try await worker(next, prompt, endpoint)))
                                } catch { return (next.id, .failure(error)) }
                            }
                        }
                        guard running > 0, let (id, outcome) = await group.next() else { break }
                        running -= 1
                        switch outcome {
                        case .success(let output):
                            graph.update(id) { $0.status = .done; $0.result = output }
                            continuation.yield(.taskFinished(id: id, summary: String(output.prefix(300))))
                            _ = try? await lead?.publish(topic: "task/\(id)", type: .result, body: String(output.prefix(2_000)))
                        case .failure(let error):
                            let current = graph.task(id)
                            let blocked = error as? SwarmBlocked
                            if blocked == nil, let current, current.attempts < attemptsPerTask {
                                graph.update(id) { $0.status = .pending }   // one more try
                            } else {
                                let reason = blocked?.reason ?? AgentRetry.explain(error)
                                graph.update(id) { $0.status = .blocked; $0.result = reason }
                                graph.skipDependents(of: id)
                                continuation.yield(.taskBlocked(id: id, reason: reason))
                                _ = try? await lead?.publish(topic: "swarm", type: .blocker, body: "\(id) is blocked: \(reason)")
                            }
                        }
                    }
                }
                // Anything still pending (cancelled run) is skipped, not left looking in-progress.
                for pending in graph.tasks where pending.status == .pending || pending.status == .running {
                    graph.update(pending.id) { $0.status = .skipped }
                }
                continuation.yield(.finished(graph))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
