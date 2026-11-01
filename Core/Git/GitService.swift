import Foundation

public struct GitFileStatus: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var statusCode: String
    public var path: String
    public var staged: Bool

    public init(statusCode: String, path: String, staged: Bool) {
        self.statusCode = statusCode
        self.path = path
        self.staged = staged
    }

    public var label: String {
        switch statusCode {
        case "M": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "??": return "Untracked"
        case "!!": return "Ignored"
        default: return statusCode
        }
    }
}

public struct GitCommitInfo: Identifiable, Equatable, Sendable {
    public var id: String { hash }
    public var hash: String
    public var author: String
    public var date: Date?
    public var subject: String

    public init(hash: String, author: String, date: Date?, subject: String) {
        self.hash = hash
        self.author = author
        self.date = date
        self.subject = subject
    }
}

public struct GitBlameLine: Identifiable, Equatable, Sendable {
    public var id: Int { lineNumber }
    public var lineNumber: Int
    public var hash: String
    public var author: String
    public var text: String

    public init(lineNumber: Int, hash: String, author: String, text: String) {
        self.lineNumber = lineNumber
        self.hash = hash
        self.author = author
        self.text = text
    }
}

public enum GitError: Error, Equatable, Sendable {
    case notARepository(String)
    case gitUnavailable(String)
    case commandFailed(String)
    case nothingToCommit
}

/// Git integration over the git CLI. The spec names libgit2, but no
/// production-grade Swift binding ships for it today; the reference
/// implementation (OpenClaudeCodexDesktop GitService) also shells out to git,
/// so this follows the proven route. Push is deliberately not implemented.
public actor GitService {
    public static let gitPath = "/usr/bin/git"
    public static let diffLimit = 512 * 1024

    private let gitPathOverride: String?
    private nonisolated(unsafe) static var resolvedExecutable: String?

    public init(gitPath: String? = nil) {
        self.gitPathOverride = gitPath
    }

    private var gitExecutable: String {
        if let gitPathOverride { return gitPathOverride }
        if let resolved = Self.resolvedExecutable { return resolved }
        // /usr/bin/git is an xcrun shim that refuses to run inside App Sandbox;
        // probe candidates once and keep the first that answers --version.
        let candidates = [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            Self.gitPath,
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: candidate)
            probe.arguments = ["--version"]
            probe.standardOutput = Pipe()
            probe.standardError = Pipe()
            do {
                try probe.run()
                probe.waitUntilExit()
                if probe.terminationStatus == 0 {
                    Self.resolvedExecutable = candidate
                    return candidate
                }
            } catch {
                continue
            }
        }
        return Self.gitPath
    }

    private func run(_ arguments: [String], in repositoryPath: String, maxBytes: Int = 4 * 1024 * 1024) throws -> String {
        guard FileManager.default.fileExists(atPath: gitExecutable) else {
            throw GitError.gitUnavailable("git not found at \(gitExecutable)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitExecutable)
        process.arguments = ["-C", repositoryPath] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw GitError.commandFailed(error.localizedDescription)
        }
        var output = Data()
        let handle = stdout.fileHandleForReading
        while output.count < maxBytes, process.isRunning || handle.availableData.count > 0 {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
        }
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            var message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if message.contains("nothing to commit") || message.contains("no changes added to commit") {
                throw GitError.nothingToCommit
            }
            throw GitError.commandFailed(message.isEmpty ? "git \(arguments.first ?? "") exited \(process.terminationStatus)" : message)
        }
        return String(decoding: output.prefix(maxBytes), as: UTF8.self)
    }

    public func isRepository(_ path: String) -> Bool {
        (try? run(["rev-parse", "--is-inside-work-tree"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)) == "true"
    }

    public func initializeRepository(at path: String) throws {
        _ = try run(["init", "-q"], in: path)
    }

    public func status(_ repositoryPath: String) throws -> [GitFileStatus] {
        let output = try run(["status", "--porcelain=v1", "-z"], in: repositoryPath)
        var results: [GitFileStatus] = []
        // With -z every record is "XY <path>"\0; renames add the original
        // path as a second \0-terminated field.
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else { break }
            let code = String(record.prefix(2)).trimmingCharacters(in: .whitespaces)
            let path = String(record.dropFirst(3))
            if (code.contains("R") || code.contains("C")), records.indices.contains(index + 1) {
                results.append(GitFileStatus(statusCode: "R", path: "\(path) → \(records[index + 1])", staged: true))
                index += 2
                continue
            }
            let staged = !code.hasPrefix("?") && !code.hasPrefix("!")
            results.append(GitFileStatus(statusCode: code, path: path, staged: staged))
            index += 1
        }
        return results
    }

    public func diff(_ repositoryPath: String, staged: Bool = false, path: String? = nil) throws -> String {
        var arguments = ["diff", "--no-color"]
        if staged { arguments.append("--cached") }
        if let path { arguments.append("--"); arguments.append(path) }
        return try run(arguments, in: repositoryPath, maxBytes: Self.diffLimit)
    }

    public func stage(_ repositoryPath: String, paths: [String]) throws {
        _ = try run(["add", "--"] + paths, in: repositoryPath)
    }

    public func unstage(_ repositoryPath: String, paths: [String]) throws {
        _ = try run(["reset", "HEAD", "--"] + paths, in: repositoryPath)
    }

    @discardableResult
    public func commit(_ repositoryPath: String, message: String, author: String? = nil) throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitError.commandFailed("commit message is empty")
        }
        var arguments = ["commit", "-m", message]
        if let author {
            arguments.append("--author")
            arguments.append(author)
        }
        return try run(arguments, in: repositoryPath).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func branches(_ repositoryPath: String) throws -> (current: String, all: [String]) {
        let output = try run(["branch", "--format=%(refname:short)|%(HEAD)"], in: repositoryPath)
        var all: [String] = []
        var current = ""
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let name = parts.first, !name.isEmpty else { continue }
            all.append(name)
            if parts.count > 1, parts[1] == "*" {
                current = name
            }
        }
        return (current, all)
    }

    public func createBranch(_ repositoryPath: String, name: String) throws {
        guard !name.isEmpty else { throw GitError.commandFailed("branch name is empty") }
        _ = try run(["branch", name], in: repositoryPath)
    }

    public func checkout(_ repositoryPath: String, branch: String) throws {
        _ = try run(["checkout", branch], in: repositoryPath)
    }

    public func log(_ repositoryPath: String, limit: Int = 50) throws -> [GitCommitInfo] {
        let output = try run(
            ["log", "--max-count=\(min(limit, 500))", "--date=iso8601", "--pretty=format:%H%x1f%an%x1f%aI%x1f%s%x1e"],
            in: repositoryPath
        )
        return output.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { entry in
            let fields = entry.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { return nil }
            let date = fields[2].isEmpty ? nil : ISO8601DateFormatter().date(from: fields[2])
            return GitCommitInfo(hash: fields[0], author: fields[1], date: date, subject: fields[3])
        }
    }

    public func blame(_ repositoryPath: String, path: String) throws -> [GitBlameLine] {
        let output = try run(["blame", "--porcelain", "--", path], in: repositoryPath, maxBytes: 8 * 1024 * 1024)
        var lines: [GitBlameLine] = []
        var currentHash = ""
        var currentAuthor = ""
        var lineNumber = 0
        for line in output.split(separator: "\n") {
            if currentHash.isEmpty, line.count >= 40, line.prefix(40).allSatisfy({ $0.isHexDigit }) {
                let head = line.split(separator: " ").first.map(String.init) ?? ""
                currentHash = String(head.prefix(12))
                let parts = line.split(separator: " ")
                if parts.count >= 2, let start = Int(parts[2]) {
                    lineNumber = start
                }
                continue
            }
            if line.hasPrefix("author ") {
                currentAuthor = String(line.dropFirst(7))
                continue
            }
            if line.hasPrefix("\t") {
                lines.append(GitBlameLine(lineNumber: lineNumber, hash: currentHash, author: currentAuthor, text: String(line.dropFirst())))
                lineNumber += 1
                currentHash = ""
                currentAuthor = ""
                continue
            }
        }
        return lines
    }
}
