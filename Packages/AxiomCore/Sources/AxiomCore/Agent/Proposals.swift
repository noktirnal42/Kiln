import Foundation

/// An edit an agent proposes instead of making directly. It waits in the project (`proposals.json`) for the analyst to accept or
/// reject it; accepting applies it through the normal revision-checked, logged edit path with the agent as provenance.
public struct EditProposal: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, accepted, rejected, withdrawn, failed }
    public var id: String
    public var created: Date
    /// rename_function, set_comment, set_signature, annotate_address or change_variable.
    public var kind: String
    public var address: String
    public var name: String?
    public var comment: String?
    public var label: String?
    public var type: String?
    public var variableId: String?
    public var signature: String?
    public var rationale: String
    /// Addresses (or short notes) the agent cites as evidence.
    public var evidence: [String]
    /// Who proposed it, e.g. "agent:claude-code".
    public var source: String
    /// Proposals sharing a group are accepted or rejected together, atomically.
    public var groupId: String?
    public var status: Status
    public var decidedAt: Date?
    public var note: String?
    public var resultRevision: Int?

    /// Human-readable one-line description for review lists.
    public var summary: String {
        switch kind {
        case "rename_function": return "Rename function 0x\(address) to \(name ?? "?")"
        case "set_comment": return "Set function comment on 0x\(address)"
        case "set_signature": return "Retype function 0x\(address) as \(signature ?? "?")"
        case "annotate_address":
            return "Annotate 0x\(address)" + (label.map { " label “\($0)”" } ?? "") + (comment.map { " comment “\($0)”" } ?? "")
        case "change_variable":
            return "Variable \(variableId ?? "?") in 0x\(address)" + (name.map { " → \($0)" } ?? "") + (type.map { " : \($0)" } ?? "")
        default: return kind + " 0x" + address
        }
    }
    public var operation: ProjectStore.EditOperation? {
        switch kind {
        case "rename_function": return .function(address: address, name: name, comment: nil, signature: nil)
        case "set_comment": return .function(address: address, name: nil, comment: comment, signature: nil)
        case "set_signature": return .function(address: address, name: nil, comment: nil, signature: signature)
        case "annotate_address": return .addressNote(address: address, comment: comment, label: label)
        case "change_variable": return variableId.map { .variable(address: address, id: $0, name: name, type: type) }
        default: return nil
        }
    }
}

public enum ProposalStore {
    public static let kinds = ["rename_function", "set_comment", "set_signature", "annotate_address", "change_variable"]
    static let maxProposals = 2_000
    static func file(_ project: String) -> URL { URL(fileURLWithPath: project).appendingPathComponent("proposals.json") }

    public static func list(project: String, status: EditProposal.Status? = nil) throws -> [EditProposal] {
        guard let data = try? Data(contentsOf: file(project)) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let all = try decoder.decode([EditProposal].self, from: data)
        return status.map { s in all.filter { $0.status == s } } ?? all
    }

    private static func write(_ proposals: [EditProposal], project: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(proposals).write(to: file(project), options: .atomic)
    }
    private static func locked<T>(_ project: String, _ body: () throws -> T) throws -> T {
        let lockPath = URL(fileURLWithPath: project).appendingPathComponent(".proposals-lock").path
        let deadline = Date().addingTimeInterval(5)
        while mkdir(lockPath, 0o700) != 0 {
            guard Date() < deadline else { throw AxiomError.message("Proposals are being updated. Retry shortly; remove a stale .proposals-lock after a crash.") }
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { try? FileManager.default.removeItem(atPath: lockPath) }
        return try body()
    }

    /// Records a proposal after validating it against the project exactly as acceptance would (a dry run on an in-memory copy).
    @discardableResult
    public static func propose(project: String, kind: String, address: String, name: String? = nil, comment: String? = nil, label: String? = nil, type: String? = nil,
                               variableId: String? = nil, signature: String? = nil, rationale: String, evidence: [String] = [], source: String, groupId: String? = nil) throws -> EditProposal {
        guard kinds.contains(kind) else { throw AxiomError.message("Unknown proposal kind \(kind). Use one of: \(kinds.joined(separator: ", ")).") }
        guard !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rationale.count <= 2_000 else { throw AxiomError.message("A proposal needs a rationale of 1–2000 characters.") }
        guard evidence.count <= 50, evidence.allSatisfy({ $0.count <= 200 }) else { throw AxiomError.message("At most 50 evidence items of 200 characters.") }
        var proposal = EditProposal(id: "prop_" + UUID().uuidString.prefix(8).lowercased(), created: Date(), kind: kind, address: address, name: name, comment: comment, label: label, type: type,
                                    variableId: variableId, signature: signature, rationale: rationale, evidence: evidence, source: source, groupId: groupId, status: .pending)
        guard let operation = proposal.operation else { throw AxiomError.message("This proposal kind needs its required fields (change_variable needs variableId).") }
        var scratch = try ProjectStore.load(project)
        try ProjectStore.apply(operation, to: &scratch)   // validation only; nothing is saved
        return try locked(project) {
            var all = try list(project: project)
            guard all.count < maxProposals else { throw AxiomError.message("Too many proposals; accept, reject or withdraw some first.") }
            proposal.created = Date(); all.append(proposal)
            try write(all, project: project)
            return proposal
        }
    }

    /// Withdraws a pending proposal (the proposing agent changed its mind).
    public static func withdraw(project: String, id: String) throws {
        try locked(project) {
            var all = try list(project: project)
            guard let index = all.firstIndex(where: { $0.id == id }) else { throw AxiomError.message("No proposal \(id).") }
            guard all[index].status == .pending else { throw AxiomError.message("Proposal \(id) is already \(all[index].status.rawValue).") }
            all[index].status = .withdrawn; all[index].decidedAt = Date()
            try write(all, project: project)
        }
    }

    /// Rejects pending proposals (and everything in their groups).
    public static func reject(project: String, ids: [String], reason: String? = nil) throws {
        try locked(project) {
            var all = try list(project: project)
            let targets = expand(ids, in: all)
            guard !targets.isEmpty else { throw AxiomError.message("No pending proposal matches.") }
            for index in all.indices where targets.contains(all[index].id) { all[index].status = .rejected; all[index].decidedAt = Date(); all[index].note = reason }
            try write(all, project: project)
        }
    }

    /// Accepts pending proposals (expanded to whole groups) as ONE atomic transaction: either every edit is applied, logged with the
    /// agent as source and its rationale, or none is and the proposals are marked failed with the reason.
    @discardableResult
    public static func accept(project: String, ids: [String]) throws -> Analysis {
        try locked(project) {
            var all = try list(project: project)
            let targets = expand(ids, in: all)
            guard !targets.isEmpty else { throw AxiomError.message("No pending proposal matches.") }
            let chosen = all.filter { targets.contains($0.id) }
            let steps = try chosen.map { proposal -> ProjectStore.EditStep in
                guard let operation = proposal.operation else { throw AxiomError.message("Proposal \(proposal.id) is malformed.") }
                return ProjectStore.EditStep(operation: operation, source: proposal.source, rationale: proposal.rationale)
            }
            do {
                let current = try ProjectStore.load(project)
                let result = try ProjectStore.transact(project, expectedRevision: current.revision, steps)
                for index in all.indices where targets.contains(all[index].id) { all[index].status = .accepted; all[index].decidedAt = Date(); all[index].resultRevision = result.revision }
                try write(all, project: project)
                return result
            } catch {
                for index in all.indices where targets.contains(all[index].id) { all[index].status = .failed; all[index].decidedAt = Date(); all[index].note = error.localizedDescription }
                try? write(all, project: project)
                throw error
            }
        }
    }

    /// Pending proposals named by `ids`, plus every pending proposal sharing a group with one of them.
    static func expand(_ ids: [String], in all: [EditProposal]) -> Set<String> {
        let named = all.filter { ids.contains($0.id) && $0.status == .pending }
        let groups = Set(named.compactMap(\.groupId))
        return Set(all.filter { $0.status == .pending && (ids.contains($0.id) || ($0.groupId.map(groups.contains) ?? false)) }.map(\.id))
    }
}
