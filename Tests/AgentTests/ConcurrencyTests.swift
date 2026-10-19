import Foundation
import Testing
@testable import Kiln

/// Records when each run's model turn starts; the first call blocks briefly
/// so overlap between runs would be visible in the timestamps.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [Date] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return stamps.count
    }

    var timestamps: [Date] {
        lock.lock(); defer { lock.unlock() }
        return stamps
    }

    /// Records the call; the FIRST call blocks for `holdSeconds` so a second
    /// overlapping run would show a near-zero gap.
    func record(holdSeconds: Double) {
        lock.lock()
        let isFirst = stamps.isEmpty
        stamps.append(Date())
        lock.unlock()
        if isFirst && holdSeconds > 0 {
            Thread.sleep(forTimeInterval: holdSeconds)
        }
    }
}

struct ConcurrencyLimiterTests {
    @Test func maxConcurrentTasksCapsOverlappingRunsOfOneProfile() async throws {
        let registry = ToolRegistry(tools: [])
        let orchestrator = AgentOrchestrator(toolRegistry: registry)
        let profile = AgentProfile(
            name: "single-lane",
            mode: .askOnly,
            toolPermissions: ToolPermissionSet(enabledTools: []),
            maxConcurrentTasks: 1
        )

        let log = CallLog()
        let chatFactory: @Sendable (ChatRequest) async throws -> AsyncThrowingStream<ChatChunk, Error> = { _ in
            log.record(holdSeconds: 0.5)
            return AsyncThrowingStream { c in
                c.yield(ChatChunk(delta: ChatMessage(role: .assistant, content: "ok"), finishReason: .stop))
                c.finish()
            }
        }

        async let first = collectRun(orchestrator, profile: profile, prompt: "one", chat: chatFactory)
        try await Task.sleep(nanoseconds: 100_000_000) // let run 1 start and hold its slot
        async let second = collectRun(orchestrator, profile: profile, prompt: "two", chat: chatFactory)

        let (events1, error1) = await first
        let (events2, error2) = await second
        #expect(error1 == nil)
        #expect(error2 == nil)
        #expect(events1.compactMap { ev -> AgentRunSummary? in if case .finished(let s) = ev { return s }; return nil }.count == 1)
        #expect(events2.compactMap { ev -> AgentRunSummary? in if case .finished(let s) = ev { return s }; return nil }.count == 1)

        // Both ran; the second must not have started while the first held
        // its slot (the first call blocks for 0.5s inside the provider).
        let stamps = log.timestamps
        #expect(stamps.count == 2)
        guard stamps.count == 2 else { return }
        let gap = stamps[1].timeIntervalSince(stamps[0])
        #expect(gap >= 0.3, "second run started only \(gap)s after the first — the concurrency cap did not hold")
    }

    @Test func differentProfilesRunIndependently() async throws {
        let orchestrator = AgentOrchestrator(toolRegistry: ToolRegistry(tools: []))
        let profileA = AgentProfile(name: "a", mode: .askOnly, toolPermissions: ToolPermissionSet(enabledTools: []), maxConcurrentTasks: 1)
        let profileB = AgentProfile(name: "b", mode: .askOnly, toolPermissions: ToolPermissionSet(enabledTools: []), maxConcurrentTasks: 1)

        let log = CallLog()
        let chatFactory: @Sendable (ChatRequest) async throws -> AsyncThrowingStream<ChatChunk, Error> = { _ in
            log.record(holdSeconds: 0.3)
            return AsyncThrowingStream { c in
                c.yield(ChatChunk(delta: ChatMessage(role: .assistant, content: "ok"), finishReason: .stop))
                c.finish()
            }
        }

        async let first = collectRun(orchestrator, profile: profileA, prompt: "one", chat: chatFactory)
        try await Task.sleep(nanoseconds: 80_000_000)
        async let second = collectRun(orchestrator, profile: profileB, prompt: "two", chat: chatFactory)

        _ = await first
        _ = await second
        let stamps = log.timestamps
        #expect(stamps.count == 2)
        guard stamps.count == 2 else { return }
        let gap = stamps[1].timeIntervalSince(stamps[0])
        #expect(gap < 0.25, "gap \(gap)s — different profiles should not queue behind each other")
    }
}
