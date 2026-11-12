import Foundation

public struct GHPullRequest: Equatable, Sendable, Identifiable {
    public var number: Int
    public var title: String
    public var author: String
    public var state: String
    public var isDraft: Bool
    public var branch: String
    public var updated: String
    public var url: String
    public var reviewDecision: String
    public var checks: [GHCheck]
    public var body: String
    public var id: Int { number }
}

public struct GHCheck: Equatable, Sendable {
    public var name: String
    public var status: String      // e.g. COMPLETED, IN_PROGRESS
    public var conclusion: String  // e.g. SUCCESS, FAILURE, ""
    public var url: String
    /// "pass", "fail", "pending" or "skipped"
    public var verdict: String {
        let c = conclusion.uppercased()
        if status.uppercased() != "COMPLETED", !status.isEmpty, c.isEmpty { return "pending" }
        switch c {
        case "SUCCESS": return "pass"
        case "FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED", "ERROR": return "fail"
        case "NEUTRAL", "SKIPPED": return "skipped"
        case "": return "pending"
        default: return "pending"
        }
    }
}

public struct GHIssue: Equatable, Sendable, Identifiable {
    public var number: Int
    public var title: String
    public var author: String
    public var state: String
    public var labels: [String]
    public var updated: String
    public var url: String
    public var body: String
    public var id: Int { number }
}

public struct GHRun: Equatable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var status: String
    public var conclusion: String
    public var branch: String
    public var event: String
    public var created: String
    public var url: String
}

public enum GitHubError: Error, Equatable, LocalizedError {
    case ghMissing, notSignedIn, notARepo, failed(String), invalid(String)
    public var errorDescription: String? {
        switch self {
        case .ghMissing: "The GitHub command-line tool (gh) was not found. Install it with Homebrew (brew install gh), then run gh auth login in a terminal."
        case .notSignedIn: "gh is not signed in. Run gh auth login in a terminal, then try again."
        case .notARepo: "This folder is not a GitHub repository (or gh cannot see its remote)."
        case .failed(let m): "GitHub request failed: \(m)"
        case .invalid(let m): m
        }
    }
}

/// Runs `gh` with arguments (never through a shell) in a folder and returns its standard output.
public protocol GHRunning: Sendable {
    func run(_ arguments: [String], in directory: URL) async throws -> Data
}

public struct SystemGHRunner: GHRunning {
    public init() {}

    static func locate() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh", NSHomeDirectory() + "/.local/bin/gh"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func run(_ arguments: [String], in directory: URL) async throws -> Data {
        guard let path = Self.locate() else { throw GitHubError.ghMissing }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.currentDirectoryURL = directory
                var env = ProcessInfo.processInfo.environment
                env["GH_PROMPT_DISABLED"] = "1"; env["NO_COLOR"] = "1"; env["GH_NO_UPDATE_NOTIFIER"] = "1"
                process.environment = env
                let out = Pipe(), err = Pipe()
                process.standardOutput = out; process.standardError = err
                do { try process.run() } catch { continuation.resume(throwing: GitHubError.failed(error.localizedDescription)); return }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); timer.cancel()
                if process.terminationStatus == 0 { continuation.resume(returning: data); return }
                let message = String(decoding: errData, as: UTF8.self)
                continuation.resume(throwing: GitHubService.classify(message))
            }
        }
    }
}

public struct GitHubService: Sendable {
    let runner: any GHRunning
    public init(runner: any GHRunning = SystemGHRunner()) { self.runner = runner }

    static func classify(_ stderr: String) -> GitHubError {
        let m = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.contains("gh auth login") || m.contains("not logged in") || m.contains("authentication") { return .notSignedIn }
        if m.contains("not a git repository") || m.contains("no git remotes") || m.contains("Could not resolve to a Repository") || m.contains("none of the git remotes") { return .notARepo }
        return .failed(String(m.prefix(300)))
    }

    public func repo(in directory: URL) async throws -> String {
        let data = try await runner.run(["repo", "view", "--json", "nameWithOwner"], in: directory)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = json["nameWithOwner"] as? String else { throw GitHubError.notARepo }
        return name
    }

    static let allowedStates: Set<String> = ["open", "closed", "merged", "all"]

    public func pullRequests(in directory: URL, state: String = "open", limit: Int = 20) async throws -> [GHPullRequest] {
        guard Self.allowedStates.contains(state) else { throw GitHubError.invalid("state must be open, closed, merged or all.") }
        let data = try await runner.run(["pr", "list", "--state", state, "--limit", String(min(max(limit, 1), 50)), "--json", "number,title,author,state,isDraft,headRefName,updatedAt,url,reviewDecision"], in: directory)
        return try Self.parsePullRequests(data)
    }

    public func pullRequest(_ number: Int, in directory: URL) async throws -> GHPullRequest {
        guard number > 0 else { throw GitHubError.invalid("Pull request number must be positive.") }
        let data = try await runner.run(["pr", "view", String(number), "--json", "number,title,author,state,isDraft,headRefName,updatedAt,url,reviewDecision,body,statusCheckRollup"], in: directory)
        guard let one = try Self.parsePullRequests(data, single: true).first else { throw GitHubError.failed("Unexpected reply.") }
        return one
    }

    public func issues(in directory: URL, state: String = "open", limit: Int = 20) async throws -> [GHIssue] {
        guard Self.allowedStates.contains(state), state != "merged" else { throw GitHubError.invalid("state must be open, closed or all.") }
        let data = try await runner.run(["issue", "list", "--state", state, "--limit", String(min(max(limit, 1), 50)), "--json", "number,title,author,state,labels,updatedAt,url,body"], in: directory)
        return try Self.parseIssues(data)
    }

    public func runs(in directory: URL, branch: String? = nil, limit: Int = 15) async throws -> [GHRun] {
        var args = ["run", "list", "--limit", String(min(max(limit, 1), 50)), "--json", "databaseId,name,status,conclusion,headBranch,event,createdAt,url"]
        if let branch, !branch.isEmpty {
            guard Self.safeRef(branch) else { throw GitHubError.invalid("That branch name is not allowed.") }
            args += ["--branch", branch]
        }
        return try Self.parseRuns(try await runner.run(args, in: directory))
    }

    /// Branch names never start with "-" (which would be read as an option) or contain control characters or spaces.
    static func safeRef(_ ref: String) -> Bool {
        !ref.isEmpty && ref.count <= 200 && !ref.hasPrefix("-") && !ref.contains("..") && !ref.unicodeScalars.contains { $0.value < 0x21 || $0 == "\u{7F}" || $0 == "~" || $0 == "^" || $0 == ":" || $0 == "?" || $0 == "*" || $0 == "[" || $0 == "\\" }
    }

    // MARK: Parsing

    static func array(_ data: Data, single: Bool = false) throws -> [[String: Any]] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { throw GitHubError.failed("Unreadable reply.") }
        if single, let d = raw as? [String: Any] { return [d] }
        guard let list = raw as? [[String: Any]] else { throw GitHubError.failed("Unexpected reply.") }
        return list
    }

    static func login(_ any: Any?) -> String { ((any as? [String: Any])?["login"] as? String) ?? "" }

    static func parsePullRequests(_ data: Data, single: Bool = false) throws -> [GHPullRequest] {
        try array(data, single: single).map { d in
            GHPullRequest(number: d["number"] as? Int ?? 0, title: d["title"] as? String ?? "", author: login(d["author"]), state: d["state"] as? String ?? "",
                          isDraft: d["isDraft"] as? Bool ?? false, branch: d["headRefName"] as? String ?? "", updated: d["updatedAt"] as? String ?? "", url: d["url"] as? String ?? "",
                          reviewDecision: d["reviewDecision"] as? String ?? "",
                          checks: (d["statusCheckRollup"] as? [[String: Any]] ?? []).map(parseCheck),
                          body: d["body"] as? String ?? "")
        }
    }

    /// A check run has name, status and conclusion; an older commit status has context and a single state (SUCCESS, FAILURE, ERROR, PENDING, EXPECTED).
    static func parseCheck(_ c: [String: Any]) -> GHCheck {
        if let context = c["context"] as? String {
            let state = (c["state"] as? String ?? "").uppercased()
            let done = !(state == "PENDING" || state == "EXPECTED" || state.isEmpty)
            let conclusion = state == "SUCCESS" ? "SUCCESS" : (state == "FAILURE" || state == "ERROR" ? "FAILURE" : "")
            return GHCheck(name: context, status: done ? "COMPLETED" : "IN_PROGRESS", conclusion: conclusion, url: c["targetUrl"] as? String ?? "")
        }
        return GHCheck(name: c["name"] as? String ?? "", status: c["status"] as? String ?? "", conclusion: c["conclusion"] as? String ?? "", url: c["detailsUrl"] as? String ?? "")
    }

    static func parseIssues(_ data: Data) throws -> [GHIssue] {
        try array(data).map { d in
            GHIssue(number: d["number"] as? Int ?? 0, title: d["title"] as? String ?? "", author: login(d["author"]), state: d["state"] as? String ?? "",
                    labels: (d["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }, updated: d["updatedAt"] as? String ?? "", url: d["url"] as? String ?? "", body: d["body"] as? String ?? "")
        }
    }

    static func parseRuns(_ data: Data) throws -> [GHRun] {
        try array(data).map { d in
            GHRun(id: d["databaseId"] as? Int ?? 0, name: d["name"] as? String ?? "", status: d["status"] as? String ?? "", conclusion: d["conclusion"] as? String ?? "",
                  branch: d["headBranch"] as? String ?? "", event: d["event"] as? String ?? "", created: d["createdAt"] as? String ?? "", url: d["url"] as? String ?? "")
        }
    }
}
