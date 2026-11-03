import Foundation

/// What the file looked like when Kiln last read or wrote it; used to notice that something else changed it.
public struct FileStamp: Equatable, Sendable {
    public var modified: Date
    public var size: UInt64

    public static func of(_ url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? UInt64 else { return nil }
        return FileStamp(modified: modified, size: size)
    }
}

public enum EditorError: Error, Equatable, LocalizedError {
    case changedOnDisk
    case notEditable
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .changedOnDisk: "The file changed on disk after you opened it. Reload it, or choose Overwrite to keep your version."
        case .notEditable: "This file cannot be edited here."
        case .writeFailed(let reason): "Could not save: \(reason)"
        }
    }
}

/// One open file. Owns its text, the last saved text, and the disk stamp, so unsaved edits survive moving between
/// tools and an outside change (an agent, git, another editor) is noticed instead of silently overwritten.
@MainActor @Observable
public final class EditorDocument: Identifiable {
    public enum Status: Equatable, Sendable {
        case editable
        case binary
        case tooLarge(bytes: UInt64)
        case unreadable(String)
    }

    public static let maxBytes: UInt64 = 2_000_000

    public nonisolated let id = UUID()
    public let url: URL
    public var text: String
    public private(set) var savedText: String
    public private(set) var status: Status
    /// The file changed on disk while there were unsaved edits.
    public private(set) var conflict = false
    /// The file no longer exists on disk.
    public private(set) var deletedOnDisk = false
    /// Text restored from a previous session's unsaved work.
    public var restoredFromRecovery = false
    private var stamp: FileStamp?
    private var permissions: Int?

    public var isDirty: Bool { status == .editable && text != savedText }
    public var name: String { url.lastPathComponent }
    public var isEditable: Bool { status == .editable }

    public init(url: URL) {
        self.url = url
        let loaded = Self.read(url)
        self.text = loaded.text
        self.savedText = loaded.text
        self.status = loaded.status
        self.stamp = FileStamp.of(url)
        self.permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    static func read(_ url: URL) -> (text: String, status: Status) {
        guard let stamp = FileStamp.of(url) else { return ("", .unreadable("The file does not exist.")) }
        if stamp.size > maxBytes { return ("", .tooLarge(bytes: stamp.size)) }
        guard let data = try? Data(contentsOf: url) else { return ("", .unreadable("Permission denied or the file is not readable.")) }
        // A NUL byte in the first 8 KB is how git and most editors recognise binary content.
        if data.prefix(8192).contains(0) { return ("", .binary) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return ("", .unreadable("The text encoding is not supported."))
        }
        return (text, .editable)
    }

    // MARK: Saving

    /// Writes the text. Refuses when the file changed on disk since it was read, unless `overwrite` is true.
    public func save(overwrite: Bool = false) throws {
        guard status == .editable else { throw EditorError.notEditable }
        if !overwrite, FileManager.default.fileExists(atPath: url.path), FileStamp.of(url) != stamp {
            conflict = true
            throw EditorError.changedOnDisk
        }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        } catch {
            throw EditorError.writeFailed(error.localizedDescription)
        }
        savedText = text
        stamp = FileStamp.of(url)
        conflict = false
        deletedOnDisk = false
    }

    // MARK: External changes

    public enum ExternalChange: Equatable, Sendable { case none, reloaded, conflict, deleted }

    /// Compares the disk with what was last read. Clean documents reload silently; edited ones raise a conflict.
    @discardableResult
    public func checkForExternalChange() -> ExternalChange {
        guard status == .editable || status == .binary else { return .none }
        guard FileManager.default.fileExists(atPath: url.path) else {
            deletedOnDisk = true
            return .deleted
        }
        deletedOnDisk = false
        guard FileStamp.of(url) != stamp else { return .none }
        if isDirty {
            conflict = true
            return .conflict
        }
        reload()
        return .reloaded
    }

    /// Replaces the text with what is on disk and drops unsaved edits.
    public func reload() {
        let loaded = Self.read(url)
        text = loaded.text
        savedText = loaded.text
        status = loaded.status
        stamp = FileStamp.of(url)
        conflict = false
        deletedOnDisk = false
    }

    /// Keeps the user's text but accepts the disk's new state as the baseline (after "Keep mine").
    public func keepMineAfterConflict() {
        stamp = FileStamp.of(url)
        conflict = false
    }

    /// Puts recovered text back as unsaved edits.
    public func applyRecovered(_ recovered: String) {
        guard status == .editable, recovered != text else { return }
        text = recovered
        restoredFromRecovery = true
    }
}
