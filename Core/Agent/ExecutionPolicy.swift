import Foundation
import Network

// MARK: - Verdicts

public enum PolicyVerdict: String, Codable, Equatable, Sendable {
    case allow
    case requireApproval
    case deny
}

/// What the policy decided, and which rule produced the decision — the GUI
/// can always show *why* something paused or was blocked.
public struct PolicyDecision: Equatable, Sendable {
    public var verdict: PolicyVerdict
    public var rule: String
    public var reason: String

    public init(verdict: PolicyVerdict, rule: String = "", reason: String = "") {
        self.verdict = verdict
        self.rule = rule
        self.reason = reason
    }

    public var allowed: Bool { verdict == .allow }
}

/// The situations that can pause a run for a human. Everything else either
/// passes or is refused outright.
public enum ApprovalKind: String, Codable, CaseIterable, Sendable {
    case networkNewDomain
    case writeOutsideScope
    case riskyShell
    case spendOverHalfBudget
}

// MARK: - Agent modes

/// What a run is allowed to *do* at its ceiling, independent of which tools
/// are enabled. The mode caps the permission level before any tool list is
/// built; the agent's tool set can only narrow things further.
public enum AgentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case askOnly
    case plan
    case review
    case patch
    case act
    case autonomous

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .askOnly: return "Ask only"
        case .plan: return "Plan"
        case .review: return "Review"
        case .patch: return "Patch"
        case .act: return "Act"
        case .autonomous: return "Autonomous"
        }
    }

    /// Structurally forbids write/execute tools, regardless of permissions.
    public var isReadOnly: Bool {
        switch self {
        case .askOnly, .plan, .review: return true
        case .patch, .act, .autonomous: return false
        }
    }

    /// `patch` may compute diffs but must not write them directly.
    public var allowsDirectWrites: Bool {
        switch self {
        case .act, .autonomous: return true
        case .askOnly, .plan, .review, .patch: return false
        }
    }

    public var maxPermittedLevel: ToolPermissionLevel {
        isReadOnly ? .read : .execute
    }
}

// MARK: - Rule groups (System5 policy.py, ported)

public struct WorkspaceRule: Codable, Equatable, Sendable {
    /// When true, writes may touch the host filesystem including absolute
    /// paths outside the workspace. Off means writes stay inside the root.
    public var hostAccess: Bool
    public var writeScope: [String]
    public var denyPaths: [String]

    public init(hostAccess: Bool = false, writeScope: [String] = ["**"], denyPaths: [String] = ["../**", "/**"]) {
        self.hostAccess = hostAccess
        self.writeScope = writeScope
        self.denyPaths = denyPaths
    }
}

public struct NetworkRule: Codable, Equatable, Sendable {
    public enum DefaultMode: String, Codable, Sendable {
        /// Nothing reaches web tools unless it is allowlisted (or a grant
        /// covers it, or a human approves it).
        case deny
        /// Anything reaches web tools except the denylist and the built-in
        /// SSRF backstop — the shape of an ordinary machine's egress.
        case allow
    }

    public var allowLocal: Bool
    public var defaultMode: DefaultMode
    public var egressAllowlist: [String]
    public var egressDenylist: [String]

    public init(allowLocal: Bool = false, defaultMode: DefaultMode = .deny, egressAllowlist: [String] = [], egressDenylist: [String] = []) {
        self.allowLocal = allowLocal
        self.defaultMode = defaultMode
        self.egressAllowlist = egressAllowlist
        self.egressDenylist = egressDenylist
    }
}

public struct ShellRule: Codable, Equatable, Sendable {
    /// Regex patterns. A match means require-approval (the human decides).
    public var requireApprovalPatterns: [String]
    /// Regex patterns. A match means refused outright, no approval possible.
    public var blockPatterns: [String]

    public init(requireApprovalPatterns: [String] = [], blockPatterns: [String] = []) {
        self.requireApprovalPatterns = requireApprovalPatterns
        self.blockPatterns = blockPatterns
    }

    public static let standardBlocks: [String] = [
        #"\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r|--recursive\s+--force)\s+(/|~|\$HOME|$)"#,
        #"\bmkfs\b"#,
        #"\bdiskutil\s+erase"#,
        #"\bdd\s+if=\S*/dev/"#,
        #"\b(shutdown|reboot|halt)\b"#,
        #":\(\)\s*\{.*\};:"#,
        #">\s*/dev/sd"#,
    ]

    public static let standardApprovalGates: [String] = [
        #"\bsudo\b"#,
        #"\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r|--recursive\s+--force)\b"#,
        #"\bgit\s+push\b.*(--force|\s-f\b)"#,
        #"\bgit\s+reset\s+--hard"#,
        #"\bgit\s+clean\s+-[a-zA-Z]*f"#,
        #"\bcurl\b.*\|\s*(sh|bash|zsh)\b"#,
        #"\bwget\b.*\|\s*(sh|bash|zsh)\b"#,
        #"\bchmod\s+-R\s+777"#,
        #"\bnpm\s+publish\b"#,
    ]

    public static var standard: ShellRule {
        ShellRule(requireApprovalPatterns: standardApprovalGates, blockPatterns: standardBlocks)
    }
}

public struct BudgetRule: Codable, Equatable, Sendable {
    /// Zero disables that cap locally; provider/context limits still apply.
    public var usdCap: Double
    public var tokenCap: Int
    public var wallClockMinutes: Int

    public init(usdCap: Double = 5.0, tokenCap: Int = 2_000_000, wallClockMinutes: Int = 30) {
        self.usdCap = usdCap
        self.tokenCap = tokenCap
        self.wallClockMinutes = wallClockMinutes
    }
}

// MARK: - The policy (GATE A)

/// Declarative policy: what a run may do, what needs a human, what is
/// refused outright. Consulted on every tool hop by the orchestrator, and —
/// before the first hop — to filter the tool list the model is even offered.
///
/// Gate A: `offeredTools` strips tools before the model sees them.
/// Gate B: `checkTool` / `checkWritePath` / `checkShell` / `checkEgress`
/// stop execution even for a tool the model hallucinated anyway. The two
/// gates are independent by construction: filtering never makes dispatch
/// trust the tool list, and dispatch never widens what was offered.
public struct ExecutionPolicy: Codable, Equatable, Sendable {
    public var name: String
    public var mode: AgentMode
    public var toolsAllowed: [String]
    public var workspace: WorkspaceRule
    public var network: NetworkRule
    public var shell: ShellRule
    public var budget: BudgetRule
    public var requiredApprovals: [ApprovalKind]

    public init(
        name: String = "default",
        mode: AgentMode = .act,
        toolsAllowed: [String] = [
            "read_file", "write_file", "edit_file", "delete_file",
            "list_directory", "glob_files", "grep_files",
            "run_command", "stream_command", "background_command", "read_command_output",
            "git_status", "git_diff", "git_commit", "git_branch", "git_log",
            "web_search", "web_fetch",
            "search_workspace",
        ],
        workspace: WorkspaceRule = WorkspaceRule(),
        network: NetworkRule = NetworkRule(),
        shell: ShellRule = ShellRule.standard,
        budget: BudgetRule = BudgetRule(),
        requiredApprovals: [ApprovalKind] = [
            .networkNewDomain, .writeOutsideScope, .riskyShell, .spendOverHalfBudget,
        ]
    ) {
        self.name = name
        self.mode = mode
        self.toolsAllowed = toolsAllowed
        self.workspace = workspace
        self.network = network
        self.shell = shell
        self.budget = budget
        self.requiredApprovals = requiredApprovals
    }

    public static var standard: ExecutionPolicy { ExecutionPolicy() }

    /// Tools contributed by Kiln's own modules (Reverse Engineering, Model Lab, Devices). They are not in the
    /// fixed allowlist above, but each declares its permission level, which the mode cap, the
    /// approval gate and the agent's own tool set still enforce.
    public static let moduleToolPrefixes = ["re_", "lab_", "swarm_", "mcp_", "computer_", "browser_", "device_", "media_", "image_"]
    public static func isModuleTool(_ name: String) -> Bool { moduleToolPrefixes.contains { name.hasPrefix($0) } }

    /// A policy for modes that must not touch anything: read tools only.
    public static var readOnly: ExecutionPolicy {
        var p = ExecutionPolicy(mode: .review, requiredApprovals: [.writeOutsideScope, .riskyShell, .networkNewDomain])
        p.toolsAllowed = ["read_file", "list_directory", "glob_files", "grep_files", "git_status", "git_diff", "git_log", "search_workspace"]
        return p
    }

    // -- Gate A: the tool list the model may even see --------------------------

    /// The specs this run is allowed to offer, before the model sees
    /// anything. Read-only modes strip write/execute/admin here; tools the
    /// policy refuses are absent rather than declined at call time; a tool
    /// that requires a workspace is never offered without one.
    public func offeredTools(
        from registry: ToolRegistry,
        permissions: ToolPermissionSet,
        workspaceRoot: URL?
    ) -> [ToolSpec] {
        let cap = mode.maxPermittedLevel
        return registry.allSpecs().filter { spec in
            guard toolsAllowed.contains(spec.name) || Self.isModuleTool(spec.name) else { return false }
            guard permissions.isEnabled(spec.name) else { return false }
            guard spec.permission <= cap || (["mcp_call_tool", "computer_use"].contains(spec.name) && mode.allowsDirectWrites) else { return false }
            if mode.isReadOnly && !mode.allowsDirectWrites && spec.permission > .read { return false }
            guard !spec.requiresWorkspace || workspaceRoot != nil else { return false }
            return true
        }
    }

    // -- Gate B: per-hop checks ------------------------------------------------

    public func checkTool(_ tool: String) -> PolicyDecision {
        if toolsAllowed.contains(tool) || Self.isModuleTool(tool) {
            return PolicyDecision(verdict: .allow)
        }
        return PolicyDecision(verdict: .deny, rule: "tools_allowed", reason: "tool '\(tool)' not permitted")
    }

    public func checkWritePath(_ relPath: String) -> PolicyDecision {
        if workspace.hostAccess {
            return PolicyDecision(verdict: .allow, rule: "workspace.host_access")
        }
        let parts = relPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let isAbsolute = relPath.hasPrefix("/")
        if isAbsolute || parts.contains("..") {
            return PolicyDecision(
                verdict: approvalOrDeny(.writeOutsideScope),
                rule: "workspace.deny_paths",
                reason: "path '\(relPath)' escapes the run workspace"
            )
        }
        let norm = parts.joined(separator: "/")
        for pat in workspace.denyPaths where PathWildcard.matches(norm, pattern: pat) {
            return PolicyDecision(
                verdict: approvalOrDeny(.writeOutsideScope),
                rule: "workspace.deny_paths:\(pat)",
                reason: "path '\(relPath)' matches a denied pattern"
            )
        }
        for pat in workspace.writeScope where PathWildcard.matches(norm, pattern: pat) {
            return PolicyDecision(verdict: .allow, rule: "workspace.write_scope:\(pat)")
        }
        return PolicyDecision(
            verdict: approvalOrDeny(.writeOutsideScope),
            rule: "workspace.write_scope",
            reason: "path '\(relPath)' is not inside write_scope"
        )
    }

    public func checkShell(_ cmd: String) -> PolicyDecision {
        let cmdRange = NSRange(location: 0, length: (cmd as NSString).length)
        for pat in shell.blockPatterns {
            if let regex = PathWildcard.regex(pat), regex.firstMatch(in: cmd, range: cmdRange) != nil {
                return PolicyDecision(
                    verdict: .deny,
                    rule: "shell.block_patterns:\(pat)",
                    reason: "blocked command"
                )
            }
        }
        for pat in shell.requireApprovalPatterns {
            if let regex = PathWildcard.regex(pat), regex.firstMatch(in: cmd, range: cmdRange) != nil {
                return PolicyDecision(
                    verdict: approvalOrDeny(.riskyShell),
                    rule: "shell.require_approval_patterns:\(pat)",
                    reason: "command matches a risk pattern"
                )
            }
        }
        return PolicyDecision(verdict: .allow)
    }

    public func checkEgress(_ host: String, grants: Set<String> = []) -> PolicyDecision {
        let h = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !network.allowLocal && Self.isInternalAddress(h) {
            return PolicyDecision(
                verdict: .deny,
                rule: "network.ssrf_guard",
                reason: "'\(host)' resolves inside this machine's own network and is always blocked"
            )
        }
        for entry in network.egressDenylist where Self.matchesHost(h, entry: entry) {
            return PolicyDecision(
                verdict: .deny,
                rule: "network.egress_denylist:\(entry)",
                reason: "host '\(host)' is on the egress denylist"
            )
        }
        if network.defaultMode == .allow {
            return PolicyDecision(verdict: .allow, rule: "network.default:allow")
        }
        for entry in network.egressAllowlist where Self.matchesHost(h, entry: entry) {
            return PolicyDecision(verdict: .allow, rule: "network.egress_allowlist:\(entry)")
        }
        if grants.contains(h) {
            return PolicyDecision(verdict: .allow, rule: "grant.egress_host")
        }
        return PolicyDecision(
            verdict: approvalOrDeny(.networkNewDomain),
            rule: "network.default",
            reason: "host '\(host)' is not on the egress allowlist"
        )
    }

    public func checkBudget(costUSD: Double, tokens: Int, minutes: Double) -> PolicyDecision {
        if budget.usdCap > 0 && costUSD >= budget.usdCap {
            return PolicyDecision(verdict: .deny, rule: "budget.usd_cap", reason: "USD budget exhausted")
        }
        if budget.tokenCap > 0 && tokens >= budget.tokenCap {
            return PolicyDecision(verdict: .deny, rule: "budget.token_cap", reason: "token budget exhausted")
        }
        if budget.wallClockMinutes > 0 && minutes >= Double(budget.wallClockMinutes) {
            return PolicyDecision(verdict: .deny, rule: "budget.wall_clock_minutes", reason: "wall-clock budget spent")
        }
        if budget.usdCap > 0 && costUSD >= budget.usdCap / 2 && requiredApprovals.contains(.spendOverHalfBudget) {
            return PolicyDecision(verdict: .requireApproval, rule: "approvals.spend_over_half_budget", reason: "past half the USD budget")
        }
        return PolicyDecision(verdict: .allow)
    }

    func approvalOrDeny(_ kind: ApprovalKind) -> PolicyVerdict {
        requiredApprovals.contains(kind) ? .requireApproval : .deny
    }

    static func matchesHost(_ host: String, entry: String) -> Bool {
        let entry = entry.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.hasPrefix("*.") {
            return host == String(entry.dropFirst(2)) || host.hasSuffix(String(entry.dropFirst()))
        }
        return host == entry
    }

    // -- Human-readable summary for the UI --------------------------------------

    public func summary() -> [String] {
        let usd = budget.usdCap <= 0 ? "uncapped" : String(format: "$%.2f", budget.usdCap)
        let tokens = budget.tokenCap <= 0 ? "uncapped" : "\(budget.tokenCap) tokens"
        let minutes = budget.wallClockMinutes <= 0 ? "uncapped" : "\(budget.wallClockMinutes) min"
        return [
            "Tools: \(toolsAllowed.joined(separator: ", "))",
            workspace.hostAccess
                ? "Files: host filesystem access, including absolute paths"
                : "Writes: allowed under \(workspace.writeScope); denied \(workspace.denyPaths)",
            "Network: \(network.defaultMode.rawValue) by default; \(network.egressAllowlist.count) host(s) allowlisted",
            "Shell: \(shell.blockPatterns.count) blocked / \(shell.requireApprovalPatterns.count) approval-gated patterns",
            "Budget: \(usd) / \(tokens) / \(minutes)",
            "Requires approval: \(requiredApprovals.map(\.rawValue).joined(separator: ", "))",
        ]
    }

    // -- The SSRF backstop --------------------------------------------------------

    /// Hostnames that stay blocked even under default-allow. Web tools run on
    /// the operator's own machine, so an agent asking them to fetch an
    /// internal address is asking the *host* to make that request.
    static let alwaysBlockedNames = try! NSRegularExpression(
        pattern: #"^(localhost|.*\.local|.*\.internal|metadata\.google\.internal)\.?$"#,
        options: [.caseInsensitive]
    )

    /// True when `host` names this machine or a network only it can see.
    ///
    /// Deliberately not a pattern match on the text: "127.1", "2130706433",
    /// "0" and "::ffff:127.0.0.1" are all loopback, and a regex over the
    /// spelling misses every one. The address parsers normalize the
    /// shorthands, so ask them instead. This is a check on what was
    /// *written*, not on what DNS would return.
    public static func isInternalAddress(_ host: String) -> Bool {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return true }
        let range = NSRange(location: 0, length: (host as NSString).length)
        if alwaysBlockedNames.firstMatch(in: host, range: range) != nil { return true }
        var candidate = host
        if host.hasPrefix("[") && host.hasSuffix("]") {
            candidate = String(host.dropFirst().dropLast())
        }
        if let v4 = IPv4Address(candidate) {
            return isInternalIPv4([UInt8](v4.rawValue))
        }
        if let v6 = IPv6Address(candidate) {
            return isInternalIPv6([UInt8](v6.rawValue))
        }
        // "127.1", "0", "2130706433": inet_aton parses the shorthand the
        // same way everything that dials them does.
        var addr = in_addr()
        if candidate.withCString({ inet_aton($0, &addr) }) == 1 {
            let bytes = withUnsafeBytes(of: addr.s_addr, Array.init)
            if let v4 = IPv4Address(Data(bytes)) {
                return isInternalIPv4([UInt8](v4.rawValue))
            }
        }
        return false
    }

    static func isInternalIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let (b0, b1, b2) = (bytes[0], bytes[1], bytes[2])
        let isPrivate = b0 == 10
            || (b0 == 172 && (b1 & 0xF0) == 16)
            || (b0 == 192 && b1 == 168)
            || (b0 == 169 && b1 == 254)
        let isLoopback = b0 == 127
        let isUnspecified = b0 == 0
        let isReserved = (b0 & 0xF0) == 240 || (b0 == 192 && b1 == 0 && (b2 == 0 || b2 == 2))
        let isMulticast = (b0 & 0xF0) == 224
        return isPrivate || isLoopback || isUnspecified || isReserved || isMulticast
    }

    static func isInternalIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        // IPv4-mapped: 80 zero bits, two 0xff bytes, then the v4 address.
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isInternalIPv4(Array(bytes.suffix(4)))
        }
        let isLoopback = bytes == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        let isUnspecified = bytes.allSatisfy { $0 == 0 }
        let isUniqueLocal = (bytes[0] & 0xFE) == 0xFC
        let isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
        let isMulticast = bytes[0] == 0xFF
        return isLoopback || isUnspecified || isUniqueLocal || isLinkLocal || isMulticast
    }
}

// MARK: - Wildcard/regex helpers

public enum PathWildcard {
    /// Cache held inside a lock-protected box: a `static var` dictionary
    /// would be nonisolated global mutable state under strict concurrency.
    private final class RegexCache: @unchecked Sendable {
        let lock = NSLock()
        var storage: [String: NSRegularExpression] = [:]
    }
    private static let cache = RegexCache()

    /// fnmatch-style matching where `*` spans path separators and `?` is one
    /// character. Used by the workspace write-scope rules.
    public static func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = globRegex(pattern) else { return text == pattern }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// A raw (already-regex) pattern, cached. Shell rules arrive as regex.
    public static func regex(_ pattern: String) -> NSRegularExpression? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let cached = cache.storage[pattern] { return cached }
        // If it compiles as a regex, use it as one.
        if let r = try? NSRegularExpression(pattern: pattern) {
            cache.storage[pattern] = r
            return r
        }
        return nil
    }

    /// Compiles a glob into a regex (escaping metacharacters, mapping
    /// `*` → `.*`, `?` → `.`).
    public static func globRegex(_ glob: String) -> NSRegularExpression? {
        var out = "^"
        for ch in glob {
            switch ch {
            case "*": out += ".*"
            case "?": out += "."
            default:
                out += NSRegularExpression.escapedTemplate(for: String(ch))
            }
        }
        out += "$"
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let cached = cache.storage[out] { return cached }
        guard let r = try? NSRegularExpression(pattern: out) else { return nil }
        cache.storage[out] = r
        return r
    }
}
