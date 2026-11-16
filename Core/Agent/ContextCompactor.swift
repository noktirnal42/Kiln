import Foundation

// MARK: - Budget

/// How much of a model's context window a request may use, and when to start trimming.
public struct ContextBudget: Equatable, Sendable {
    /// The model's whole window, in tokens.
    public var window: Int
    /// Tokens held back for the reply (`profile.maxTokens`).
    public var reservedForOutput: Int
    /// Tokens the tool schemas take on every request.
    public var toolSchemaTokens: Int
    /// Fraction of `available` at which compaction starts.
    public var triggerFraction: Double

    public init(window: Int, reservedForOutput: Int, toolSchemaTokens: Int, triggerFraction: Double = 0.7) {
        self.window = window
        self.reservedForOutput = reservedForOutput
        self.toolSchemaTokens = toolSchemaTokens
        self.triggerFraction = triggerFraction
    }

    /// Room for messages: the window minus the reply and the tool schemas. Never below a small floor, so a
    /// window smaller than its own reserve doesn't make every request look over budget.
    public var available: Int { max(512, window - reservedForOutput - toolSchemaTokens) }
    public var triggerTokens: Int { Int(Double(available) * triggerFraction) }
}

// MARK: - What a compaction did

public enum CompactionStage: String, Codable, Equatable, Sendable {
    case none
    /// Older tool results were swapped for one-line stubs.
    case clearedToolResults
    /// The older part of the conversation became one summary message.
    case summarized
    /// The summary call failed, so the oldest part was dropped.
    case dropped
}

public struct CompactionOutcome: Sendable {
    public var messages: [ChatMessage]
    public var tokensBefore: Int
    public var tokensAfter: Int
    public var stage: CompactionStage
    public var clearedResults: Int
    /// The messages folded into the summary or dropped (not the stubbed ones), oldest first.
    public var replacedMessages: [ChatMessage]
    /// The summary, or the honest drop note.
    public var summary: String?

    public var didCompact: Bool { stage != .none }
}

/// Which messages a summary stands in for, so a conversation can rebuild its history as summary + later messages.
public enum ContextMetadata {
    /// Marks a synthetic summary (or drop note) message.
    public static let kind = "kiln_context"
    public static let summaryKind = "summary"
    /// Index (in the conversation's message list) of the message this one came from.
    public static let sourceIndex = "kiln_idx"
    /// On a summary: how many conversation messages it covers.
    public static let covers = "kiln_covers"
    /// Marks the new user prompt of the current run.
    public static let prompt = "kiln_prompt"
}

// MARK: - Compactor

/// Keeps a long agent run inside the model's context window. Pure: it never reaches for a model on its own, the
/// caller hands in the summariser, so every stage can be tested without one.
public enum ContextCompactor {
    public static let charsPerToken = 3.5
    /// Tool results this many messages back (counting tool messages) are kept in full.
    public static let recentToolResultsKept = 4
    /// Results shorter than this aren't worth a stub.
    public static let minimumClearableCharacters = 240
    /// Each message is clipped to this many characters in the transcript sent to the summariser.
    static let transcriptMessageCap = 2_400

    // MARK: Estimates

    public static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.utf8.count) / charsPerToken).rounded(.up))
    }

    /// Content plus tool-call names and arguments plus a few tokens of per-message framing.
    public static func estimateTokens(_ message: ChatMessage) -> Int {
        var total = 4 + estimateTokens(message.content)
        for call in message.toolCalls {
            total += 8 + estimateTokens(call.name) + estimateTokens(call.arguments)
        }
        return total
    }

    public static func estimateTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1) }
    }

    public static func toolSchemaTokens(_ tools: [ProviderTool]) -> Int {
        guard !tools.isEmpty, let data = try? JSONEncoder().encode(tools) else { return 0 }
        return Int((Double(data.count) / charsPerToken).rounded(.up))
    }

    /// What the next request carries: the messages (the system prompt is one of them) and the tool list. The context meter shows this
    /// both during a run and when idle, so the two agree.
    public static func requestTokens(messages: [ChatMessage], tools: [ProviderTool]) -> Int {
        estimateTokens(messages) + toolSchemaTokens(tools)
    }

    public static func budget(window: Int, maxTokens: Int, tools: [ProviderTool]) -> ContextBudget {
        ContextBudget(window: window, reservedForOutput: maxTokens, toolSchemaTokens: toolSchemaTokens(tools))
    }

    // MARK: Stage (a): clear old tool results

    public static func stub(tool: String, characters: Int) -> String {
        "[result cleared: \(tool.isEmpty ? "tool" : tool), \(characters) chars]"
    }

    static func isStub(_ message: ChatMessage) -> Bool { message.content.hasPrefix("[result cleared:") }

    /// Replaces the content of every tool result except the newest `keepRecent` with a short stub.
    public static func clearOldToolResults(
        _ messages: [ChatMessage], keepRecent: Int = recentToolResultsKept
    ) -> (messages: [ChatMessage], cleared: Int) {
        let toolIndexes = messages.indices.filter { messages[$0].role == .tool }
        let clearable = toolIndexes.dropLast(max(0, keepRecent))
        var result = messages
        var cleared = 0
        for index in clearable {
            let message = messages[index]
            guard !isStub(message), message.content.count >= minimumClearableCharacters else { continue }
            result[index].content = stub(tool: message.metadata["tool_name"] ?? "", characters: message.content.count)
            cleared += 1
        }
        return (result, cleared)
    }

    // MARK: Stage (b)/(c): where to cut

    /// The index where the verbatim tail starts. Never lands on a tool result (which would separate it from the
    /// assistant call that asked for it) and never inside the leading system messages. The tail holds roughly
    /// `tailTokens`, and always the latest user message when that fits comfortably.
    static func cutIndex(_ messages: [ChatMessage], tailTokens: Int) -> Int {
        let firstBody = messages.firstIndex { $0.role != .system } ?? messages.count
        var cut = messages.count
        var used = 0
        while cut > firstBody {
            let cost = estimateTokens(messages[cut - 1])
            if used + cost > tailTokens, cut < messages.count { break }
            used += cost
            cut -= 1
        }
        // Prefer to keep the latest user message verbatim when it isn't a huge detour.
        if let lastUser = messages.lastIndex(where: { $0.role == .user }), lastUser >= firstBody, lastUser < cut,
           estimateTokens(Array(messages[lastUser...])) <= tailTokens * 2 {
            cut = lastUser
        }
        // Never begin the tail on a tool result: walk back to the assistant call that owns it.
        while cut > firstBody, messages[cut].role == .tool { cut -= 1 }
        return max(cut, firstBody)
    }

    /// The text a summariser reads: one block per message, results and long turns clipped.
    public static func transcript(_ messages: [ChatMessage]) -> String {
        messages.map { message in
            var line: String
            switch message.role {
            case .user: line = "USER"
            case .assistant: line = "ASSISTANT"
            case .tool: line = "TOOL RESULT (\(message.metadata["tool_name"] ?? "tool"))"
            case .system: line = "SYSTEM"
            }
            var body = message.content
            if body.count > transcriptMessageCap {
                body = String(body.prefix(transcriptMessageCap)) + " …[\(message.content.count - transcriptMessageCap) more chars cut]"
            }
            line += ": " + body
            for call in message.toolCalls {
                line += "\n  called \(call.name)(\(String(call.arguments.prefix(400))))"
            }
            return line
        }.joined(separator: "\n\n")
    }

    public static let summaryInstructions = """
    You are compacting an agent conversation so work can continue in a smaller context window. Write a faithful, \
    dense summary of the transcript the user provides, for the agent that will continue it. Keep: the user's goal and \
    every instruction or preference they gave; decisions made and why; files read, created or changed (full paths); \
    commands run and what they showed; errors hit and how they were resolved; the current state; and the next steps \
    still open. Preserve exact names, paths, numbers and identifiers. Do not invent anything, do not address the user, \
    and do not call tools. Plain prose or short bullet lists, no preamble.
    """

    /// A stored summary (already wrapped) turned back into the message it was.
    public static func restoredSummary(_ content: String, covers: Int) -> ChatMessage {
        ChatMessage(role: .user, content: content,
                    metadata: [ContextMetadata.kind: ContextMetadata.summaryKind, ContextMetadata.covers: String(covers)])
    }

    static func summaryMessage(_ text: String) -> ChatMessage {
        ChatMessage(
            role: .user,
            content: "[Summary of the earlier conversation, written when the context window filled up]\n\n\(text)",
            metadata: [ContextMetadata.kind: ContextMetadata.summaryKind]
        )
    }

    static func dropNote(count: Int) -> ChatMessage {
        ChatMessage(
            role: .user,
            content: "[Context note: \(count) earlier message\(count == 1 ? "" : "s") were dropped to fit the model's context window and could not be summarised. You no longer have them. If you need something from that part of the work, re-read it or ask the user.]",
            metadata: [ContextMetadata.kind: ContextMetadata.summaryKind]
        )
    }

    // MARK: Compaction

    /// Brings `messages` under budget, doing as little as it takes.
    ///
    /// - Parameter force: run the summary stage even when under the trigger (the `/compact` command).
    /// - Parameter summarize: turns a transcript into a summary; throws or returns empty text on failure.
    public static func compact(
        _ messages: [ChatMessage],
        budget: ContextBudget,
        force: Bool = false,
        summarize: @Sendable (String) async throws -> String
    ) async -> CompactionOutcome {
        let before = estimateTokens(messages)
        func unchanged() -> CompactionOutcome {
            CompactionOutcome(messages: messages, tokensBefore: before, tokensAfter: before, stage: .none,
                              clearedResults: 0, replacedMessages: [], summary: nil)
        }
        if !force, before <= budget.triggerTokens { return unchanged() }

        // (a) Stub out old tool results.
        let (cleared, clearedCount) = clearOldToolResults(messages)
        let afterClear = estimateTokens(cleared)
        if !force, afterClear <= budget.triggerTokens {
            guard clearedCount > 0 else { return unchanged() }
            return CompactionOutcome(messages: cleared, tokensBefore: before, tokensAfter: afterClear,
                                     stage: .clearedToolResults, clearedResults: clearedCount, replacedMessages: [], summary: nil)
        }

        // (b) Summarise the older part, keep system messages and a recent tail verbatim.
        // Aim well under the trigger so we don't compact again on the very next round.
        let tailTarget = max(256, Int(Double(budget.available) * (force ? 0.10 : 0.25)))
        let cut = cutIndex(cleared, tailTokens: tailTarget)
        let firstBody = cleared.firstIndex { $0.role != .system } ?? cleared.count
        let systems = cleared.filter { $0.role == .system }
        let head = Array(cleared[firstBody..<cut])
        let tail = Array(cleared[cut...])
        guard !head.isEmpty else {
            // Nothing older to fold in: the most we can do is what stage (a) did.
            guard clearedCount > 0 else { return unchanged() }
            return CompactionOutcome(messages: cleared, tokensBefore: before, tokensAfter: afterClear,
                                     stage: .clearedToolResults, clearedResults: clearedCount, replacedMessages: [], summary: nil)
        }
        // Originals, not stubs, are what the covered-count bookkeeping refers to.
        let replaced = Array(messages[firstBody..<cut])

        var text = transcript(head)
        let transcriptCap = Int(Double(max(budget.available, 2_000)) * 0.7 * charsPerToken)
        if text.count > transcriptCap {
            // Keep how it began (the goal) and how it ended (the current state); cut the middle.
            let head = Int(Double(transcriptCap) * 0.3)
            text = String(text.prefix(head))
                + "\n\n[middle of the transcript omitted: it was too long to summarise in one call]\n\n"
                + String(text.suffix(transcriptCap - head))
        }
        let summaryText: String?
        do {
            let produced = try await summarize(text).trimmingCharacters(in: .whitespacesAndNewlines)
            summaryText = produced.isEmpty ? nil : produced
        } catch {
            summaryText = nil
        }

        let replacement: ChatMessage
        let stage: CompactionStage
        if let summaryText {
            replacement = summaryMessage(summaryText)
            stage = .summarized
        } else {
            // (c) The summary call failed: drop the older part and say so.
            replacement = dropNote(count: replaced.count)
            stage = .dropped
        }
        var result = systems + [replacement] + tail
        // A giant tail can still be over budget; stub whatever else is clearable.
        if estimateTokens(result) > budget.available {
            result = systems + [replacement] + clearOldToolResults(tail, keepRecent: 1).messages
        }
        return CompactionOutcome(
            messages: result, tokensBefore: before, tokensAfter: estimateTokens(result), stage: stage,
            clearedResults: clearedCount, replacedMessages: replaced, summary: replacement.content
        )
    }
}
