import Foundation

/// What an agent run actually did, read off its tool events: which tools were offered, which executed and how they ended,
/// which files were written, which commands ran. A model's prose is a claim; this is the evidence for or against it.
public struct RunEvidence: Equatable, Sendable {
    public struct Call: Equatable, Sendable {
        public var tool: String
        public var status: ToolCallStatus
        /// A path or command taken from the call's arguments (never contents or secrets).
        public var target: String?
        public var error: String?
    }

    public var toolsOffered: [String] = []
    public var calls: [Call] = []
    public var rounds = 0
    /// Turns that ended with prose and no tool call while tools were available.
    public var proseOnlyTurns = 0
    public var providerRetries = 0
    public var finalText = ""

    public static let writeTools: Set<String> = ["write_file", "edit_file", "delete_file"]
    public static let readTools: Set<String> = ["read_file", "list_directory", "glob_files", "grep_files", "search_workspace",
                                                "git_status", "git_diff", "git_log", "web_fetch", "web_search"]

    public var succeeded: [Call] { calls.filter { $0.status == .succeeded } }
    public var failed: [Call] { calls.filter { $0.status == .failed || $0.status == .denied } }
    public var filesWritten: [String] {
        Array(Set(succeeded.filter { Self.writeTools.contains($0.tool) }.compactMap(\.target))).sorted()
    }
    public var commandsRun: [Call] { succeeded.filter { $0.tool == "run_command" || $0.tool == "stream_command" || $0.tool == "background_command" } }
    public var didWrite: Bool { !succeeded.filter { Self.writeTools.contains($0.tool) }.isEmpty || !commandsRun.isEmpty }
    public var didRead: Bool {
        succeeded.contains { Self.readTools.contains($0.tool) || $0.tool.hasPrefix("re_") || $0.tool.hasPrefix("lab_") || $0.tool == "run_command" }
    }

    /// One line for the activity view, the swarm bus and later workers: counts, files, commands.
    public var summaryLine: String {
        if calls.isEmpty { return "evidence: no tools were executed" }
        var counts: [String: Int] = [:]
        for call in succeeded { counts[call.tool, default: 0] += 1 }
        var parts = ["tools: " + counts.sorted { $0.key < $1.key }.map { $1 > 1 ? "\($0)×\($1)" : $0 }.joined(separator: ", ")]
        if !failed.isEmpty { parts.append("\(failed.count) failed/denied") }
        if !filesWritten.isEmpty { parts.append("files written: " + filesWritten.prefix(6).joined(separator: ", ")) }
        if !commandsRun.isEmpty { parts.append("commands: " + commandsRun.prefix(3).compactMap(\.target).map { String($0.prefix(60)) }.joined(separator: "; ")) }
        return "evidence: " + parts.joined(separator: " · ")
    }
}

/// Builds `RunEvidence` from the event stream of one run.
public struct RunEvidenceCollector: Sendable {
    public private(set) var evidence = RunEvidence()
    private var turnToolCalls = 0
    private var turnText = false

    public init(toolsOffered: [String] = []) {
        evidence.toolsOffered = toolsOffered.sorted()
    }

    public mutating func record(_ event: AgentEvent) {
        switch event {
        case .roundStarted(let round):
            closeTurn()
            evidence.rounds = round
        case .textDelta: turnText = true
        case .textReset: turnText = false
        case .toolCallStarted: turnToolCalls += 1
        case .toolCallFinished(let record):
            evidence.calls.append(RunEvidence.Call(tool: record.toolName, status: record.status,
                                                   target: Self.target(of: record), error: record.errorText.map { String($0.prefix(200)) }))
        case .retryScheduled: evidence.providerRetries += 1
        case .finished(let summary):
            closeTurn()
            evidence.finalText = summary.finalText
        default: break
        }
    }

    private mutating func closeTurn() {
        if turnText && turnToolCalls == 0 && !evidence.toolsOffered.isEmpty { evidence.proseOnlyTurns += 1 }
        turnText = false
        turnToolCalls = 0
    }

    /// The path or command a call was about, from its argument JSON.
    static func target(of record: ToolCallRecord) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(record.argumentsJSON.utf8))) as? [String: Any] else { return nil }
        for key in ["path", "command", "file", "pattern", "project_id", "experiment_id"] {
            if let value = object[key] as? String, !value.isEmpty { return String(value.prefix(200)) }
        }
        return nil
    }
}

/// Why a worker's result is not trusted, in terms an operator can act on: whose fault was it?
public enum RunFailure: Equatable, Sendable, CustomStringConvertible {
    /// The provider or transport failed or returned nothing (not the model's reasoning).
    case providerReturnedNothing
    /// The model answered in prose and never used the tools it was given.
    case modelUsedNoTools
    /// The model wrote a tool call as text instead of calling the tool.
    case modelSimulatedToolCall
    /// A tool it called failed or was denied; the work was not completed.
    case toolFailed(tool: String, message: String)
    /// The summary claims changes that no successful write or command supports.
    case claimedWorkWithoutEvidence
    /// A required artifact is missing or empty after the run.
    case expectationNotMet(String)

    /// Classifies an error that ended a run before the verifier saw it, so operators get the same vocabulary.
    public static func classify(errorMessage: String) -> String {
        let m = errorMessage.lowercased()
        if m.contains("does not support tools") || m.contains("tool use is not supported") {
            return "Model limitation: this model does not support tool calling. Pick a tool-capable model."
        }
        if m.contains("timeout") || m.contains("timed out") || m.contains("connection") || m.contains("rate limit")
            || m.contains("invalid response") || m.contains("http ") {
            return "Provider/transport: \(errorMessage)"
        }
        return "Unverified: \(errorMessage)"
    }

    public var description: String {
        switch self {
        case .providerReturnedNothing:
            "Provider/transport: the model returned no text and made no tool calls (empty response). Retry, or check the provider and model."
        case .modelUsedNoTools:
            "Model limitation: it answered in prose and never executed a tool, so nothing it says about the project is verified. Try a model with stronger tool support."
        case .modelSimulatedToolCall:
            "Model limitation: it wrote a tool call as text instead of calling the tool. Try a model with stronger tool support."
        case .toolFailed(let tool, let message):
            "Tool failure: \(tool) failed (\(message)); the task was not completed."
        case .claimedWorkWithoutEvidence:
            "Unverified: the summary says files were changed, but no write or command succeeded in this run."
        case .expectationNotMet(let what):
            "Unverified: expected \(what), but it is not there after the run."
        }
    }
}

/// An artifact a task must leave behind, checked on disk after the worker finishes. Relative paths are inside the workspace.
public enum TaskExpectation: Equatable, Sendable {
    case fileExists(String)
    case fileNonEmpty(String)

    /// `file:<path>` (must exist) or `nonempty:<path>`, as a plan may state them.
    public init?(_ text: String) {
        if text.hasPrefix("file:") { self = .fileExists(String(text.dropFirst(5))) }
        else if text.hasPrefix("nonempty:") { self = .fileNonEmpty(String(text.dropFirst(9))) }
        else { return nil }
    }

    /// nil when satisfied, otherwise what was missing. Paths may not leave the workspace.
    public func unmet(in workspace: URL?) -> String? {
        let path: String
        switch self { case .fileExists(let p), .fileNonEmpty(let p): path = p }
        guard let workspace else { return "a workspace for \(path)" }
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { return "\(path) (outside the workspace)" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return "file \(path)" }
        if case .fileNonEmpty = self, !isDirectory.boolValue,
           ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) == 0 { return "non-empty file \(path)" }
        return nil
    }
}

public enum RunVerifier {
    /// Phrases that claim something was changed on disk.
    private static let claim = try! NSRegularExpression(
        pattern: #"\b(created|wrote|written|saved|updated|modified|edited|added|fixed|implemented|generated)\b.{0,80}\b[\w./-]+\.(swift|py|js|ts|md|txt|json|yml|yaml|html|css|c|h|rs|go|sh|toml)\b"#,
        options: [.caseInsensitive])

    /// Decides whether to trust a worker's result. `role` shapes what evidence is expected: an implementer that claims changes
    /// needs a successful write or command; any worker that was given tools and used none produced only prose.
    public static func verdict(evidence: RunEvidence, summary: String, role: SwarmRole,
                               expectations: [TaskExpectation] = [], workspace: URL?, simulatedToolCall: Bool) -> RunFailure? {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if simulatedToolCall { return .modelSimulatedToolCall }
        if text.isEmpty && evidence.calls.isEmpty { return .providerReturnedNothing }
        if let failure = evidence.failed.last, evidence.succeeded.isEmpty, role == .implementer {
            return .toolFailed(tool: failure.tool, message: failure.error ?? "failed")
        }
        if evidence.calls.isEmpty && !evidence.toolsOffered.isEmpty { return .modelUsedNoTools }
        if role == .implementer, !evidence.didWrite,
           claim.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return .claimedWorkWithoutEvidence
        }
        for expectation in expectations { if let missing = expectation.unmet(in: workspace) { return .expectationNotMet(missing) } }
        return nil
    }
}
