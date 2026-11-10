import Foundation

/// Hooks: scripts the project runs at fixed points in an agent run, configured in `.kiln/hooks/hooks.json`
/// (user scope: `~/.kiln/hooks/hooks.json`):
///
///     {"hooks":[{"event":"pre_tool","match":"run_command|write_file","command":".kiln/hooks/check.sh","timeout":10}]}
///
/// The script gets the event as JSON on stdin. Exit 0 = no objection (stdout may be a JSON object
/// `{"decision":"allow|deny|annotate","reason":"…","note":"…"}`), exit 2 = deny with stderr as the reason, any other exit
/// or a timeout = the hook failed, which is recorded and treated as no decision.
///
/// A hook can only make a run stricter or add a note: `allow` is recorded but never skips an approval, a policy check
/// or the behavior monitor. Every decision goes to the audit chain.
public enum HookEvent: String, Codable, CaseIterable, Sendable {
    case preTool = "pre_tool", postTool = "post_tool", promptSubmit = "prompt_submit", stop
}

public struct HookDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(event.rawValue):\(match ?? "*"):\(command)" }
    public var event: HookEvent
    /// Tool-name pattern for tool events: names separated by `|`, `*` as a wildcard. Nil = every tool.
    public var match: String?
    public var command: String
    public var timeout: Double?
    /// Where it was configured: "project" or "user". Set by the loader.
    public var scope: String? = nil

    func matches(tool: String?) -> Bool {
        guard let match, !match.isEmpty, match != "*" else { return true }
        guard let tool else { return false }
        return match.split(separator: "|").contains { pattern in
            let p = pattern.trimmingCharacters(in: .whitespaces)
            if p.hasSuffix("*") { return tool.hasPrefix(p.dropLast()) }
            return p == tool
        }
    }
}

public enum HookVerdict: String, Sendable { case allow, deny, annotate, failed }

public struct HookDecision: Equatable, Sendable {
    public var hook: HookDefinition
    public var verdict: HookVerdict
    public var reason: String
}

public struct HookOutcome: Equatable, Sendable {
    public var decisions: [HookDecision] = []
    public var denial: String? { decisions.first { $0.verdict == .deny }?.reason }
    public var notes: [String] { decisions.filter { $0.verdict == .annotate }.map(\.reason) }
    public static let none = HookOutcome()
}

public struct HookRunner: Sendable {
    public var hooks: [HookDefinition]
    public var workspaceRoot: URL?
    public var audit: PlatformAudit?
    public init(hooks: [HookDefinition], workspaceRoot: URL?, audit: PlatformAudit? = nil) {
        self.hooks = hooks; self.workspaceRoot = workspaceRoot; self.audit = audit
    }

    public static func load(workspaceRoot: URL?, home: URL?) -> [HookDefinition] {
        func read(_ url: URL, scope: String) -> [HookDefinition] {
            struct File: Decodable { var hooks: [HookDefinition] }
            guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
            return file.hooks.map { var h = $0; h.scope = scope; return h }
        }
        return (home.map { read($0.appendingPathComponent(".kiln/hooks/hooks.json"), scope: "user") } ?? [])
            + (workspaceRoot.map { read($0.appendingPathComponent(".kiln/hooks/hooks.json"), scope: "project") } ?? [])
    }

    /// Runs every matching hook in order. Stops at the first denial.
    public func run(_ event: HookEvent, tool: String? = nil, payload: [String: Any]) async -> HookOutcome {
        var outcome = HookOutcome()
        for hook in hooks where hook.event == event && (event == .preTool || event == .postTool ? hook.matches(tool: tool) : true) {
            var body = payload
            body["event"] = event.rawValue
            if let tool { body["tool"] = tool }
            if let root = workspaceRoot { body["workspace"] = root.path }
            let decision = await execute(hook, input: body)
            outcome.decisions.append(decision)
            await audit?.record("hook.decision", [
                "event": .string(event.rawValue), "tool": tool.map(AuditValue.string) ?? .null,
                "command": .string(hook.command), "scope": .string(hook.scope ?? "project"),
                "verdict": .string(decision.verdict.rawValue), "reason": .string(String(decision.reason.prefix(300))),
            ])
            if decision.verdict == .deny { break }
        }
        return outcome
    }

    private func execute(_ hook: HookDefinition, input: [String: Any]) async -> HookDecision {
        let data = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
        let timeout = hook.timeout ?? 10
        let cwd = workspaceRoot
        return await Task.detached { () -> HookDecision in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", hook.command]
            if let cwd { process.currentDirectoryURL = cwd }
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
            do { try process.run() } catch {
                return HookDecision(hook: hook, verdict: .failed, reason: "could not start: \(error.localizedDescription)")
            }
            stdin.fileHandleForWriting.write(data)
            try? stdin.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            if process.isRunning {
                process.terminate()
                return HookDecision(hook: hook, verdict: .failed, reason: "timed out after \(Int(timeout))s")
            }
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch process.terminationStatus {
            case 0:
                if let object = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
                   let raw = object["decision"] as? String {
                    let reason = (object["reason"] as? String) ?? (object["note"] as? String) ?? ""
                    switch raw {
                    case "deny", "block": return HookDecision(hook: hook, verdict: .deny, reason: reason.isEmpty ? "denied by hook" : reason)
                    case "annotate": return HookDecision(hook: hook, verdict: .annotate, reason: reason)
                    default: return HookDecision(hook: hook, verdict: .allow, reason: reason)   // recorded; widens nothing
                    }
                }
                return HookDecision(hook: hook, verdict: out.isEmpty ? .allow : .annotate, reason: out)
            case 2:
                return HookDecision(hook: hook, verdict: .deny, reason: err.isEmpty ? "denied by hook" : err)
            default:
                return HookDecision(hook: hook, verdict: .failed, reason: "exit \(process.terminationStatus): \(err.prefix(200))")
            }
        }.value
    }
}
