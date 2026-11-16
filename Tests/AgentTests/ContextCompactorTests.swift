import Foundation
import Testing
@testable import Kiln

// MARK: - Builders

private func toolTurn(_ id: String, tool: String = "read_file", result: String) -> [ChatMessage] {
    [
        ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: id, name: tool, arguments: "{\"path\":\"\(id).txt\"}")]),
        ChatMessage(role: .tool, content: result, metadata: ["tool_call_id": id, "tool_name": tool]),
    ]
}

private func bulky(_ n: Int, _ ch: Character = "x") -> String { String(repeating: ch, count: n) }

/// Every tool message must follow the assistant message that asked for it (possibly after sibling results).
private func pairsIntact(_ messages: [ChatMessage]) -> Bool {
    var open: Set<String> = []
    for message in messages {
        switch message.role {
        case .assistant: open = Set(message.toolCalls.map(\.id))
        case .tool:
            guard let id = message.metadata["tool_call_id"], open.contains(id) else { return false }
        default: open = []
        }
    }
    return true
}

private final class SummaryCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _transcripts: [String] = []
    var transcripts: [String] { lock.lock(); defer { lock.unlock() }; return _transcripts }
    func add(_ text: String) { lock.lock(); _transcripts.append(text); lock.unlock() }
}

private struct SummaryFailed: Error {}

struct ContextCompactorEstimateTests {
    @Test func textIsAboutThreeAndAHalfCharactersPerToken() {
        #expect(ContextCompactor.estimateTokens(bulky(350)) == 100)
        #expect(ContextCompactor.estimateTokens("") == 0)
    }

    @Test func toolCallArgumentsCountTowardAMessage() {
        let plain = ChatMessage(role: .assistant, content: "ok")
        let withCall = ChatMessage(role: .assistant, content: "ok",
                                   toolCalls: [ToolCall(id: "1", name: "write_file", arguments: bulky(700))])
        #expect(ContextCompactor.estimateTokens(withCall) - ContextCompactor.estimateTokens(plain) >= 200)
    }

    @Test func budgetIsWindowMinusReplyMinusToolSchemas() {
        let tool = ProviderTool(name: "read_file", description: bulky(700), parameters: [:], required: [])
        let schema = ContextCompactor.toolSchemaTokens([tool])
        #expect(schema >= 200)
        let budget = ContextCompactor.budget(window: 10_000, maxTokens: 1_000, tools: [tool])
        #expect(budget.available == 10_000 - 1_000 - schema)
        #expect(budget.triggerTokens == Int(Double(budget.available) * 0.7))
    }

    @Test func aWindowSmallerThanItsReserveStillLeavesAFloor() {
        let budget = ContextBudget(window: 1_000, reservedForOutput: 4_096, toolSchemaTokens: 0)
        #expect(budget.available == 512)
    }
}

struct ContextCompactorStageTests {
    private let budget = ContextBudget(window: 4_000, reservedForOutput: 500, toolSchemaTokens: 0) // available 3500, trigger 2450

    @Test func underTheTriggerNothingChangesAndNoModelIsCalled() async {
        let log = SummaryCallLog()
        let messages = [ChatMessage(role: .user, content: "hi")]
        let outcome = await ContextCompactor.compact(messages, budget: budget) { text in log.add(text); return "s" }
        #expect(outcome.stage == .none)
        #expect(outcome.messages == messages)
        #expect(log.transcripts.isEmpty)
    }

    @Test func oldToolResultsBecomeStubsAndTheNewestFewStayWhole() {
        var messages: [ChatMessage] = [ChatMessage(role: .user, content: "go")]
        for i in 0..<7 { messages += toolTurn("c\(i)", result: bulky(1_000, Character(String(i)))) }
        let (cleared, count) = ContextCompactor.clearOldToolResults(messages)
        #expect(count == 3)
        let results = cleared.filter { $0.role == .tool }
        #expect(results[0].content == "[result cleared: read_file, 1000 chars]")
        #expect(results[2].content.hasPrefix("[result cleared:"))
        #expect(results[3].content == bulky(1_000, "3"))
        #expect(results[6].content == bulky(1_000, "6"))
        #expect(pairsIntact(cleared))
        // Metadata survives, so the pair still matches.
        #expect(results[0].metadata["tool_call_id"] == "c0")
    }

    @Test func shortResultsAreNotWorthAStub() {
        var messages: [ChatMessage] = []
        for i in 0..<6 { messages += toolTurn("c\(i)", result: "ok") }
        let (cleared, count) = ContextCompactor.clearOldToolResults(messages)
        #expect(count == 0)
        #expect(cleared == messages)
    }

    @Test func clearingAloneIsEnoughWhenItGetsUnderTheTrigger() async {
        var messages: [ChatMessage] = [ChatMessage(role: .system, content: "sys"), ChatMessage(role: .user, content: "go")]
        for i in 0..<8 { messages += toolTurn("c\(i)", result: bulky(1_400)) } // ~3200 tokens of results
        let log = SummaryCallLog()
        let outcome = await ContextCompactor.compact(messages, budget: budget) { text in log.add(text); return "s" }
        #expect(outcome.stage == .clearedToolResults)
        #expect(outcome.clearedResults == 4)
        #expect(outcome.tokensAfter < outcome.tokensBefore)
        #expect(outcome.tokensAfter <= budget.triggerTokens)
        #expect(log.transcripts.isEmpty)
        #expect(outcome.messages.count == messages.count)
    }

    @Test func whenClearingIsNotEnoughTheOlderPartIsSummarisedAndTheTailKeptVerbatim() async {
        var messages: [ChatMessage] = [ChatMessage(role: .system, content: "be careful"), ChatMessage(role: .user, content: "first ask")]
        for i in 0..<14 { messages += toolTurn("c\(i)", result: bulky(4_000)) }
        messages.append(ChatMessage(role: .assistant, content: "Here is where we are."))
        messages.append(ChatMessage(role: .user, content: "now do the last thing"))
        let before = ContextCompactor.estimateTokens(messages)
        #expect(before > budget.triggerTokens)

        let log = SummaryCallLog()
        let outcome = await ContextCompactor.compact(messages, budget: budget) { text in
            log.add(text); return "The user wants X. Files: a.txt."
        }
        #expect(outcome.stage == .summarized)
        #expect(log.transcripts.count == 1)
        #expect(log.transcripts.first?.contains("first ask") == true)
        #expect(outcome.summary?.contains("The user wants X") == true)
        // System message first, then exactly one summary, then the recent turns untouched.
        #expect(outcome.messages[0] == messages[0])
        #expect(outcome.messages[1].metadata[ContextMetadata.kind] == ContextMetadata.summaryKind)
        #expect(outcome.messages.last == messages.last)
        #expect(outcome.messages.filter { $0.metadata[ContextMetadata.kind] != nil }.count == 1)
        #expect(outcome.tokensAfter < outcome.tokensBefore)
        #expect(outcome.tokensAfter <= budget.available)
        #expect(pairsIntact(outcome.messages))
        #expect(outcome.messages[2].role != .tool)
        #expect(!outcome.replacedMessages.isEmpty)
        #expect(outcome.replacedMessages.first == messages[1])
    }

    @Test func anAssistantCallIsNeverSeparatedFromItsResultsAtAnyCutPoint() async {
        // Several tool calls in one assistant turn, with sizes chosen so cuts land in awkward places.
        for size in stride(from: 300, through: 2_400, by: 150) {
            var messages: [ChatMessage] = [ChatMessage(role: .user, content: "start")]
            for i in 0..<6 {
                let calls = (0..<3).map { ToolCall(id: "c\(i)_\($0)", name: "read_file", arguments: "{}") }
                messages.append(ChatMessage(role: .assistant, content: "", toolCalls: calls))
                for call in calls {
                    messages.append(ChatMessage(role: .tool, content: bulky(size), metadata: ["tool_call_id": call.id, "tool_name": "read_file"]))
                }
            }
            let small = ContextBudget(window: 2_000, reservedForOutput: 200, toolSchemaTokens: 0)
            let outcome = await ContextCompactor.compact(messages, budget: small) { _ in "sum" }
            #expect(pairsIntact(outcome.messages), "size \(size)")
        }
    }

    @Test func aFailedSummaryFallsBackToDroppingTheOldestPartWithAnHonestNote() async {
        var messages: [ChatMessage] = [ChatMessage(role: .user, content: "first ask")]
        for i in 0..<14 { messages += toolTurn("c\(i)", result: bulky(4_000)) }
        messages.append(ChatMessage(role: .user, content: "and finally"))
        let outcome = await ContextCompactor.compact(messages, budget: budget) { _ in throw SummaryFailed() }
        #expect(outcome.stage == .dropped)
        let note = outcome.messages.first { $0.metadata[ContextMetadata.kind] != nil }
        #expect(note?.content.contains("were dropped") == true)
        #expect(note?.content.contains("could not be summarised") == true)
        #expect(outcome.messages.last == messages.last)
        #expect(outcome.tokensAfter < outcome.tokensBefore)
        #expect(pairsIntact(outcome.messages))
    }

    @Test func anEmptySummaryCountsAsAFailure() async {
        var messages: [ChatMessage] = [ChatMessage(role: .user, content: "first ask")]
        for i in 0..<14 { messages += toolTurn("c\(i)", result: bulky(4_000)) }
        let outcome = await ContextCompactor.compact(messages, budget: budget) { _ in "  \n " }
        #expect(outcome.stage == .dropped)
    }

    @Test func forcingSummarisesEvenUnderTheTrigger() async {
        var messages: [ChatMessage] = []
        for i in 0..<6 {
            messages.append(ChatMessage(role: .user, content: "question \(i) " + bulky(900)))
            messages.append(ChatMessage(role: .assistant, content: "answer \(i) " + bulky(900)))
        }
        let roomy = ContextBudget(window: 5_500, reservedForOutput: 500, toolSchemaTokens: 0)
        let plain = await ContextCompactor.compact(messages, budget: roomy) { _ in "s" }
        #expect(plain.stage == .none)
        let forced = await ContextCompactor.compact(messages, budget: roomy, force: true) { _ in "Short summary." }
        #expect(forced.stage == .summarized)
        #expect(forced.messages.count < messages.count)
        #expect(forced.messages.last == messages.last)
    }

    @Test func aSecondCompactionFoldsThePreviousSummaryIn() async {
        var messages: [ChatMessage] = [ContextCompactor.restoredSummary("[Summary] earlier work on parser", covers: 4)]
        for i in 0..<14 { messages += toolTurn("c\(i)", result: bulky(4_000)) }
        messages.append(ChatMessage(role: .user, content: "keep going"))
        let log = SummaryCallLog()
        let outcome = await ContextCompactor.compact(messages, budget: budget) { text in log.add(text); return "merged" }
        #expect(outcome.stage == .summarized)
        #expect(log.transcripts.first?.contains("earlier work on parser") == true)
        #expect(outcome.messages.filter { $0.metadata[ContextMetadata.kind] != nil }.count == 1)
    }

    @Test func aHugeTranscriptIsCappedBeforeItIsSentToTheSummariser() async {
        var messages: [ChatMessage] = [ChatMessage(role: .user, content: "start")]
        for i in 0..<400 { messages += toolTurn("c\(i)", result: bulky(2_000)) }
        let small = ContextBudget(window: 3_000, reservedForOutput: 500, toolSchemaTokens: 0)
        let log = SummaryCallLog()
        _ = await ContextCompactor.compact(messages, budget: small) { text in log.add(text); return "s" }
        let sent = log.transcripts.first?.count ?? Int.max
        #expect(sent <= Int(Double(small.available) * 0.7 * ContextCompactor.charsPerToken) + 200)
    }

    @Test func theRequestSizeCountsMessagesAndTheToolList() {
        let messages = [ChatMessage(role: .system, content: "You are an agent."), ChatMessage(role: .user, content: "hello there")]
        let tool = ProviderTool(name: "read_file", description: String(repeating: "x", count: 700))
        let withTools = ContextCompactor.requestTokens(messages: messages, tools: [tool])
        #expect(withTools == ContextCompactor.estimateTokens(messages) + ContextCompactor.toolSchemaTokens([tool]))
        #expect(withTools > ContextCompactor.requestTokens(messages: messages, tools: []))
    }
}
