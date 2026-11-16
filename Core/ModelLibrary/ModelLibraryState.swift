import Foundation
import Observation

/// What the library UI and the agent tools share: the installed and running models, and the pulls in progress or finished this session.
@MainActor @Observable public final class ModelLibraryState {
    public static let shared = ModelLibraryState()

    public struct Pull: Identifiable, Equatable, Sendable {
        public enum Phase: Equatable, Sendable { case running, finished, failed(String), cancelled }
        public var id: String { name }
        public var name: String
        public var status = "Starting…"
        public var fraction: Double?
        public var completed: Int64 = 0
        public var total: Int64 = 0
        public var phase: Phase = .running
    }

    public private(set) var installed: [OllamaInstalledModel] = []
    public private(set) var running: [OllamaRunningModel] = []
    public private(set) var pulls: [Pull] = []
    public private(set) var message: String?
    public var library = OllamaLibrary()
    /// Where state changes are recorded in the audit log; set by whoever starts the work (a tool call or the sheet).
    public var audit: PlatformAudit?
    private var tasks: [String: Task<Void, Never>] = [:]

    public init() {}

    public func refresh() async {
        do {
            async let models = library.installed(); async let loaded = library.running()
            installed = try await models; running = (try? await loaded) ?? []; message = nil
        } catch { installed = []; running = []; message = error.localizedDescription }
    }

    /// Starts a pull and returns at once; progress appears in `pulls`. A model that is already pulling is not started twice.
    @discardableResult public func startPull(_ model: String, audit: PlatformAudit? = nil) throws -> String {
        let name = try OllamaLibrary.validate(model)
        if pulls.contains(where: { $0.name == name && $0.phase == .running }) { return name }
        pulls.removeAll { $0.name == name }
        pulls.append(Pull(name: name))
        let recorder = audit ?? self.audit
        let library = library
        tasks[name] = Task { [weak self] in
            await recorder?.record("models.pull.started", ["model": .string(name), "source": .string("ollama")])
            do {
                for try await event in library.pull(name) {
                    self?.update(name) { pull in
                        pull.status = event.status
                        if let total = event.total, total > 0 { pull.total = total; pull.completed = event.completed ?? 0; pull.fraction = event.fraction }
                        else { pull.fraction = nil }
                    }
                }
                self?.update(name) { $0.phase = .finished; $0.status = "Downloaded"; $0.fraction = 1 }
                await recorder?.record("models.pull.finished", ["model": .string(name)])
                await self?.refresh()
            } catch is CancellationError {
                self?.update(name) { $0.phase = .cancelled; $0.status = "Cancelled" }
                await recorder?.record("models.pull.cancelled", ["model": .string(name)])
            } catch {
                let text = error.localizedDescription
                self?.update(name) { $0.phase = .failed(text); $0.status = text }
                await recorder?.record("models.pull.failed", ["model": .string(name), "error": .string(text)])
            }
            self?.tasks[name] = nil
        }
        return name
    }

    public func cancelPull(_ model: String) {
        tasks[model]?.cancel()
    }

    public func remove(_ model: String, audit: PlatformAudit? = nil) async throws {
        let recorder = audit ?? self.audit
        let size = installed.first { $0.name == model }?.sizeBytes ?? 0
        try await library.delete(model)
        await recorder?.record("models.removed", ["model": .string(model), "bytes": .int(Int(size))])
        await refresh()
    }

    private func update(_ name: String, _ change: (inout Pull) -> Void) {
        guard let index = pulls.firstIndex(where: { $0.name == name }) else { return }
        change(&pulls[index])
    }
}
