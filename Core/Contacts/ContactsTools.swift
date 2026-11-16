import Foundation

/// Read-only tools over the Contacts app. Results are limited and say plainly when Contacts access is missing.
public struct ContactsTool: ToolExecuting {
    public enum Kind: String, CaseIterable, Sendable { case status, search }
    public let kind: Kind
    let service: ContactsService

    public init(kind: Kind, service: ContactsService = ContactsService()) { self.kind = kind; self.service = service }

    public static func register(into registry: ToolRegistry, service: ContactsService = ContactsService()) {
        for kind in Kind.allCases { registry.register(ContactsTool(kind: kind, service: service)) }
    }

    public var spec: ToolSpec {
        switch kind {
        case .status: ToolSpec(name: "contacts_status", summary: "Say whether Kiln may read the Contacts app. Never prompts.", permission: .read)
        case .search: ToolSpec(name: "contacts_search", summary: "Find people in the user's Contacts by name, company or email (name, company, emails, phone numbers; at most 20). The first use may show the macOS permission prompt. Read-only; use it to find an address before drafting mail.",
                               parameters: [ToolParam(name: "query", description: "Part of a name, company or email address"), ToolParam(name: "limit", type: "integer", description: "1–20, default 10", required: false)], permission: .read)
        }
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        switch kind {
        case .status: return service.access.explanation
        case .search:
            let args = ToolArgs.object(from: argumentsJSON) ?? [:]
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw AgentRunError.permissionDenied("query is required.") }
            let access = await service.ensureAccess()
            guard access.isAuthorized else { return access.explanation }
            let found = try await service.search(query, limit: min(max(args["limit"] as? Int ?? 10, 1), 20))
            guard !found.isEmpty else { return "No contacts match \"\(query)\"." }
            return found.map { c in
                [c.name.isEmpty ? "(no name)" : c.name, c.organization, c.emails.joined(separator: ", "), c.phones.joined(separator: ", ")]
                    .filter { !$0.isEmpty }.joined(separator: " | ")
            }.joined(separator: "\n")
        }
    }
}
