import Foundation
import Observation

/// State and actions behind the Audit & Monitor panel. All logic lives here so it can be tested
/// without a window; the view only renders and forwards clicks.
@MainActor
@Observable
public final class AuditPanelModel {
    /// What the chain's last check says. `notVerified` is the honest state until someone asks:
    /// showing "OK" without having verified would be a fake capability.
    public enum ChainStatus: Equatable {
        case noChain
        case notVerified
        case intact(checked: Int)
        case tampered(brokenSeq: Int)
        case truncated(expectedEvents: Int?)
        case unreadable(line: Int)
    }

    public struct EventRow: Identifiable, Equatable {
        public let id: Int          // seq
        public let timestamp: Date?
        public let type: String
        public let detail: String
        public let needsAttention: Bool
    }

    public static let rubricModelKey = "monitor.rubricModel"
    public static let rubricFallbackKey = "monitor.rubricFallbackModel"
    public static let recentLimit = 40

    private let chain: AuditChain?
    private let health: AuditHealth?
    private let settings: SettingsService?

    /// Display only: the policy is fixed by the app, not edited here.
    public let pauseAtSeverity: Int

    public private(set) var summary: AuditSummary?
    public private(set) var verification: AuditVerification?
    public private(set) var verifiedAt: Date?
    public private(set) var recentEvents: [EventRow] = []
    public private(set) var droppedEntries = 0
    public private(set) var lastFailure: String?
    public private(set) var errorMessage: String?
    public private(set) var exportStatus: String?
    public private(set) var isBusy = false

    public var rubricModel = ""
    public var rubricFallbackModel = ""
    public private(set) var settingsStatus: String?

    public init(chain: AuditChain?, health: AuditHealth?, settings: SettingsService?, pauseAtSeverity: Int = 5) {
        self.chain = chain
        self.health = health
        self.settings = settings
        self.pauseAtSeverity = pauseAtSeverity
    }

    public var hasChain: Bool { chain != nil }

    public var chainStatus: ChainStatus {
        guard chain != nil else { return .noChain }
        guard let verification else {
            // The cheap summary can already tell that rows were removed, without rehashing.
            if let summary, summary.truncated { return .truncated(expectedEvents: summary.expectedEvents) }
            return .notVerified
        }
        if let line = verification.unreadableLine { return .unreadable(line: line) }
        if verification.truncated { return .truncated(expectedEvents: verification.expectedEvents) }
        if let broken = verification.brokenSeq { return .tampered(brokenSeq: broken) }
        return verification.ok ? .intact(checked: verification.checked) : .notVerified
    }

    // MARK: Actions

    /// Cheap refresh: size, head, recent events, drop count, settings. Does not rehash the chain.
    public func refresh() async {
        errorMessage = nil
        let snapshot = health?.snapshot
        droppedEntries = snapshot?.dropped ?? 0
        lastFailure = snapshot?.lastFailure
        if let chain {
            do {
                summary = try await chain.summary()
                recentEvents = try await chain.recent(Self.recentLimit).reversed().map(Self.row)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if let settings {
            rubricModel = await settings.get(Self.rubricModelKey, as: String.self, fallback: "")
            rubricFallbackModel = await settings.get(Self.rubricFallbackKey, as: String.self, fallback: "")
        }
    }

    /// Full recomputation of every hash. Deliberate and on demand: it is O(n).
    public func verify() async {
        guard let chain else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            verification = try await chain.verify()
            verifiedAt = Date()
            summary = try await chain.summary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Writes a self-verifying bundle. A chain that is NOT intact is still exported, because
    /// evidence of tampering is exactly what an auditor wants, but the status says so plainly.
    public func export(to url: URL, signKey: Data? = nil) async {
        guard let chain else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let bundle = try await chain.export(signKey: signKey)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(bundle).write(to: url, options: .atomic)
            exportStatus = bundle.chainOK
                ? "Exported \(bundle.count) events. The chain was intact."
                : "Exported \(bundle.count) events. WARNING: the chain is NOT intact; the bundle records that."
        } catch {
            exportStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Persists the rubric monitor's models. Empty turns the model-based pass off.
    public func saveRubricSettings() async {
        guard let settings else { return }
        let model = rubricModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = rubricFallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await settings.set(model, forKey: Self.rubricModelKey)
            try await settings.set(fallback, forKey: Self.rubricFallbackKey)
            rubricModel = model
            rubricFallbackModel = fallback
            settingsStatus = model.isEmpty
                ? "Model-based monitoring is off."
                : "Saved. Takes effect on the next agent run."
        } catch {
            settingsStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Rows (pure)

    static func row(_ event: AuditEvent) -> EventRow {
        EventRow(id: event.seq, timestamp: parseTimestamp(event.ts), type: event.type,
                 detail: detail(for: event), needsAttention: needsAttention(event))
    }

    static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// Events worth a second look. Not a verdict: a policy denial is the policy working.
    static func needsAttention(_ event: AuditEvent) -> Bool {
        switch event.type {
        case "policy.denied", "monitor.paused", "monitor.review", "agent.run.failed": return true
        case "monitor.flag":
            if case .int(let severity)? = event.payload["severity"] { return severity >= 5 }
            return false
        default: return false
        }
    }

    /// One readable line per event type. Payloads are already redacted and clipped when recorded.
    static func detail(for event: AuditEvent) -> String {
        func text(_ key: String) -> String? {
            if case .string(let value)? = event.payload[key] { return value }
            return nil
        }
        func number(_ key: String) -> Int? {
            if case .int(let value)? = event.payload[key] { return value }
            return nil
        }
        let tool = text("tool") ?? "?"

        switch event.type {
        case "agent.run.started":
            return "profile \(text("profile") ?? "?") · mode \(text("mode") ?? "?")"
        case "agent.run.finished":
            return "\(number("rounds") ?? 0) rounds · \(number("tool_calls_executed") ?? 0) tool calls · \(number("tool_calls_denied") ?? 0) denied"
        case "agent.run.failed":
            return text("reason") ?? ""
        case "agent.round":
            return "round \(number("round") ?? 0)"
        case "tool.call":
            return "\(tool) \(identifyingArgument(event) ?? "")".trimmingCharacters(in: .whitespaces)
        case "tool.result":
            return "\(tool) → \(text("status") ?? "?")"
        case "policy.denied":
            return "\(tool) · rule \(text("rule") ?? "?")"
        case "approval.requested":
            var line = tool
            if case .bool(true)? = event.payload["destructive"] { line += " · destructive" }
            return line
        case "approval.decision", "monitor.review":
            return text("decision") ?? ""
        case "approval.resolved":
            if case .bool(let approved)? = event.payload["approved"] { return approved ? "approved" : "declined" }
            return ""
        case "monitor.flag":
            return "[\(text("category") ?? "?") \(number("severity") ?? 0)] \(text("rationale") ?? "")"
        case "monitor.paused":
            return "\(tool) held · severity \(number("severity") ?? 0)"
        case "monitor.assessed":
            return "round \(number("round") ?? 0) · \(number("flags") ?? 0) flags · worst \(number("worst") ?? 0)"
        case "provider.retry":
            return "attempt \(number("attempt") ?? 0) · \(text("reason") ?? "")"
        default:
            return event.payload.keys.sorted().joined(separator: ", ")
        }
    }

    private static func identifyingArgument(_ event: AuditEvent) -> String? {
        guard case .object(let arguments)? = event.payload["arguments"],
              case .object(let values)? = arguments["values"] else { return nil }
        for key in ["path", "command", "url", "pattern", "query", "glob", "branch"] {
            if case .string(let value)? = values[key] { return "\(key)=\(value)" }
        }
        return nil
    }
}
