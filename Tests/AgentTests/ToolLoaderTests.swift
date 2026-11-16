import Foundation
import Testing
@testable import Kiln

private final class ToolsSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var rounds: [[String]] = []
    var perRound: [[String]] { lock.lock(); defer { lock.unlock() }; return rounds }
    let script: @Sendable (Int) -> ChatChunk
    private func record(_ names: [String]) -> Int { lock.lock(); defer { lock.unlock() }; rounds.append(names); return rounds.count }
    init(script: @escaping @Sendable (Int) -> ChatChunk) { self.script = script }
    var factory: @Sendable (ChatRequest) async throws -> AsyncThrowingStream<ChatChunk, Error> {
        let me = self
        return { request in
            let chunk = me.script(me.record(request.tools.map(\.name)))
            return AsyncThrowingStream { $0.yield(chunk); $0.finish() }
        }
    }
}

@MainActor
struct ToolLoaderTests {
    private func allTools() async -> [ToolSpec] { await CapabilityRegistryTests.fullToolRegistry().allSpecs() }
    private func tokens(_ specs: [ToolSpec]) -> Int { ContextCompactor.toolSchemaTokens(specs.map(\.providerTool)) }

    @Test func aHugeWindowOffersEverythingAndABigOneLoadsOnDemand() async {
        let specs = await allTools()
        #expect(ToolLoader(offered: specs, window: 1_000_000) == nil, "the whole toolbox is under a tenth of a million tokens")
        #expect(ToolLoader(offered: specs, window: 128_000) != nil)
        #expect(ToolLoader(offered: specs, window: 8_192) != nil)
    }

    @Test func aRunStartsWithTheBasicsAndTheSearchToolOnly() async throws {
        let specs = await allTools()
        let loader = try #require(ToolLoader(offered: specs, window: 128_000))
        let names = Set(loader.initial().map(\.name))
        #expect(names.contains("read_file") && names.contains(ToolLoader.searchToolName))
        #expect(!names.contains("mail_recent") && !names.contains("re_open_binary"))
        #expect(tokens(loader.initial()) < 5_500, "was \(tokens(specs)) with every tool; now \(tokens(loader.initial()))")
        #expect(tokens([loader.searchSpec]) < 900, "the catalog of groups stays small")
        #expect(loader.searchSpec.detail.contains("mail (5)"))
    }

    @Test func searchingByWordLoadsTheMatchingToolsAndNamesThem() async throws {
        let specs = await allTools()
        let loader = try #require(ToolLoader(offered: specs, window: 128_000))
        let reply = loader.search("email")
        #expect(reply.hasPrefix("Loaded "))
        #expect(reply.contains("mail_recent") && reply.contains("mail_send"))
        let names = Set(loader.offered().map(\.name))
        #expect(names.isSuperset(of: ["mail_recent", "mail_send", "read_file", ToolLoader.searchToolName]))
        #expect(!names.contains("notes_create"), "only what was asked for")
        #expect(loader.search("email") .hasPrefix("Loaded "), "searching again is harmless")
        #expect(loader.offered().filter { $0.name == "mail_send" }.count == 1)
    }

    @Test func selectLoadsExactNamesAndAnUnknownSearchListsTheGroups() async throws {
        let specs = await allTools()
        let loader = try #require(ToolLoader(offered: specs, window: 128_000))
        let reply = loader.search("select:notes_recent, notes_search")
        #expect(reply.hasPrefix("Loaded 2 tools"))
        #expect(Set(loader.offered().map(\.name)).isSuperset(of: ["notes_recent", "notes_search"]))
        let none = loader.search("zzzzzz")
        #expect(none.hasPrefix("No tool matches") && none.contains("mail"))
    }

    @Test func callingAToolThatIsNotLoadedLoadsItAndShowsItsArguments() async throws {
        let specs = await allTools()
        let loader = try #require(ToolLoader(offered: specs, window: 128_000))
        #expect(loader.isDeferredAndNotLoaded("calendar_events"))
        let text = try #require(loader.loadNamed("calendar_events"))
        #expect(text.contains("did not run") && text.contains("call it again") && text.contains("calendar_events("))
        #expect(!loader.isDeferredAndNotLoaded("calendar_events"))
        #expect(loader.loadNamed("read_file") == nil, "basic tools are never deferred")
    }

    @Test func theMeterAndBudgetCountOnlyWhatIsLoaded() async {
        let orchestrator = AgentOrchestrator(toolRegistry: await CapabilityRegistryTests.fullToolRegistry())
        let budget = orchestrator.contextBudget(profile: .workstationAgent(), contextWindow: 128_000)
        #expect(budget.toolSchemaTokens < 5_500, "was about 21,500 before on-demand loading; now \(budget.toolSchemaTokens)")
        let small = orchestrator.contextBudget(profile: .workstationAgent(), contextWindow: 8_192)
        #expect(small.toolSchemaTokens <= Int(8_192 * ToolFit.defaultShare) + 900)
        #expect(small.available > 1_000)
    }

    @Test func aRunLoadsToolsWhenAskedAndTheNextRequestCarriesThem() async throws {
        let (center, watcher) = try await makeTestApprovalCenter(autoResolve: .approveOnce)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(toolRegistry: await CapabilityRegistryTests.fullToolRegistry(), approvalCenter: center)
        let seen = ToolsSeen { round in
            if round == 1 {
                return ChatChunk(delta: ChatMessage(role: .assistant, content: ""), finishReason: .toolCalls,
                                 toolCalls: [ToolCall(id: "s1", name: ToolLoader.searchToolName, arguments: #"{"query":"notes"}"#)])
            }
            return ChatChunk(delta: ChatMessage(role: .assistant, content: "Loaded them."), finishReason: .stop)
        }
        var events: [AgentEvent] = []
        for try await event in orchestrator.run(profile: .workstationAgent(), prompt: "find my notes about dinner", workspaceRoot: nil,
                                                contextWindow: 128_000, roundLimit: 5, chat: seen.factory) { events.append(event) }
        let rounds = seen.perRound
        #expect(rounds.count == 2)
        #expect(rounds[0].contains(ToolLoader.searchToolName) && !rounds[0].contains("notes_recent"))
        #expect(rounds[1].contains("notes_recent") && rounds[1].contains("notes_search"), "round two carries the loaded tools: \(rounds[1].count) tools")
        let finished = events.compactMap { e -> ToolCallRecord? in if case .toolCallFinished(let r) = e { return r }; return nil }
        #expect(finished.first?.toolName == ToolLoader.searchToolName && finished.first?.status == .succeeded)
        #expect(finished.first?.resultText?.contains("notes_recent") == true)
        #expect(events.contains { if case .toolsFitted(let offered, let total) = $0 { return offered < total }; return false })
    }
}
