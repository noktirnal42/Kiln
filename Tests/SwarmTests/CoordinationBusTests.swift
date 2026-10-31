import Foundation
import Testing
@testable import Kiln

struct CoordinationBusTests {
    private func collect(_ stream: AsyncStream<CoordinationMessage>, count: Int) async -> [CoordinationMessage] {
        var out: [CoordinationMessage] = []
        for await m in stream { out.append(m); if out.count == count { break } }
        return out
    }

    @Test func broadcastReachesOnlyTopicSubscribersAndNeverEchoesToSender() async throws {
        let bus = CoordinationBus()
        let a = try await bus.register(agent: "a"), b = try await bus.register(agent: "b"), c = try await bus.register(agent: "c")
        let bStream = try await b.subscribe(to: ["plan"])
        let cStream = try await c.subscribe(to: ["other"])
        let aStream = try await a.subscribe(to: ["plan"])
        try await a.publish(topic: "plan", type: .plan, body: "step 1")
        try await a.publish(topic: "plan", type: .plan, body: "step 2")

        let got = await collect(bStream, count: 2)
        #expect(got.map(\.body) == ["step 1", "step 2"])
        #expect(got.map(\.seq) == [1, 2])
        await bus.close()
        #expect(await collect(cStream, count: 1).isEmpty)
        #expect(await collect(aStream, count: 1).isEmpty, "no echo to the sender")
    }

    @Test func directMessagesGoToOneAgentButStayVisibleToTheOperator() async throws {
        let bus = CoordinationBus()
        let a = try await bus.register(agent: "a"), b = try await bus.register(agent: "b"), c = try await bus.register(agent: "c")
        let observer = await bus.observe()
        let bStream = try await b.subscribe(to: ["chat"]), cStream = try await c.subscribe(to: ["chat"])
        try await a.publish(topic: "chat", type: .question, body: "secret handshake", to: "b")

        #expect(await collect(bStream, count: 1).first?.body == "secret handshake")
        #expect(await collect(observer, count: 1).first?.to == "b")
        await bus.close()
        #expect(await collect(cStream, count: 1).isEmpty)
        #expect(await c.history().isEmpty, "other agents cannot read direct traffic")
        #expect(await bus.history().count == 1, "the operator can")
    }

    @Test func senderIsStampedAndIdsAreValidatedAndUnique() async throws {
        let bus = CoordinationBus()
        let a = try await bus.register(agent: "a")
        #expect(try await a.publish(topic: "t", type: .progress, body: "x").from == "a")
        await #expect(throws: CoordinationError.duplicateAgent("a")) { _ = try await bus.register(agent: "a") }
        await #expect(throws: CoordinationError.reservedAgentID("operator")) { _ = try await bus.register(agent: "operator") }
        await #expect(throws: CoordinationError.reservedAgentID("orchestrator-1")) { _ = try await bus.register(agent: "orchestrator-1") }
        await #expect(throws: CoordinationError.invalidAgentID("Bad Name")) { _ = try await bus.register(agent: "Bad Name") }
        await #expect(throws: CoordinationError.unknownRecipient("ghost")) { try await a.publish(topic: "t", type: .sync, body: "x", to: "ghost") }
    }

    @Test func secretsAreRedactedAndSizesBounded() async throws {
        let bus = CoordinationBus()
        let a = try await bus.register(agent: "a")
        let m = try await a.publish(topic: "t", type: .result, body: "key AKIAIOSFODNN7EXAMPLE", data: ["k": "AKIAIOSFODNN7EXAMPLE"])
        #expect(!m.body.contains("AKIAIOSFODNN7EXAMPLE"))
        #expect(m.data["k"] != "AKIAIOSFODNN7EXAMPLE")
        #expect(m.redactions >= 2)
        await #expect(throws: CoordinationError.bodyTooLarge(8_192)) {
            try await a.publish(topic: "t", type: .sync, body: String(repeating: "x", count: 9_000))
        }
    }

    @Test func aSlowSubscriberLosesItsOldestMessagesWithoutBlockingAnyone() async throws {
        var limits = CoordinationLimits(); limits.mailboxLimit = 3
        let bus = CoordinationBus(limits: limits)
        let a = try await bus.register(agent: "a"), b = try await bus.register(agent: "b")
        let stream = try await b.subscribe(to: ["t"])
        for i in 1...10 { try await a.publish(topic: "t", type: .progress, body: "m\(i)") }

        let stat = try #require(await bus.deliveryStats().first { $0.agent == "b" })
        #expect(stat.dropped == 7)
        await bus.close()
        #expect(await collect(stream, count: 10).map(\.body) == ["m8", "m9", "m10"], "newest kept")
    }

    @Test func historyIsCappedAndTheLossIsCounted() async throws {
        var limits = CoordinationLimits(); limits.historyLimit = 5
        let bus = CoordinationBus(limits: limits)
        let a = try await bus.register(agent: "a")
        for i in 1...8 { try await a.publish(topic: "t", type: .progress, body: "m\(i)") }
        #expect(await bus.history(limit: 100).map(\.seq) == [4, 5, 6, 7, 8])
        #expect(await bus.historyDropped == 3)
        #expect(await bus.messageCount == 8)
    }

    @Test func sharedMemoryIsCompareAndSetAndEveryWriteIsAMessage() async throws {
        let bus = CoordinationBus()
        let a = try await bus.register(agent: "a"), b = try await bus.register(agent: "b")
        let first = try await a.writeMemory("plan", "v1", expectedVersion: 0)
        #expect(first.version == 1 && first.updatedBy == "a")
        await #expect(throws: CoordinationError.versionConflict(key: "plan", expected: 0, current: 1)) {
            try await b.writeMemory("plan", "stolen", expectedVersion: 0)
        }
        #expect(try await b.writeMemory("plan", "v2", expectedVersion: 1).version == 2)
        #expect(await a.readMemory("plan")?.updatedBy == "b")
        #expect(await bus.history(topic: CoordinationBus.memoryTopic).count == 2, "conflicts are not writes")
        await #expect(throws: CoordinationError.invalidKey("Bad Key")) { try await a.writeMemory("Bad Key", 1) }
    }

    @Test func concurrentAtomicUpdatesAreNotLost() async throws {
        let bus = CoordinationBus()
        let a = try await bus.register(agent: "a")
        await withTaskGroup(of: Void.self) { group in
            for _ in 1...50 {
                group.addTask {
                    _ = try? await a.updateMemory("counter") { current in
                        if case .int(let n)? = current?.value { return .int(n + 1) }
                        return .int(1)
                    }
                }
            }
        }
        #expect(await a.readMemory("counter")?.value == .int(50))
        #expect(await a.readMemory("counter")?.version == 50)
    }

    @Test func everyMessageIsAuditedAndTheChainVerifies() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-bus-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chain = AuditChain(directory: dir)
        let recorder = AgentAuditRecorder(chain: chain, runID: "swarm-1")
        let bus = CoordinationBus(audit: recorder)
        let a = try await bus.register(agent: "a")
        try await a.publish(topic: "t", type: .plan, body: "hello")
        _ = try? await a.writeMemory("k", "v", expectedVersion: 5)   // conflict
        await recorder.finish()

        let types = try await chain.export().events.map(\.type)
        #expect(types == ["bus.message", "bus.memory.conflict"])
        #expect(try await chain.verify().ok)
    }
}
