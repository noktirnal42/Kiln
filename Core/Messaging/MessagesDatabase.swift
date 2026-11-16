import Foundation
import SQLite3

public struct MessageChat: Identifiable, Equatable, Sendable {
    public var id: Int64            // chat ROWID
    public var guid: String         // e.g. "iMessage;-;+15550100199" or "iMessage;+;chat123"
    public var title: String        // display name, or the other person's number/email
    public var isGroup: Bool
    public var lastDate: Date?
    public var lastText: String
}

public struct ChatMessage2: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var text: String
    public var isFromMe: Bool
    public var sender: String       // handle (number or email); empty for your own messages
    public var date: Date?
    public var hasAttachment: Bool
}

public enum MessagesDatabaseError: Error, Equatable, LocalizedError {
    case needsFullDiskAccess, missing, query(String)
    public var errorDescription: String? {
        switch self {
        case .needsFullDiskAccess: "Kiln cannot read your Messages history. Turn on Full Disk Access for Kiln in System Settings, Privacy & Security, then reopen Kiln."
        case .missing: "No Messages history was found on this Mac. Open the Messages app and sign in first."
        case .query(let m): "Could not read Messages: \(m)"
        }
    }
}

/// Reads the Messages app's local database (`chat.db`) read-only. Apple documents no API for this: the schema can change between macOS
/// releases, and reading needs the Full Disk Access permission. Nothing here writes to the database.
public struct MessagesDatabase: Sendable {
    public let path: String
    public static var defaultPath: String { NSHomeDirectory() + "/Library/Messages/chat.db" }

    public init(path: String = MessagesDatabase.defaultPath) { self.path = path }

    /// Seconds between 1970 and 2001; message dates count from 2001, in nanoseconds on current macOS (seconds on very old files).
    static func date(fromAppleTime raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private func open() throws -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: path) else {
            // Without Full Disk Access the file exists but cannot be opened; a path that does not exist at all means no Messages data.
            throw MessagesDatabaseError.missing
        }
        var db: OpaquePointer?
        let code = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard code == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw code == SQLITE_CANTOPEN || code == SQLITE_PERM || code == SQLITE_AUTH ? MessagesDatabaseError.needsFullDiskAccess : MessagesDatabaseError.query("open failed (\(code))")
        }
        sqlite3_busy_timeout(db, 1500)
        // Opening can succeed while the first read is refused; probe once so the caller gets the permission message.
        var probe: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &probe, nil)
        sqlite3_finalize(probe)
        if rc == SQLITE_AUTH || rc == SQLITE_PERM || rc == SQLITE_CANTOPEN { sqlite3_close(db); throw MessagesDatabaseError.needsFullDiskAccess }
        return db
    }

    private func rows(_ sql: String, bind: [Int64] = [], _ read: (OpaquePointer) -> Void) throws {
        let db = try open()
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw msg.contains("authorization") || msg.contains("not authorized") ? MessagesDatabaseError.needsFullDiskAccess : MessagesDatabaseError.query(msg)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in bind.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), v) }
        while sqlite3_step(stmt) == SQLITE_ROW { read(stmt) }
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    private static func body(_ stmt: OpaquePointer, textColumn: Int32, blobColumn: Int32) -> String {
        let plain = text(stmt, textColumn)
        if !plain.isEmpty { return plain }
        let n = Int(sqlite3_column_bytes(stmt, blobColumn))
        guard n > 0, let p = sqlite3_column_blob(stmt, blobColumn) else { return "" }
        return AttributedBodyDecoder.text(from: Data(bytes: p, count: n)) ?? ""
    }

    /// The most recently active conversations.
    public func chats(limit: Int = 40) throws -> [MessageChat] {
        var out: [MessageChat] = []
        let sql = """
        SELECT c.ROWID, c.guid, c.chat_identifier, COALESCE(c.display_name, ''), c.style,
               (SELECT MAX(m.date) FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID WHERE j.chat_id = c.ROWID) AS last_date,
               (SELECT m.text FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID WHERE j.chat_id = c.ROWID ORDER BY m.date DESC LIMIT 1),
               (SELECT m.attributedBody FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID WHERE j.chat_id = c.ROWID ORDER BY m.date DESC LIMIT 1)
        FROM chat c WHERE last_date IS NOT NULL ORDER BY last_date DESC LIMIT \(max(1, min(limit, 200)))
        """
        try rows(sql) { s in
            let display = Self.text(s, 3), ident = Self.text(s, 2)
            out.append(MessageChat(id: sqlite3_column_int64(s, 0), guid: Self.text(s, 1), title: display.isEmpty ? ident : display,
                                   isGroup: sqlite3_column_int(s, 4) == 43, lastDate: Self.date(fromAppleTime: sqlite3_column_int64(s, 5)),
                                   lastText: Self.body(s, textColumn: 6, blobColumn: 7)))
        }
        return out
    }

    /// The newest `limit` messages of a conversation, oldest first.
    public func messages(inChat chatID: Int64, limit: Int = 60) throws -> [ChatMessage2] {
        try messages(where: "j.chat_id = ?1", bind: [chatID], limit: limit)
    }

    /// Messages with a ROWID above `rowID` in any conversation (to notice new arrivals), oldest first.
    public func messages(after rowID: Int64, limit: Int = 100) throws -> [ChatMessage2] {
        try messages(where: "m.ROWID > ?1", bind: [rowID], limit: limit)
    }

    public func latestRowID() throws -> Int64 {
        var value: Int64 = 0
        try rows("SELECT COALESCE(MAX(ROWID), 0) FROM message") { value = sqlite3_column_int64($0, 0) }
        return value
    }

    private func messages(where clause: String, bind: [Int64], limit: Int) throws -> [ChatMessage2] {
        var out: [ChatMessage2] = []
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, COALESCE(h.id, ''), m.date, m.cache_has_attachments
        FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE \(clause) ORDER BY m.date DESC LIMIT \(max(1, min(limit, 500)))
        """
        try rows(sql, bind: bind) { s in
            out.append(ChatMessage2(id: sqlite3_column_int64(s, 0), text: Self.body(s, textColumn: 1, blobColumn: 2), isFromMe: sqlite3_column_int(s, 3) == 1,
                                    sender: Self.text(s, 4), date: Self.date(fromAppleTime: sqlite3_column_int64(s, 5)), hasAttachment: sqlite3_column_int(s, 6) == 1))
        }
        return out.reversed()
    }
}

/// Newer macOS stores message text in `attributedBody`, an archived NSAttributedString, and leaves `text` empty.
/// This reads the string out of the archive without unarchiving it (unarchiving data from another app is avoided).
public enum AttributedBodyDecoder {
    public static func text(from data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard let start = find(marker, in: bytes) else { return nil }
        var i = start + marker.count
        // The class descriptor is followed by a few bytes, then 0x2B ('+') introduces the string payload.
        var scanned = 0
        while i < bytes.count, bytes[i] != 0x2B, scanned < 16 { i += 1; scanned += 1 }
        guard i < bytes.count, bytes[i] == 0x2B else { return nil }
        i += 1
        guard i < bytes.count else { return nil }
        var length = 0
        let first = bytes[i]; i += 1
        switch first {
        case 0x81: guard i + 2 <= bytes.count else { return nil }; length = Int(bytes[i]) | Int(bytes[i + 1]) << 8; i += 2
        case 0x82: guard i + 4 <= bytes.count else { return nil }; length = (0..<4).reduce(0) { $0 | Int(bytes[i + $1]) << (8 * $1) }; i += 4
        default: length = Int(first)
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        let text = String(decoding: bytes[i..<(i + length)], as: UTF8.self)
        return text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }
}
