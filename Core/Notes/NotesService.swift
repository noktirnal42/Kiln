import Foundation
import AppKit

public struct NoteSummary: Identifiable, Equatable, Sendable {
    public var id: String          // Notes' own identifier, e.g. "x-coredata://…/ICNote/p123"
    public var title: String
    public var folder: String
    public var modified: Date?
    public var isLocked: Bool
}

public enum NotesError: Error, Equatable, LocalizedError {
    case automationDenied, failed(String), notFound, locked, empty, badReply
    public var errorDescription: String? {
        switch self {
        case .automationDenied: "Kiln is not allowed to control Notes. Turn it on in System Settings, Privacy & Security, Automation."
        case .failed(let m): "Notes could not do that: \(m)"
        case .notFound: "That note was not found."
        case .locked: "That note is password protected. Kiln cannot read locked notes."
        case .empty: "The note needs some text."
        case .badReply: "Notes gave an answer Kiln could not read."
        }
    }
}

/// Runs AppleScript for the Notes app. The real one drives Notes (macOS asks once to allow it); tests substitute a fake.
public protocol NotesScripting: Sendable {
    func run(_ source: String) async throws -> String
}

public struct SystemNotesScripting: NotesScripting {
    public init() {}

    @MainActor static func execute(_ source: String) throws -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { throw NotesError.automationDenied }
            throw NotesError.failed((error[NSAppleScript.errorMessage] as? String) ?? "unknown error")
        }
        return result?.stringValue ?? ""
    }

    public func run(_ source: String) async throws -> String { try await MainActor.run { try Self.execute(source) } }
}

/// Reads and creates notes in the Notes app through its scripting interface. Apple documents no other access, so macOS updates can change
/// behaviour. Notes are only created, never edited or deleted, and locked notes are never read.
public struct NotesService: Sendable {
    let scripting: any NotesScripting
    public static let bodyLimit = 20_000
    static let fieldSeparator = "\u{1F}", recordSeparator = "\u{1E}"

    public init(scripting: any NotesScripting = SystemNotesScripting()) { self.scripting = scripting }

    // MARK: Scripts (pure, so tests can compile and inspect them)

    static func listScript(source: String, maximum: Int = 3000) -> String {
        """
        set rs to (ASCII character 30)
        set us to (ASCII character 31)
        set nowDate to current date
        tell application "Notes"
            set theNotes to \(source)
            set theIDs to id of theNotes
            set theNames to name of theNotes
            set theDates to modification date of theNotes
            set theLocks to password protected of theNotes
            set theFolders to name of container of theNotes
            set out to ""
            set total to count of theIDs
            if total > \(maximum) then set total to \(maximum)
            repeat with i from 1 to total
                set out to out & (item i of theIDs) & us & (item i of theNames) & us & ((item i of theDates) - nowDate) & us & (item i of theFolders) & us & (item i of theLocks) & rs
            end repeat
            return out
        end tell
        """
    }

    static func searchSource(_ query: String) -> String {
        let q = AppleScriptText.literal(query)
        return "(notes whose name contains \(q) or plaintext contains \(q))"
    }

    static func readScript(id: String) -> String {
        """
        tell application "Notes"
            set n to note id \(AppleScriptText.literal(id))
            if password protected of n then return "LOCKED"
            return (name of n) & (ASCII character 31) & (plaintext of n)
        end tell
        """
    }

    static func createScript(html: String, folder: String?) -> String {
        let target = folder.map { "at folder \(AppleScriptText.literal($0)) " } ?? ""
        return """
        tell application "Notes"
            set n to make new note \(target)with properties {body:\(AppleScriptText.literal(html))}
            return id of n
        end tell
        """
    }

    /// Title and text become HTML: the title as a heading, each line of text as its own block, everything escaped.
    static func html(title: String, body: String) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "<div><br></div>" : "<div>\(esc(String($0)))</div>" }
        return "<h1>\(esc(title))</h1>" + lines.joined()
    }

    // MARK: Operations

    static func parseList(_ raw: String) throws -> [NoteSummary] {
        var out: [NoteSummary] = []
        let now = Date()
        for record in raw.split(separator: Character(recordSeparator)) where !record.isEmpty {
            let f = record.split(separator: Character(fieldSeparator), omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { throw NotesError.badReply }
            // The script reports each modification time as seconds from "now" (a date difference), which has no locale or time-zone to get wrong.
            let delta = Double(f[2].replacingOccurrences(of: ",", with: ".")) ?? 0
            out.append(NoteSummary(id: f[0], title: f[1], folder: f[3], modified: now.addingTimeInterval(delta), isLocked: f[4].lowercased() == "true"))
        }
        return out.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    public func recent(limit: Int = 30) async throws -> [NoteSummary] {
        Array(try Self.parseList(try await scripting.run(Self.listScript(source: "notes"))).prefix(max(1, limit)))
    }

    public func search(_ query: String, limit: Int = 30) async throws -> [NoteSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return Array(try Self.parseList(try await scripting.run(Self.listScript(source: Self.searchSource(q)))).prefix(max(1, limit)))
    }

    public func read(id: String) async throws -> (title: String, text: String) {
        guard id.hasPrefix("x-coredata://"), !id.unicodeScalars.contains(where: { $0.value < 0x20 }) else { throw NotesError.notFound }
        let raw = try await scripting.run(Self.readScript(id: id))
        if raw == "LOCKED" { throw NotesError.locked }
        let parts = raw.split(separator: Character(Self.fieldSeparator), maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { throw NotesError.badReply }
        return (parts[0], String(parts[1].prefix(Self.bodyLimit)))
    }

    /// Creates a note (never edits or deletes one). Returns the new note's id.
    @discardableResult
    public func create(title: String, body: String, folder: String? = nil) async throws -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines), b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !b.isEmpty else { throw NotesError.empty }
        let f = folder?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        return try await scripting.run(Self.createScript(html: Self.html(title: t.isEmpty ? String(b.prefix(60)) : t, body: String(b.prefix(Self.bodyLimit))), folder: f)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
