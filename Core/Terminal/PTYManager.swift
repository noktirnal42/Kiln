import Foundation

public struct TerminalSessionInfo: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var shell: String
    public var workingDirectory: String

    public init(id: UUID, title: String, shell: String, workingDirectory: String) {
        self.id = id
        self.title = title
        self.shell = shell
        self.workingDirectory = workingDirectory
    }
}

public enum TerminalError2: Error, Equatable, Sendable {
    case sessionNotFound(UUID)
}

/// Owns live PTY sessions and per-workspace input history. Actor-isolated.
/// Session cwd is constrained to a workspace root that must exist; this pins
/// the starting directory but is not a full security boundary — sandbox
/// backends arrive with the Phase 4 swarming engine.
public actor PTYManager {
    public static let historyLimit = 500

    private var sessions: [UUID: PTYSession] = [:]
    private var sessionInfos: [UUID: TerminalSessionInfo] = [:]
    private var histories: [String: [CommandHistoryEntry]] = [:]
    private let historyBaseDirectory: URL

    public init(historyBaseDirectory: URL? = nil) {
        if let historyBaseDirectory {
            self.historyBaseDirectory = historyBaseDirectory
        } else if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            self.historyBaseDirectory = appSupport.appendingPathComponent("SuperMetaApp/TerminalHistory", isDirectory: true)
        } else {
            self.historyBaseDirectory = FileManager.default.temporaryDirectory
        }
    }

    public func allSessions() -> [TerminalSessionInfo] {
        sessionInfos.values.sorted { $0.title < $1.title }
    }

    public func session(_ id: UUID) -> PTYSession? {
        sessions[id]
    }

    public func sessionInfo(_ id: UUID) -> TerminalSessionInfo? {
        sessionInfos[id]
    }

    @discardableResult
    public func createSession(
        title: String? = nil,
        shell: String? = nil,
        workspaceRoot: String,
        environment: [String: String] = [:]
    ) async throws -> TerminalSessionInfo {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspaceRoot, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TerminalError.workspaceRootInvalid(workspaceRoot)
        }
        let resolvedShell = shell ?? ShellDetection.detectShell()
        guard FileManager.default.isExecutableFile(atPath: resolvedShell) else {
            throw TerminalError.shellNotFound(resolvedShell)
        }
        let session = PTYSession(shell: resolvedShell, workingDirectory: workspaceRoot)
        try session.start(environment: environment)
        let info = TerminalSessionInfo(
            id: session.id,
            title: title ?? "Terminal \(sessionInfos.count + 1)",
            shell: resolvedShell,
            workingDirectory: workspaceRoot
        )
        sessions[session.id] = session
        sessionInfos[session.id] = info
        return info
    }

    public func closeSession(_ id: UUID) {
        sessions[id]?.close()
        sessions.removeValue(forKey: id)
        sessionInfos.removeValue(forKey: id)
    }

    public func closeAll() {
        for id in sessions.keys {
            closeSession(id)
        }
    }

    // MARK: Command history (per workspace root)

    public func recordInput(_ line: String, workspaceRoot: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = histories[workspaceRoot] ?? loadHistory(workspaceRoot: workspaceRoot)
        history.append(CommandHistoryEntry(line: String(trimmed.prefix(4096))))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        histories[workspaceRoot] = history
        saveHistory(history, workspaceRoot: workspaceRoot)
    }

    public func history(workspaceRoot: String) -> [CommandHistoryEntry] {
        histories[workspaceRoot] ?? loadHistory(workspaceRoot: workspaceRoot)
    }

    private func historyURL(workspaceRoot: String) -> URL {
        let encoded = Self.directoryName(for: workspaceRoot)
        return historyBaseDirectory.appendingPathComponent("\(encoded).json")
    }

    static func directoryName(for workspaceRoot: String) -> String {
        workspaceRoot
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func loadHistory(workspaceRoot: String) -> [CommandHistoryEntry] {
        guard let data = try? Data(contentsOf: historyURL(workspaceRoot: workspaceRoot)) else { return [] }
        return (try? JSONDecoder().decode([CommandHistoryEntry].self, from: data)) ?? []
    }

    private func saveHistory(_ history: [CommandHistoryEntry], workspaceRoot: String) {
        let url = historyURL(workspaceRoot: workspaceRoot)
        do {
            let directory = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try JSONEncoder().encode(history).write(to: url, options: .atomic)
        } catch {
            ModuleLogger(moduleIdentifier: "com.supermeta.terminal")
                .error("history persist failed: \(String(describing: error))")
        }
    }
}
