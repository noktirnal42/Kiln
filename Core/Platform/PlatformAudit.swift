import Foundation

/// Audit records for platform features (memory, commands, hooks, checkpoints, sessions, usage). Anything that
/// changes state records one entry in the tamper-evident chain: what changed and where, never file contents or prompts.
public struct PlatformAudit: Sendable {
    public let chain: AuditChain?
    public init(chain: AuditChain?) { self.chain = chain }

    /// Fire and forget: a refused entry must never block the user's action. Returns once the entry is appended
    /// so tests (and callers that need ordering) can wait for it.
    public func record(_ type: String, _ payload: [String: AuditValue] = [:], runID: String? = nil) async {
        guard let chain else { return }
        _ = try? await chain.append(type: type, payload: payload, runID: runID ?? "platform")
    }
}
