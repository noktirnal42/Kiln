import Foundation
import SQLite3

// SQLite's `SQLITE_TRANSIENT` is a C macro that Swift cannot import directly.
nonisolated(unsafe) private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteError: Error, LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)
    case execute(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): "Could not open the library database: \(message)"
        case .prepare(let message): "Could not prepare a database statement: \(message)"
        case .step(let message): "Database statement failed: \(message)"
        case .execute(let message): "Database command failed: \(message)"
        }
    }
}

enum SQLValue {
    case text(String)
    case int(Int)
    case double(Double)
    case null
}

final class SQLiteDatabase {
    private(set) var handle: OpaquePointer?

    init(path: String) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            if let database { sqlite3_close_v2(database) }
            throw SQLiteError.open(message)
        }
        handle = database
        sqlite3_busy_timeout(database, 5_000)
        try execute("PRAGMA foreign_keys = ON;")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = NORMAL;")
        }
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw SQLiteError.execute("Database is closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw SQLiteError.execute(message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        guard let handle else { throw SQLiteError.prepare("Database is closed") }
        return try Statement(database: handle, sql: sql)
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    var userVersion: Int {
        get {
            guard let handle else { return 0 }
            let statement = try? Statement(database: handle, sql: "PRAGMA user_version;")
            guard let statement, (try? statement.step()) == true else { return 0 }
            return statement.columnInt(0)
        }
        set {
            try? execute("PRAGMA user_version = \(newValue);")
        }
    }
}

final class Statement {
    private let database: OpaquePointer
    private var statement: OpaquePointer?

    init(database: OpaquePointer, sql: String) throws {
        self.database = database
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, statement != nil else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(database)))
        }
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let string):
                result = string.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
                }
            case .int(let integer):
                result = sqlite3_bind_int64(statement, index, Int64(integer))
            case .double(let double):
                result = sqlite3_bind_double(statement, index, double)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw SQLiteError.step(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    @discardableResult
    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SQLiteError.step(String(cString: sqlite3_errmsg(database)))
        }
    }

    func run() throws {
        _ = try step()
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func columnText(_ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    func columnInt(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    func columnDouble(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func columnIsNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }
}
