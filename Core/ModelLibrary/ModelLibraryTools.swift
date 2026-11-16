import Foundation

/// Agent tools for local Ollama models. Installing writes gigabytes to disk and uses the network, so it needs approval; removing is destructive.
/// Names that come from a model's own output are validated like any other input, and the tool reply says what happened, not what was hoped.
public struct ModelLibraryTool: ToolExecuting {
    public enum Kind: String, CaseIterable, Sendable { case installed = "models_installed", pull = "models_pull", progress = "models_progress", cancel = "models_cancel", remove = "models_remove" }
    public let kind: Kind
    public init(kind: Kind) { self.kind = kind }

    @MainActor public static func register(into registry: ToolRegistry) { for kind in Kind.allCases { registry.register(ModelLibraryTool(kind: kind)) } }

    private static let nameParam = ToolParam(name: "model", type: "string", description: "Ollama model name, for example llama3.2:3b or hf.co/user/repo:Q4_K_M", required: true)

    public var spec: ToolSpec {
        switch kind {
        case .installed: ToolSpec(name: "models_installed", summary: "List the models installed in the local Ollama server with size, quantization and which are loaded now. Says so if Ollama is not running.", permission: .read)
        case .pull: ToolSpec(name: "models_pull", summary: "Download a model into the local Ollama server (from the Ollama library, or hf.co/<user>/<repo>[:quant] from Hugging Face). Returns at once; check models_progress. Refuses when the disk is too full. Requires approval.", parameters: [Self.nameParam], permission: .write)
        case .progress: ToolSpec(name: "models_progress", summary: "Progress of model downloads started in this session: status, bytes and percent, or the error.", permission: .read)
        case .cancel: ToolSpec(name: "models_cancel", summary: "Cancel a model download in progress. Ollama keeps the partial data and resumes it if the same download is started again. Requires approval.", parameters: [Self.nameParam], permission: .write)
        case .remove: ToolSpec(name: "models_remove", summary: "Remove an installed Ollama model from disk. The name must match an installed model exactly. Cannot be undone (the model can be downloaded again). Requires approval.", parameters: [Self.nameParam], permission: .admin, isDestructive: true)
        }
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = ToolArgs.object(from: argumentsJSON) ?? [:]
        let audit = context.services.audit
        return try await run(args, audit: audit)
    }

    @MainActor private func run(_ args: [String: Any], audit: PlatformAudit?) async throws -> String {
        let state = ModelLibraryState.shared
        let model = (args["model"] as? String) ?? ""
        switch kind {
        case .installed:
            await state.refresh()
            if let message = state.message { return message }
            if state.installed.isEmpty { return "Ollama is running but has no models installed." }
            let loaded = Set(state.running.map(\.name))
            return state.installed.map { m in
                let size = ByteCountFormatter.string(fromByteCount: m.sizeBytes, countStyle: .file)
                return "\(m.name) | \(size)" + (m.parameterSize.map { " | \($0)" } ?? "") + (m.quantization.map { " | \($0)" } ?? "") + (loaded.contains(m.name) ? " | loaded now" : "")
            }.joined(separator: "\n")
        case .pull:
            let name = try state.startPull(model, audit: audit)
            return "Started downloading \(name). It runs in the background; check models_progress. A download is not a working model until you have tried it."
        case .progress:
            if state.pulls.isEmpty { return "No downloads in this session." }
            return state.pulls.map { p in
                let pct = p.fraction.map { " \(Int($0 * 100))%" } ?? ""
                let bytes = p.total > 0 ? " (\(ByteCountFormatter.string(fromByteCount: p.completed, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: p.total, countStyle: .file)))" : ""
                return "\(p.name): \(p.status)\(pct)\(bytes)"
            }.joined(separator: "\n")
        case .cancel:
            let name = try OllamaLibrary.validate(model)
            guard state.pulls.contains(where: { $0.name == name && $0.phase == .running }) else { return "No download of \(name) is in progress." }
            state.cancelPull(name); return "Cancelling the download of \(name)."
        case .remove:
            let name = try OllamaLibrary.validate(model)
            try await state.remove(name, audit: audit)
            return "Removed \(name) from Ollama."
        }
    }
}
