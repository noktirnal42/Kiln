import Foundation
import Observation

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let level: LogLevel
    public let source: String
    public let message: String
    public let experimentID: String?
}

/// Backs the in-app "Activity" / "Runs" panel. Keeps a bounded in-memory
/// tail for the UI and mirrors every entry to a JSONL file on disk so a run's
/// full history survives past the in-memory cap and past app restarts.
@Observable
@MainActor
public final class ActivityLogger {
    public static let shared = ActivityLogger()

    public private(set) var recentEntries: [LogEntry] = []
    private let maxInMemory = 500
    private let sink = FileLogSink()

    private init() {}

    public func log(_ message: String, level: LogLevel = .info, source: String, experimentID: String? = nil) {
        let entry = LogEntry(timestamp: Date(), level: level, source: source, message: message, experimentID: experimentID)
        recentEntries.append(entry)
        if recentEntries.count > maxInMemory {
            recentEntries.removeFirst(recentEntries.count - maxInMemory)
        }
        Task.detached(priority: .utility) { [sink] in
            await sink.append(entry)
        }
    }

    public func clear() {
        recentEntries.removeAll()
    }
}

/// Off-main-thread append-only writer for the day's activity log file.
private actor FileLogSink {
    private let fileURL: URL
    private let formatter: ISO8601DateFormatter

    init() {
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        self.fileURL = LibraryPaths.logs.appendingPathComponent("activity-\(day).jsonl")
        self.formatter = ISO8601DateFormatter()
    }

    func append(_ entry: LogEntry) {
        let record: [String: String] = [
            "timestamp": formatter.string(from: entry.timestamp),
            "level": entry.level.rawValue,
            "source": entry.source,
            "message": entry.message,
            "experimentID": entry.experimentID ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        guard let lineData = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(lineData)
            }
        } else {
            try? lineData.write(to: fileURL)
        }
    }
}
