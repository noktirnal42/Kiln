import Foundation

public struct BasicBlock: Codable, Identifiable, Sendable {
    public var id: String { address }
    public var address: String
    public var destinations: [String]
}

public struct FunctionRecord: Codable, Identifiable, Sendable {
    public var id: String { address }
    public var address: String
    public var name: String
    public var signature: String
    public var code: String
    public var assembly: String
    public var callers: [String]
    public var callees: [String]
    public var comment: String
    public var error: String?
    public var engineName: String?
    /// The engine's own signature text, kept apart from an analyst retyping (`signature`). nil on projects saved before this field existed.
    public var engineSignature: String?
    public var blocks: [BasicBlock]?
    public init(address: String, name: String, signature: String = "", code: String = "", assembly: String = "", callers: [String] = [], callees: [String] = [], comment: String = "", error: String? = nil) {
        self.address = address; self.name = name; self.engineName = name; self.signature = signature; self.engineSignature = signature; self.code = code; self.assembly = assembly; self.callers = callers; self.callees = callees; self.comment = comment; self.error = error
    }
}
/// One analyst change to a function field, kept so edits can be reviewed, undone and redone.
public struct AnalystEdit: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID().uuidString
    public var address: String
    public var field: String   // "name", "comment", "signature" (function-level), "addressComment" / "label" (address-level; `address` is then the normalized address), or "variable" (`address` is the function; old/new are `id<TAB>name<TAB>type`)
    public var old: String
    public var new: String
    public var date = Date()
    /// Who made the change when it was not the analyst in the app (e.g. "agent:claude-code" via MCP, or an accepted proposal); nil = the analyst.
    public var source: String?
    /// The agent's stated reason, when the edit came from an accepted proposal.
    public var rationale: String?
    public init(address: String, field: String, old: String, new: String) {
        self.address = address; self.field = field; self.old = old; self.new = new
        self.source = EditSource.current; self.rationale = EditSource.rationale
    }
}
/// Provenance for edits made inside a scope (task-local so deep call chains need no extra parameters): agent transports bind
/// `current` for the duration of a tool call; proposal acceptance binds both.
public enum EditSource {
    @TaskLocal public static var current: String?
    @TaskLocal public static var rationale: String?
}
/// An analyst rename and/or retype of one decompiler variable (parameter or local). Either part may be absent (= unchanged).
public struct VariableChange: Codable, Equatable, Sendable {
    public var name: String?
    public var type: String?
    public init(name: String? = nil, type: String? = nil) { self.name = name; self.type = type }
    public var isEmpty: Bool { (name ?? "").isEmpty && (type ?? "").isEmpty }
}
public struct StringRecord: Codable, Identifiable, Sendable {
    public var id: Int { offset }
    public var offset: Int
    public var value: String
    public init(offset: Int, value: String) { self.offset = offset; self.value = value }
}
public struct Analysis: Codable, Sendable {
    public var schemaVersion = 1
    public var id = UUID().uuidString
    public var revision = 0
    public var binaryPath: String
    public var sha256: String
    public var size: Int
    public var format: String
    public var engine: String
    public var created = Date()
    public var sections: String
    public var hex: String
    public var functions: [FunctionRecord]
    public var strings: [StringRecord]
    public var warnings: [String]
    public var engineProject: String?
    /// Analyst-bookmarked function addresses (normalized lowercase hex). Optional so older projects still decode.
    /// For universal binaries: every architecture present and the one that was analyzed. Nil for thin binaries.
    public var slices: [String]?
    public var slice: String?
    public var bookmarks: [String]?
    /// Reviewable analyst edit log and its redo stack (most recent last). Optional so older projects still decode.
    public var edits: [AnalystEdit]?
    public var undone: [AnalystEdit]?
    /// Analyst comments and labels on arbitrary addresses (instructions or data), keyed by normalized lowercase hex address.
    /// Kept apart from engine facts; optional so older projects still decode.
    public var addressComments: [String: String]?
    public var addressLabels: [String: String]?
    /// Analyst variable renames/retypes: function address (normalized) -> engine variable id -> change. Ids are the engine's
    /// own stable identifiers (a variable's original storage, e.g. "EDI:4" or "Stack[-0xc]:4"); they come from the live worker.
    public var variableChanges: [String: [String: VariableChange]]?
    public init(binaryPath: String, sha256: String, size: Int, format: String, engine: String, sections: String, hex: String, functions: [FunctionRecord], strings: [StringRecord], warnings: [String] = []) {
        self.binaryPath = binaryPath; self.sha256 = sha256; self.size = size; self.format = format; self.engine = engine; self.sections = sections; self.hex = hex; self.functions = functions; self.strings = strings; self.warnings = warnings
    }
}
public enum AxiomError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let value): return value } }
}
public enum ProjectStore {
    /// Creates a new project without replacing any existing analysis.
    public static func create(_ analysis: Analysis, to path: String) throws {
        guard mkdir(path, 0o700) == 0 else { throw AxiomError.message("Choose a new project folder; this path already exists or cannot be created.") }
        do { try save(analysis, to: path) }
        catch { try? FileManager.default.removeItem(atPath: path); throw error }
    }
    static func locked<T>(_ path: String, _ body: () throws -> T) throws -> T {
        let lockPath = URL(fileURLWithPath: path).appendingPathComponent(".edit-lock").path
        // Concurrent agent calls and the app can all want the project at once: wait briefly for the current writer instead of failing.
        let deadline = Date().addingTimeInterval(5)
        while mkdir(lockPath, 0o700) != 0 {
            guard Date() < deadline else { throw AxiomError.message("Project is being edited. Retry after the writer finishes; remove stale .edit-lock after a crash.") }
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { try? FileManager.default.removeItem(atPath: lockPath) }
        return try body()
    }
    public static func replace(_ analysis: Analysis, to path: String, expectedID: String, expectedRevision: Int, preserveAnnotations: Bool = false) throws -> Analysis {
        try locked(path) {
            let current = try load(path)
            guard current.id == expectedID, current.revision == expectedRevision else { throw AxiomError.message("Revision conflict: reload project before editing.") }
            guard current.sha256 == analysis.sha256 else { throw AxiomError.message("Binary changed since import. Create a new project for this binary.") }
            var result = analysis
            result.bookmarks = current.bookmarks; result.edits = current.edits; result.undone = current.undone
            result.addressComments = current.addressComments; result.addressLabels = current.addressLabels; result.variableChanges = current.variableChanges
            result.id = current.id; result.created = current.created; result.revision = current.revision + 1
            if preserveAnnotations {
                let previous = Dictionary(current.functions.map { (normalizedAddress($0.address), $0) }, uniquingKeysWith: { first, _ in first })
                for index in result.functions.indices {
                    result.functions[index].engineName = result.functions[index].name
                    if let old = previous[normalizedAddress(result.functions[index].address)] {
                        result.functions[index].comment = old.comment
                        if old.engineName == nil || old.name != old.engineName { result.functions[index].name = old.name }
                    }
                }
            }
            try save(result, to: path)
            return result
        }
    }
    public static func normalizedAddress(_ address: String) -> String {
        let value = address.lowercased().replacingOccurrences(of: "0x", with: "")
        return UInt64(value, radix: 16).map { String($0, radix: 16) } ?? value
    }
    public static func load(_ path: String) throws -> Analysis {
        let url = URL(fileURLWithPath: path).appendingPathComponent("analysis.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.size] as? Int ?? 0) <= 64 * 1024 * 1024 else { throw AxiomError.message("Project exceeds the 64 MiB limit.") }
        let result = try JSONDecoder().decode(Analysis.self, from: Data(contentsOf: url))
        guard result.schemaVersion == 1 else { throw AxiomError.message("Unsupported project schema.") }
        return result
    }
    public static func save(_ analysis: Analysis, to path: String) throws {
        let dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(analysis)
        guard data.count <= 64 * 1024 * 1024 else { throw AxiomError.message("Project exceeds the 64 MiB limit.") }
        try data.write(to: dir.appendingPathComponent("analysis.json"), options: .atomic)
    }
    /// One analyst edit as data, so edits can be composed into a transaction (agent proposals are stored and applied this way).
    public enum EditOperation: Codable, Equatable, Sendable {
        case function(address: String, name: String?, comment: String?, signature: String?)
        case addressNote(address: String, comment: String?, label: String?)
        case variable(address: String, id: String, name: String?, type: String?)
    }

    /// One step of a transaction with its own provenance (who asked, and why).
    public struct EditStep: Sendable {
        public var operation: EditOperation; public var source: String?; public var rationale: String?
        public init(operation: EditOperation, source: String? = nil, rationale: String? = nil) { self.operation = operation; self.source = source; self.rationale = rationale }
    }
    public static func transact(_ path: String, expectedRevision: Int, _ steps: [EditStep]) throws -> Analysis {
        try locked(path) {
            var project = try load(path)
            guard project.revision == expectedRevision else { throw AxiomError.message("Revision conflict: reload project before editing.") }
            for step in steps {
                try EditSource.$current.withValue(step.source ?? EditSource.current) { try EditSource.$rationale.withValue(step.rationale ?? EditSource.rationale) { try apply(step.operation, to: &project) } }
            }
            project.revision += 1
            try save(project, to: path)
            return project
        }
    }

    /// Applies several edits as ONE atomic change: every operation is validated and applied to an in-memory copy under the project
    /// lock; if any fails nothing is written. One revision bump covers the whole transaction.
    public static func transact(_ path: String, expectedRevision: Int, _ operations: [EditOperation]) throws -> Analysis {
        try locked(path) {
            var project = try load(path)
            guard project.revision == expectedRevision else { throw AxiomError.message("Revision conflict: reload project before editing.") }
            for operation in operations { try apply(operation, to: &project) }
            project.revision += 1
            try save(project, to: path)
            return project
        }
    }

    /// Validates and applies one operation to an in-memory project (no I/O, no revision change).
    public static func apply(_ operation: EditOperation, to project: inout Analysis) throws {
        switch operation {
        case let .function(address, name, comment, signature): try applyFunctionEdit(&project, address: address, name: name, comment: comment, signature: signature)
        case let .addressNote(address, comment, label): try applyAddressNote(&project, address: address, comment: comment, label: label)
        case let .variable(address, id, name, type): try applyVariableChange(&project, address: address, id: id, name: name, type: type)
        }
    }

    public static func edit(_ path: String, expectedRevision: Int, address: String, name: String? = nil, comment: String? = nil, signature: String? = nil) throws -> Analysis {
        try transact(path, expectedRevision: expectedRevision, [.function(address: address, name: name, comment: comment, signature: signature)])
    }
    /// Sets (or, with an empty string, removes) an analyst comment and/or label on any address. Every change is logged for
    /// review/undo like function edits. The address need not belong to a function (data can be labelled).
    public static func annotate(_ path: String, expectedRevision: Int, address: String, comment: String? = nil, label: String? = nil) throws -> Analysis {
        try transact(path, expectedRevision: expectedRevision, [.addressNote(address: address, comment: comment, label: label)])
    }
    /// Records an analyst rename and/or retype of one variable of a function (nil = leave that part as is; "" = clear it). Logged for
    /// review/undo. `id` is the engine's variable id (from the live worker's `variables`); it is stored verbatim.
    public static func changeVariable(_ path: String, expectedRevision: Int, address: String, id: String, name: String? = nil, type: String? = nil) throws -> Analysis {
        try transact(path, expectedRevision: expectedRevision, [.variable(address: address, id: id, name: name, type: type)])
    }

    static func applyFunctionEdit(_ project: inout Analysis, address: String, name: String?, comment: String?, signature: String?) throws {
        guard let index = project.functions.firstIndex(where: { normalizedAddress($0.address) == normalizedAddress(address) }) else { throw AxiomError.message("Unknown function address.") }
        if let name {
            guard !name.isEmpty, name.count <= 256, !name.contains("\n") else { throw AxiomError.message("Name must be 1–256 characters without newlines.") }
            if project.functions[index].name != name { project.edits = (project.edits ?? []) + [AnalystEdit(address: project.functions[index].address, field: "name", old: project.functions[index].name, new: name)]; project.undone = nil }
            project.functions[index].name = name
        }
        if let comment {
            guard comment.count <= 32_768 else { throw AxiomError.message("Comment exceeds 32 KiB.") }
            if project.functions[index].comment != comment { project.edits = (project.edits ?? []) + [AnalystEdit(address: project.functions[index].address, field: "comment", old: project.functions[index].comment, new: comment)]; project.undone = nil }
            project.functions[index].comment = comment
        }
        if let signature {
            guard !signature.isEmpty, signature.count <= 1024, !signature.contains("\n") else { throw AxiomError.message("Signature must be 1–1024 characters without newlines.") }
            if project.functions[index].signature != signature { project.edits = (project.edits ?? []) + [AnalystEdit(address: project.functions[index].address, field: "signature", old: project.functions[index].signature, new: signature)]; project.undone = nil }
            if project.functions[index].engineSignature == nil { project.functions[index].engineSignature = project.functions[index].signature }
            project.functions[index].signature = signature
        }
    }

    static func applyAddressNote(_ project: inout Analysis, address: String, comment: String?, label: String?) throws {
        let trimmed = address.lowercased().replacingOccurrences(of: "0x", with: "")
        guard !trimmed.isEmpty, trimmed.count <= 16, UInt64(trimmed, radix: 16) != nil else { throw AxiomError.message("Address must be hexadecimal.") }
        let key = normalizedAddress(address)
        if let comment {
            guard comment.count <= 1024, !comment.contains("\n") else { throw AxiomError.message("Comment must be at most 1024 characters on one line.") }
            let old = project.addressComments?[key] ?? ""
            if old != comment {
                project.edits = (project.edits ?? []) + [AnalystEdit(address: key, field: "addressComment", old: old, new: comment)]; project.undone = nil
                setAddressValue(&project.addressComments, key, comment)
            }
        }
        if let label {
            guard label.count <= 256, !label.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw AxiomError.message("Label must be at most 256 characters with no whitespace.") }
            let old = project.addressLabels?[key] ?? ""
            if old != label {
                project.edits = (project.edits ?? []) + [AnalystEdit(address: key, field: "label", old: old, new: label)]; project.undone = nil
                setAddressValue(&project.addressLabels, key, label)
            }
        }
    }
    private static func setAddressValue(_ map: inout [String: String]?, _ key: String, _ value: String) {
        var current = map ?? [:]
        if value.isEmpty { current[key] = nil } else { current[key] = value }
        map = current.isEmpty ? nil : current
    }

    static func applyVariableChange(_ project: inout Analysis, address: String, id: String, name: String?, type: String?) throws {
        let key = normalizedAddress(address)
        guard project.functions.contains(where: { normalizedAddress($0.address) == key }) else { throw AxiomError.message("Unknown function address.") }
        guard !id.isEmpty, id.count <= 128, !id.contains(where: { $0.isNewline || $0 == "\t" }) else { throw AxiomError.message("Variable id must be 1–128 characters without tabs or newlines.") }
        if let name { guard name.count <= 256, !name.contains(where: { $0.isWhitespace }) else { throw AxiomError.message("Variable name must be at most 256 characters with no whitespace.") } }
        if let type { guard type.count <= 256, !type.contains(where: { $0.isNewline || $0 == "\t" }) else { throw AxiomError.message("Type must be at most 256 characters on one line.") } }
        let old = project.variableChanges?[key]?[id] ?? VariableChange()
        var new = old
        if let name { new.name = name.isEmpty ? nil : name }
        if let type { new.type = type.isEmpty ? nil : type }
        if new != old {
            project.edits = (project.edits ?? []) + [AnalystEdit(address: key, field: "variable", old: encode(id, old), new: encode(id, new))]; project.undone = nil
            setVariable(&project.variableChanges, key, id, new)
        }
    }
    static func encode(_ id: String, _ change: VariableChange) -> String { [id, change.name ?? "", change.type ?? ""].joined(separator: "\t") }
    static func decode(_ text: String) -> (id: String, change: VariableChange) {
        let parts = text.components(separatedBy: "\t")
        return (parts.first ?? "", VariableChange(name: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil, type: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil))
    }
    private static func setVariable(_ map: inout [String: [String: VariableChange]]?, _ function: String, _ id: String, _ change: VariableChange) {
        var all = map ?? [:]
        var forFunction = all[function] ?? [:]
        if change.isEmpty { forFunction[id] = nil } else { forFunction[id] = change }
        all[function] = forFunction.isEmpty ? nil : forFunction
        map = all.isEmpty ? nil : all
    }

    /// Adds or removes a bookmark on an existing function; returns the updated project.
    public static func toggleBookmark(_ path: String, expectedRevision: Int, address: String) throws -> Analysis {
        try locked(path) {
            var project = try load(path)
            guard project.revision == expectedRevision else { throw AxiomError.message("Revision conflict: reload project before editing.") }
            let key = normalizedAddress(address)
            guard project.functions.contains(where: { normalizedAddress($0.address) == key }) else { throw AxiomError.message("Unknown function address.") }
            var marks = project.bookmarks ?? []
            if let index = marks.firstIndex(of: key) { marks.remove(at: index) } else { marks.append(key) }
            project.bookmarks = marks.isEmpty ? nil : marks
            project.revision += 1
            try save(project, to: path)
            return project
        }
    }
    /// Reverts the most recent analyst edit (or re-applies the most recently undone one). Returns the updated project.
    public static func undo(_ path: String, expectedRevision: Int) throws -> Analysis { try step(path, expectedRevision, redo: false) }
    public static func redo(_ path: String, expectedRevision: Int) throws -> Analysis { try step(path, expectedRevision, redo: true) }
    private static func step(_ path: String, _ expectedRevision: Int, redo: Bool) throws -> Analysis {
        try locked(path) {
            var project = try load(path)
            guard project.revision == expectedRevision else { throw AxiomError.message("Revision conflict: reload project before editing.") }
            guard let edit = redo ? project.undone?.last : project.edits?.last else { throw AxiomError.message(redo ? "Nothing to redo." : "Nothing to undo.") }
            let value = redo ? edit.new : edit.old
            if edit.field == "addressComment" { setAddressValue(&project.addressComments, edit.address, value) }
            else if edit.field == "label" { setAddressValue(&project.addressLabels, edit.address, value) }
            else if edit.field == "variable" { let decoded = decode(value); setVariable(&project.variableChanges, edit.address, decoded.id, decoded.change) }
            else {
                guard let index = project.functions.firstIndex(where: { $0.address == edit.address }) else { throw AxiomError.message("The edited function no longer exists.") }
                switch edit.field { case "name": project.functions[index].name = value; case "signature": project.functions[index].signature = value; default: project.functions[index].comment = value }
            }
            if redo { project.undone?.removeLast(); project.edits = (project.edits ?? []) + [edit] }
            else { project.edits?.removeLast(); project.undone = (project.undone ?? []) + [edit] }
            if project.undone?.isEmpty == true { project.undone = nil }
            project.revision += 1
            try save(project, to: path)
            return project
        }
    }
}
