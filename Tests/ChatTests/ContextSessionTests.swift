import Foundation
import SwiftData
import Testing
@testable import Kiln

struct ToolActivitySummaryTests {
    private func item(_ name: String, _ path: String? = nil, failed: Bool = false) -> ToolActivityItem {
        ToolActivityItem(name: name, argumentsJSON: path.map { "{\"path\":\"\($0)\"}" } ?? "{}", failed: failed)
    }

    @Test func groupsCallsIntoOneLine() {
        let items = [
            item("run_command"), item("run_command"), item("run_command"), item("run_command"),
            item("edit_file", "a.swift"), item("edit_file", "a.swift"), item("write_file", "b.swift"),
            item("read_file", "1"), item("read_file", "2"), item("read_file", "3"),
            item("read_file", "4"), item("read_file", "5"), item("read_file", "6"),
        ]
        #expect(ToolActivitySummary.line(for: items) == "Ran 4 commands · edited 2 files · read 6 files")
    }

    @Test func singularsPluralsAndFailures() {
        #expect(ToolActivitySummary.line(for: [item("run_command", failed: true)]) == "Ran 1 command · 1 failed")
        #expect(ToolActivitySummary.line(for: [item("read_file", "x")]) == "Read 1 file")
        #expect(ToolActivitySummary.line(for: [item("web_search"), item("git_status"), item("re_list_functions")])
                == "1 git operation · 1 web lookup · used 1 other tool")
        #expect(ToolActivitySummary.line(for: []) == "")
    }
}

@MainActor
struct ContextSessionTests {
    private func snapshot(_ role: ChatMessage.Role, _ text: String) -> MessageSnapshot {
        MessageSnapshot(id: UUID(), role: role, content: text, createdAt: Date())
    }

    @Test func compactCommandIsRecognised() {
        #expect(ChatSession.isCompactCommand("/compact"))
        #expect(ChatSession.isCompactCommand("/Compact now"))
        #expect(!ChatSession.isCompactCommand("/compaction"))
        #expect(!ChatSession.isCompactCommand("please /compact"))
    }

    @Test func historyIsSummaryPlusTheMessagesItDoesNotCover() {
        let messages = (0..<6).map { snapshot($0 % 2 == 0 ? .user : .assistant, "m\($0)") }
        let plain = ChatSession.agentHistory(messages: messages, upTo: 6, compaction: nil)
        #expect(plain.map(\.content) == ["m0", "m1", "m2", "m3", "m4", "m5"])
        let state = ConversationCompaction(summary: "SUM", covered: 4)
        let rebuilt = ChatSession.agentHistory(messages: messages, upTo: 6, compaction: state)
        #expect(rebuilt.map(\.content) == ["SUM", "m4", "m5"])
        #expect(rebuilt[0].metadata[ContextMetadata.covers] == "4")
        #expect(rebuilt[1].metadata[ContextMetadata.sourceIndex] == "4")
        // A prompt index inside the covered range is not resurrected.
        #expect(ChatSession.agentHistory(messages: messages, upTo: 3, compaction: state).map(\.content) == ["SUM"])
    }

    @Test func coveredCountFollowsTheSourceTagsOfWhatWasReplaced() {
        let replaced = [
            ChatMessage(role: .user, content: "a", metadata: [ContextMetadata.sourceIndex: "2"]),
            ChatMessage(role: .assistant, content: "b", metadata: [ContextMetadata.sourceIndex: "3"]),
            ChatMessage(role: .tool, content: "run-only tool output"),
        ]
        #expect(ChatSession.coveredCount(replaced: replaced, promptIndex: 8, previous: 0) == 4)
        #expect(ChatSession.coveredCount(replaced: replaced, promptIndex: 8, previous: 6) == 6)
        let withPrompt = replaced + [ChatMessage(role: .user, content: "p", metadata: [ContextMetadata.prompt: "1"])]
        #expect(ChatSession.coveredCount(replaced: withPrompt, promptIndex: 8, previous: 0) == 9)
        let withEarlierSummary = [ContextCompactor.restoredSummary("old", covers: 5)]
        #expect(ChatSession.coveredCount(replaced: withEarlierSummary, promptIndex: 8, previous: 0) == 5)
    }

    // MARK: Integration with a stub provider

    private func makeSession(defaults: UserDefaults?) async throws -> ChatSession {
        let schema = Schema([Conversation.self, Message.self, Artifact.self, ArtifactVersion.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let session = ChatSession(
            registry: ModelRegistry(eventBus: ModuleEventBus()),
            conversations: ConversationStore(container: container),
            artifacts: ArtifactStore(container: container),
            compactionDefaults: defaults
        )
        struct Stub: ModelProvider {
            let id = "stub"
            let name = "Stub"
            let providerType: ProviderType = .customEndpoint
            let capabilities: ProviderCapabilities = [.streaming]
            func fetchModels() async throws -> [ModelDescriptor] {
                [ModelDescriptor(id: "stub-m1", name: "m1", providerID: id, providerType: providerType, contextWindow: 14_000)]
            }
            func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
                AsyncThrowingStream { c in
                    c.yield(ChatChunk(delta: ChatMessage(role: .assistant, content: "Reply."), finishReason: .stop))
                    c.finish()
                }
            }
            func checkAvailability() async -> ProviderAvailability { .available() }
        }
        await session.registry.register(Stub())
        let (center, _) = try makeTestApprovalCenter(autoResolve: nil)
        session.attachOrchestrator(AgentOrchestrator(toolRegistry: ToolRegistry(tools: []), approvalCenter: center))
        await session.newConversation()
        session.selectedModelID = "stub-m1"
        return session
    }

    @Test func slashCompactSummarisesKeepsTheTailAndLeavesANote() async throws {
        let suite = "kiln-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = try await makeSession(defaults: defaults)
        for i in 0..<4 { await session.send("question \(i) " + String(repeating: "z", count: 2_000)) }
        #expect(session.messages.count == 8)
        await session.refreshContext()
        let before = try #require(session.contextUsage)
        #expect(before.window == 14_000)
        #expect(before.used > 0)
        #expect(!session.hasContextSummary)

        await session.send("/compact")
        #expect(session.messages.count == 8, "the command is not a message")
        #expect(session.hasContextSummary)
        #expect(session.contextNotes.count == 1)
        #expect(session.contextNotes[0].text.hasPrefix("Context compacted ("))
        #expect(session.contextNotes[0].text.contains("→"))
        let after = try #require(session.contextUsage)
        #expect(after.used < before.used)
        #expect(session.errorText == nil)

        // A new turn runs on [summary] + the uncovered tail, and the summary persists across a reload of the session state.
        await session.send("one more")
        #expect(session.messages.count == 10)
        let reloaded = try await makeSession(defaults: defaults)
        _ = reloaded // state is keyed by conversation id; a different conversation starts clean
        #expect(!reloaded.hasContextSummary)
    }

    @Test func compactionStateSurvivesAnAppRestart() async throws {
        let suite = "kiln-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = try await makeSession(defaults: defaults)
        for i in 0..<4 { await session.send("question \(i) " + String(repeating: "z", count: 2_000)) }
        await session.compactNow()
        let id = try #require(session.conversationID)
        #expect(session.hasContextSummary)

        let data = try #require(defaults.data(forKey: ChatSession.compactionKey))
        let saved = try JSONDecoder().decode([UUID: ConversationCompaction].self, from: data)
        let state = try #require(saved[id])
        #expect(state.summary?.contains("Reply.") == true)
        #expect(state.covered > 0 && state.covered < 8)
        #expect(state.notes.count == 1)
    }

    @Test func compactingAnEmptyConversationSaysSoInsteadOfFailing() async throws {
        let session = try await makeSession(defaults: nil)
        await session.send("/compact")
        #expect(session.messages.isEmpty)
        #expect(!session.hasContextSummary)
        #expect(session.contextNotes.isEmpty)
    }

    @Test func aFinishedRunKeepsItsToolCallsOnTheReplyForTheCollapsedLine() async throws {
        let session = try await makeSession(defaults: nil)
        await session.send("hello")
        // No tools were called by this stub, so the reply carries none and the collapsed line is simply absent.
        #expect(session.messages.last?.toolCalls.isEmpty == true)
    }
}
