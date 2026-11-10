import SwiftUI

extension Activity { static let audit = Activity("audit") }

/// Audit: what agents did, and whether the tamper-evident record is intact. Agents get no tools here on purpose.
enum AuditActivity {
    static let descriptor = ActivityDescriptor(
        id: "audit", title: "Audit", symbol: "checkmark.seal",
        summary: "What agents did, and whether the record is intact",
        moduleIdentifier: nil,
        content: .custom { _ in AnyView(AuditActivityView()) },
        starterPrompts: { _ in
            [StarterPrompt(title: "What did agents do?", symbol: "checkmark.shield",
                           text: "Read my recent agent activity and tell me anything that looks risky or surprising.")]
        },
        capabilities: [
            .exempt("audit.browse", "Browse the audit record", .read,
                    because: "Gap: agent-facing audit queries are not built yet (docs/13). Until they are, an agent can only see its own run's tool results."),
            .exempt("audit.verify", "Verify the audit chain", .read,
                    because: "Gap: no verification tool yet (docs/13). It would be read-only; the chain itself stays append-only for agents."),
            .exempt("audit.configure", "Change audit settings", .admin,
                    because: "Deliberate: an agent must never alter the policy that records or gates its own actions."),
        ])
}
