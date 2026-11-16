import Foundation
import Testing
@testable import Kiln

struct RoundLimitSettingTests {
    @Test func resolveClampsAndUnderstandsDefaultAndUnlimited() {
        #expect(RoundLimit.resolve(nil) == 200)
        #expect(RoundLimit.resolve(0) == Int.max)
        #expect(RoundLimit.resolve(1) == RoundLimit.minimum)
        #expect(RoundLimit.resolve(99_999) == RoundLimit.maximum)
        #expect(RoundLimit.resolve(50) == 50)
        #expect(RoundLimit.label(nil) == "200 steps")
        #expect(RoundLimit.label(0) == "No pause")
    }

    @Test func storedPerProfileAndRemovable() throws {
        let defaults = try #require(TestDefaults.suite("kiln.tests.roundlimit.\(UUID().uuidString)"))
        #expect(RoundLimit.stored(profileName: "A", defaults: defaults) == nil)
        RoundLimit.store(100, profileName: "A", defaults: defaults)
        RoundLimit.store(0, profileName: "B", defaults: defaults)
        #expect(RoundLimit.stored(profileName: "A", defaults: defaults) == 100)
        #expect(RoundLimit.stored(profileName: "B", defaults: defaults) == 0)
        RoundLimit.store(nil, profileName: "A", defaults: defaults)
        #expect(RoundLimit.stored(profileName: "A", defaults: defaults) == nil)
    }

    @Test func anOldSavedProfileWithoutTheFieldStillDecodes() throws {
        let data = try JSONEncoder().encode(AgentProfile(name: "x"))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "roundLimit")
        let decoded = try JSONDecoder().decode(AgentProfile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.roundLimit == nil)
    }
}

@MainActor
struct RoundLimitSessionTests {
    @Test func aRunPausesAtTheSettingAndKeepGoingResumesWithoutTyping() async throws {
        let project = try PlatformTestSupport.tempDir("ws")
        try PlatformTestSupport.write("hello", to: project.appendingPathComponent("a.txt"))
        var stub = PlatformSessionFactory.Stub()
        stub.reply = { request in
            // After a "Continue." the model finishes; otherwise it keeps reading.
            if request.messages.last(where: { $0.role == .user })?.content == "Continue." { return ChatMessage(role: .assistant, content: "Finished.") }
            return ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: UUID().uuidString, name: "read_file", arguments: #"{"path":"a.txt"}"#, index: 0)])
        }
        let defaults = try #require(TestDefaults.suite("kiln.tests.roundlimit.session.\(UUID().uuidString)"))
        let chain = try PlatformTestSupport.auditChain()
        let session = try await PlatformSessionFactory.make(project: project, chain: chain, stub: stub, toolRegistry: ToolRegistry(tools: [ReadFileTool()]), autoResolve: .approveOnce, defaults: defaults)
        await session.setRoundLimit(RoundLimit.minimum)
        #expect(session.roundLimitSetting == RoundLimit.minimum)
        await session.send("read it forever")
        #expect(session.pausedAfterRounds == RoundLimit.minimum)
        #expect(session.messages.last?.content == AgentOrchestrator.pauseMessage(rounds: RoundLimit.minimum))
        await session.keepGoing()
        #expect(session.pausedAfterRounds == nil)
        #expect(session.messages.last?.content == "Finished.")
        let types = try await chain.recent(80).map(\.type)
        #expect(types.contains("agent.round_limit.changed"))
    }
}
