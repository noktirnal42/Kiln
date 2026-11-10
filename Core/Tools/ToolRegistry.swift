import Foundation

/// Executes a tool's logic once permission and approval have already been
/// granted. Implementations must not perform their own approval checks —
/// that is the orchestrator's job — but they should still validate their
/// inputs defensively, since a model can send anything.
public protocol ToolExecuting: Sendable {
    var spec: ToolSpec { get }
    func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String
}

/// Optional Core services a tool may use. All nil by default so every tool
/// stays unit-testable without booting the whole app; tools fall back to
/// direct, workspace-scoped implementations when a service is absent.
public struct ToolServices: Sendable {
    public var git: GitService?
    public var fileIndex: FileIndexService?
    public var mcp: MCPClientService?
    /// A web-search backend key (e.g. Tavily). Nil means search is not
    /// configured, and the tool must say so specifically — never fake it.
    public var webSearchKey: (@Sendable () -> String?)?
    /// Where tools that change platform state (memory, commands, hooks) record it. Set by the orchestrator per call.
    public var audit: PlatformAudit?

    public init(
        git: GitService? = nil,
        fileIndex: FileIndexService? = nil,
        mcp: MCPClientService? = nil,
        webSearchKey: (@Sendable () -> String?)? = nil
    ) {
        self.git = git
        self.fileIndex = fileIndex
        self.mcp = mcp
        self.webSearchKey = webSearchKey
    }
}

/// Everything a tool implementation needs from the outside world, gathered
/// in one place so tools stay unit-testable without booting an agent.
public struct ToolExecutionContext: Sendable {
    public var workspaceRoot: URL?
    public var conversationID: UUID
    public var redactSecrets: Bool
    public var services: ToolServices

    public init(
        workspaceRoot: URL?,
        conversationID: UUID,
        redactSecrets: Bool = true,
        services: ToolServices = ToolServices()
    ) {
        self.workspaceRoot = workspaceRoot
        self.conversationID = conversationID
        self.redactSecrets = redactSecrets
        self.services = services
    }
}

/// Holds every tool implementation the app knows about. Agents select a
/// subset by name via their `ToolPermissionSet`; the execution policy
/// filters further before the model sees anything.
public final class ToolRegistry: @unchecked Sendable {
    public static let shared = ToolRegistry()

    private var tools: [String: any ToolExecuting] = [:]
    private let lock = NSLock()

    public init(tools: [any ToolExecuting] = []) {
        for t in tools { self.tools[t.spec.name] = t }
    }

    public func register(_ tool: any ToolExecuting) {
        lock.lock(); defer { lock.unlock() }
        tools[tool.spec.name] = tool
    }

    public func tool(named name: String) -> (any ToolExecuting)? {
        lock.lock(); defer { lock.unlock() }
        return tools[name]
    }

    /// A new registry with everything here plus `extra` (later entries replace same-named ones).
    public func extended(with extra: [any ToolExecuting]) -> ToolRegistry {
        lock.lock(); let current = Array(tools.values); lock.unlock()
        return ToolRegistry(tools: current + extra)
    }

    public func allSpecs() -> [ToolSpec] {
        lock.lock(); defer { lock.unlock() }
        return tools.values.map(\.spec).sorted { $0.name < $1.name }
    }

    public func specs(named names: Set<String>) -> [ToolSpec] {
        lock.lock(); defer { lock.unlock() }
        return names.compactMap { tools[$0]?.spec }.sorted { $0.name < $1.name }
    }
}

// MARK: - Shared helpers

/// Races `body` against a deadline. True if the body finished first; false
/// on timeout — in which case the body keeps running detached (blocking C
/// calls cannot be interrupted), and the caller must clean up.
final class TimeoutRaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }
}

func withTimeoutRace(seconds: TimeInterval, body: @escaping @Sendable () -> Void) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let state = TimeoutRaceState(continuation)
        Task.detached {
            body()
            state.finish(true)
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            state.finish(false)
        }
    }
}

/// Runs `body` under a wall-clock ceiling, throwing `AgentRunError.toolTimedOut`
/// when it expires.
func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    toolName: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AgentRunError.toolTimedOut(toolName)
        }
        guard let first = try await group.next() else {
            throw AgentRunError.toolTimedOut(toolName)
        }
        group.cancelAll()
        return first
    }
}

/// Resolves a tool-provided path safely inside the workspace root. Every
/// filesystem tool routes through this so path traversal outside the
/// workspace is rejected in one place.
public enum WorkspacePathResolver {
    /// The workspace root with symlinks resolved. `/tmp` and `/var` are
    /// symlinks into `/private` on macOS, so comparing spellings directly
    /// makes a file inside the workspace look like it is outside.
    public static func canonicalRoot(_ root: URL) -> String {
        root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A path relative to the workspace, whichever spelling it arrives in.
    /// Returns nil when it genuinely falls outside.
    public static func relativePath(of path: String, under root: URL) -> String? {
        let rootPath = canonicalRoot(root)
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        if resolved == rootPath { return "" }
        guard resolved.hasPrefix(rootPath + "/") else { return nil }
        return String(resolved.dropFirst(rootPath.count + 1))
    }

    /// Accepts an absolute path that already points inside the workspace,
    /// as well as a relative one — models are routinely handed absolute
    /// paths by earlier tool results, and stripping the leading slash
    /// silently turned `/etc/passwd` into `<root>/etc/passwd`, failing
    /// with a "nothing there" error that described the wrong problem.
    /// Containment is enforced afterwards, so this widens what can be
    /// *expressed*, not what can be *reached*.
    public static func resolve(_ path: String, in root: URL) throws -> URL {
        let rootPath = canonicalRoot(root)
        let cleaned: String
        if path.hasPrefix("/") {
            if let inside = relativePath(of: path, under: root) {
                cleaned = inside
            } else {
                throw AgentRunError.permissionDenied(
                    "'\(path)' is outside the open workspace (\(rootPath))."
                )
            }
        } else {
            cleaned = path
        }
        let candidate = root.appendingPathComponent(cleaned).standardizedFileURL
        let candidateResolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let rootResolved = canonicalRoot(root)
        if candidateResolved != rootResolved && !candidateResolved.hasPrefix(rootResolved + "/") {
            throw AgentRunError.permissionDenied(
                "'\(path)' resolves outside the open workspace (\(rootPath))."
            )
        }
        return URL(fileURLWithPath: candidateResolved)
    }

    public static func requireRoot(_ context: ToolExecutionContext) throws -> URL {
        guard let root = context.workspaceRoot else {
            throw AgentRunError.permissionDenied("No workspace folder is open.")
        }
        return root
    }
}

/// JSON argument decoding helper: model-provided JSON to a typed payload.
enum ToolArgs {
    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw AgentRunError.permissionDenied("Tool arguments were not valid UTF-8.")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AgentRunError.permissionDenied("Tool arguments were not valid for this tool: \(error.localizedDescription)")
        }
    }

    static func object(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}

/// Every tool result is charged against the model's context window, and a
/// single unbounded one can spend the whole budget. The middle is dropped
/// rather than the end: the start of a log says what ran, the end says how
/// it finished, and cutting only the tail hides the verdict.
public enum ToolOutputCap {
    public static let ceiling = 24_000

    public static func fit(_ result: String, from toolName: String) -> String {
        guard result.count > ceiling else { return result }
        let keep = ceiling / 2
        let head = String(result.prefix(keep))
        let tail = String(result.suffix(keep))
        let dropped = result.count - (keep * 2)
        return """
        \(head)

        …[\(dropped) characters from the middle of this \(toolName) result were dropped to fit the \
        context window. The beginning and end are shown. Narrow the command or read a smaller \
        range if you need what was cut.]…

        \(tail)
        """
    }
}
