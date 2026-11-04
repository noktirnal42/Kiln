import Foundation

// Behavior monitor, deterministic half: tripwires that run on every tool call BEFORE it executes.
// Ported from System5's monitor.py (design and test intent, not code).
//
// Tripwires catch the unambiguous cases: touching Kiln's own control plane (audit log, grants,
// settings), probing the host's security surface from a shell, reading credentials outside the
// workspace, using a path outside it. They are cheap and synchronous.
//
// A finding is a reason to ASK, never a verdict. At or above `pauseAtSeverity` the originating run
// pauses and a human decides; nothing is halted automatically and no other run is touched.
// System5 once had a "halt everything at severity N" switch and removed it: an automatic,
// unrecoverable action on a heuristic's say-so was the wrong shape.

/// One tripwire finding. Severity follows System5's 1–7 scale.
public struct MonitorFlag: Codable, Sendable, Equatable {
    public let category: String
    public let severity: Int
    public let rationale: String
    public let source: String

    public init(category: String, severity: Int, rationale: String, source: String = "tripwire") {
        self.category = category
        self.severity = severity
        self.rationale = rationale
        self.source = source
    }
}

public struct MonitorPolicy: Sendable, Equatable {
    public var enabled: Bool
    /// A finding at or above this pauses the one run it came from and asks the human.
    public var pauseAtSeverity: Int
    /// Paths an agent has no business touching: the audit log and its head, grants, settings, the
    /// app itself. Resolved through symlinks before comparison.
    public var protectedPaths: [URL]

    public init(enabled: Bool = true, pauseAtSeverity: Int = 5, protectedPaths: [URL] = []) {
        self.enabled = enabled
        self.pauseAtSeverity = pauseAtSeverity
        self.protectedPaths = protectedPaths
    }

    public static let standard = MonitorPolicy()
    public static let disabled = MonitorPolicy(enabled: false)
}

public enum Tripwires {
    // MARK: Patterns

    /// Network tooling in a shell command. RECORDED, NOT ACTED ON: whether an agent may reach the
    /// network is the egress policy's call. At a pausing severity this used to stop runs the
    /// policy had already allowed.
    private static let networkShell = regex(#"\b(curl|wget|nc|ncat|netcat|telnet|ssh|scp|sftp|ftp|rsync)\b|/dev/tcp/|/dev/udp/"#)

    /// Host security surface an agent has no business touching. Deliberately narrow: "/etc/" or a
    /// bare "docker" would match `cat /etc/os-release` and ordinary Dockerfile work.
    private static let infraShell = regex(
        #"sandbox-exec|iptables|pfctl|nftables|docker\.sock|csrutil|nvram|\bchroot\b|\btccutil\b|\bspctl\b"#)

    /// Kiln's own control plane, by file name.
    private static let selfTamper = regex(
        #"audit-events\.jsonl|audit-head\.json|(^|/)grants\.json|approvals\.jsonl|mcp-approvals\.json|/Application Support/Kiln(/|$)|Kiln\.app/"#)

    private static let credentialHint = regex(
        #"(^|/)\.env($|\.)|credential|secret|id_rsa|authorized_keys|\.aws/|\.ssh/"#)

    private static let pathTools: Set<String> = [
        "read_file", "write_file", "edit_file", "delete_file", "list_directory", "glob_files", "grep_files",
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals in this file; a typo is a programmer error caught by every test.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: Check

    /// Synchronous pre-execution check. Returns every finding; the caller decides what to do.
    public static func check(
        tool: String,
        argumentsJSON: String,
        workspaceRoot: URL?,
        protectedPaths: [URL]
    ) -> [MonitorFlag] {
        var flags: [MonitorFlag] = []
        let arguments = ToolArgs.object(from: argumentsJSON) ?? [:]

        if matches(selfTamper, argumentsJSON) {
            flags.append(MonitorFlag(category: "logging_tamper", severity: 7,
                                     rationale: "\(tool) references Kiln's own control plane: \(clip(argumentsJSON))"))
        }

        if ShellCommandChecker.isShellTool(tool), let command = arguments["command"] as? String {
            for root in protectedPaths where command.contains(root.path) {
                flags.append(MonitorFlag(category: "logging_tamper", severity: 7,
                                         rationale: "shell command names a protected path: \(root.path)"))
                break
            }
            if matches(networkShell, command) {
                flags.append(MonitorFlag(category: "exfiltration", severity: 2,
                                         rationale: "shell command uses network tooling: \(clip(command))"))
            }
            if matches(infraShell, command) {
                flags.append(MonitorFlag(category: "scope_probing", severity: 7,
                                         rationale: "shell command probes host security surface: \(clip(command))"))
            }
        }

        if pathTools.contains(tool), let path = arguments["path"] as? String, !path.isEmpty {
            if let root = protectedRoot(containing: path, workspaceRoot: workspaceRoot, protectedPaths: protectedPaths) {
                flags.append(MonitorFlag(category: "logging_tamper", severity: 7,
                                         rationale: "\(tool) targets Kiln's own control plane: \(root.path)"))
            }
            if isOutside(path, workspaceRoot: workspaceRoot) {
                // A credential-shaped name only means something outside the workspace: a `.env` in
                // the project the agent was told to work on is ordinary.
                if matches(credentialHint, path) {
                    flags.append(MonitorFlag(category: "credential_access", severity: 7,
                                             rationale: "\(tool) targets credentials outside the workspace: \(clip(path))"))
                }
                flags.append(MonitorFlag(category: "scope_probing", severity: 6,
                                         rationale: "\(tool) uses an out-of-workspace path: \(clip(path))"))
            }
        }
        return flags
    }

    /// The folder to offer as a project when a held call targets a path outside the workspace: the path itself for an
    /// existing directory, otherwise its parent. Nil when the call is not a path tool, the path is inside the workspace,
    /// or it points at Kiln's own protected files (those are never offered).
    public static func folderToOffer(tool: String, argumentsJSON: String, workspaceRoot: URL?, protectedPaths: [URL] = []) -> URL? {
        guard pathTools.contains(tool),
              let data = argumentsJSON.data(using: .utf8),
              let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = arguments["path"] as? String, !raw.isEmpty,
              isOutside(raw, workspaceRoot: workspaceRoot),
              protectedRoot(containing: raw, workspaceRoot: workspaceRoot, protectedPaths: protectedPaths) == nil,
              let canonical = canonicalPath(raw, workspaceRoot: workspaceRoot) else { return nil }
        guard !matches(credentialHint, canonical + "/") else { return nil }
        var isDirectory: ObjCBool = false
        let url = URL(fileURLWithPath: canonical)
        let folder = FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory) && isDirectory.boolValue
            ? url : url.deletingLastPathComponent()
        // Never offer the whole disk or the whole home folder as a project.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard folder.path != "/", folder.path != home, folder.pathComponents.count > 2 else { return nil }
        return folder
    }

    public static func worstSeverity(_ flags: [MonitorFlag]) -> Int { flags.map(\.severity).max() ?? 0 }

    // MARK: Path logic

    /// Resolves a path the way the file tools will: `~` expanded, relative paths taken from the
    /// workspace, `..` and symlinks resolved. For a path that does not exist yet, the nearest
    /// existing ancestor is resolved and the rest appended, so `/var` and `/private/var` agree.
    static func canonicalPath(_ raw: String, workspaceRoot: URL?) -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else if let workspaceRoot {
            url = workspaceRoot.appendingPathComponent(expanded)
        } else {
            return nil
        }
        return canonical(url.standardizedFileURL)
    }

    private static func canonical(_ url: URL) -> String {
        var existing = url
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in tail { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }

    private static func isWithin(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func isOutside(_ raw: String, workspaceRoot: URL?) -> Bool {
        guard let workspaceRoot else {
            // No workspace to compare with: an absolute path or a parent hop is all we can judge.
            return raw.hasPrefix("/") || raw.hasPrefix("~") || raw.split(separator: "/").contains("..")
        }
        guard let resolved = canonicalPath(raw, workspaceRoot: workspaceRoot) else { return true }
        return !isWithin(resolved, root: canonical(workspaceRoot.standardizedFileURL))
    }

    static func protectedRoot(containing raw: String, workspaceRoot: URL?, protectedPaths: [URL]) -> URL? {
        guard let resolved = canonicalPath(raw, workspaceRoot: workspaceRoot) else { return nil }
        return protectedPaths.first { isWithin(resolved, root: canonical($0.standardizedFileURL)) }
    }

    private static func clip(_ text: String, limit: Int = 200) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
