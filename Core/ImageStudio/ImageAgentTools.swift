import Foundation

/// The Image studio as agent and MCP tools. Listing and history are reads; downloading a model, generating, editing and
/// upscaling write files (and download over the network), so they need approval like `edit_file`.
public enum ImageAgentTools {
    public static let prefix = "image_"

    @MainActor
    public static func register(module: ImageStudioModule, into registry: ToolRegistry = .shared) {
        for kind in Kind.allCases { registry.register(ImageAgentTool(kind: kind, module: module)) }
    }

    enum Kind: String, CaseIterable, Sendable {
        case listModels = "list_models", downloadModel = "download_model", generate, edit, upscale, history

        var spec: ToolSpec {
            switch self {
            case .listModels:
                ToolSpec(name: "image_list_models", summary: "List image engines (MLX on this Mac, Draw Things, ComfyUI, AUTOMATIC1111/Forge) with their status and what each cannot do, the models each can run now, the downloadable catalogue (id, size, licence, gating, installed) and any downloads in progress. Pass query to search the catalogue.",
                         parameters: [ToolParam(name: "query", description: "Filter the catalogue by name", required: false)], permission: .read)
            case .downloadModel:
                ToolSpec(name: "image_download_model", summary: "Download a catalogue model (id from image_list_models) into the universal model store, resumable and checksum-verified. Refuses when disk space is short, when a gated model needs the user's Hugging Face token or accepted terms, and for downloads over 8 GB unless confirm_large is true. Never accepts licence terms for the user. Writes files and uses the network; requires approval.",
                         parameters: [ToolParam(name: "model_id", description: "Catalogue id, e.g. sd-turbo"),
                                      ToolParam(name: "confirm_large", type: "boolean", description: "Set only after the user agreed to a download over 8 GB", required: false)], permission: .write)
            case .generate:
                ToolSpec(name: "image_generate", summary: "Generate image(s) from a text prompt with the chosen engine and model, save them in Image studio history (each PNG embeds its settings) and return their paths. Fails with the reason when no engine is ready; never fakes output. Writes files; requires approval.",
                         parameters: Self.commonParameters + [ToolParam(name: "prompt", description: "What to draw")], permission: .write)
            case .edit:
                ToolSpec(name: "image_edit", summary: "Edit an existing image: mode image_to_image (restyle), inpaint (repaint the white area of a mask) or outpaint (extend the canvas by padding_* pixels). Engines that cannot do a mode say so. Writes files; requires approval.",
                         parameters: Self.commonParameters + [
                            ToolParam(name: "prompt", description: "What the result should show"),
                            ToolParam(name: "image_path", description: "Source image path (absolute or relative to the project)"),
                            ToolParam(name: "mode", description: "image_to_image, inpaint or outpaint; default image_to_image", required: false),
                            ToolParam(name: "mask_path", description: "Mask image for inpaint (white = repaint)", required: false),
                            ToolParam(name: "strength", type: "number", description: "0–1, how far to depart from the source; default 0.7", required: false),
                            ToolParam(name: "padding_left", type: "integer", description: "Outpaint pixels to add", required: false),
                            ToolParam(name: "padding_right", type: "integer", description: "Outpaint pixels to add", required: false),
                            ToolParam(name: "padding_top", type: "integer", description: "Outpaint pixels to add", required: false),
                            ToolParam(name: "padding_bottom", type: "integer", description: "Outpaint pixels to add", required: false)], permission: .write)
            case .upscale:
                ToolSpec(name: "image_upscale", summary: "Enlarge an image 2–4× with Lanczos resampling (a bigger picture, not AI sharpening) and save it in history. Writes a file; requires approval.",
                         parameters: [ToolParam(name: "image_path", description: "Image path"), ToolParam(name: "factor", type: "number", description: "2–4; default 2", required: false)], permission: .write)
            case .history:
                ToolSpec(name: "image_history", summary: "List recent Image studio pictures with ids, paths and the settings embedded in each (prompt, model, seed, steps, size).",
                         parameters: [ToolParam(name: "limit", type: "integer", description: "Most recent first; default 10", required: false)], permission: .read)
            }
        }

        static let commonParameters: [ToolParam] = [
            ToolParam(name: "model", description: "Model id as listed by image_list_models for the engine (default: the first available)", required: false),
            ToolParam(name: "engine", description: "mlx, drawthings, comfyui or a1111; default: first ready engine that can do it", required: false),
            ToolParam(name: "negative_prompt", description: "What to avoid", required: false),
            ToolParam(name: "width", type: "integer", description: "Pixels, default 512", required: false),
            ToolParam(name: "height", type: "integer", description: "Pixels, default 512", required: false),
            ToolParam(name: "steps", type: "integer", description: "Default 4 for Turbo models, 25 otherwise", required: false),
            ToolParam(name: "guidance", type: "number", description: "CFG scale; 0 for Turbo models", required: false),
            ToolParam(name: "seed", type: "integer", description: "Fixed seed; random when omitted", required: false),
            ToolParam(name: "count", type: "integer", description: "Images, 1–4", required: false),
            ToolParam(name: "style", description: "A style name from the Image studio (Photo, Cinematic, Anime, …)", required: false),
        ]
    }

    static func resolve(_ path: String, workspace: URL?) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return (workspace ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appendingPathComponent(expanded)
    }

    /// Builds a request from tool arguments. Exposed for tests.
    static func request(from args: [String: Any], task: ImageTask, workspace: URL?) throws -> ImageGenerationRequest {
        guard let prompt = args["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImageToolError.message("prompt is required.") }
        var r = ImageGenerationRequest(prompt: prompt, model: (args["model"] as? String) ?? "", task: task)
        r.engine = args["engine"] as? String
        r.negativePrompt = (args["negative_prompt"] as? String) ?? ""
        if let w = args["width"] as? Int { r.width = w }
        if let h = args["height"] as? Int { r.height = h }
        let turbo = r.model.lowercased().contains("turbo") || r.model.lowercased().contains("lightning")
        r.steps = (args["steps"] as? Int) ?? (turbo ? 4 : 25)
        r.guidance = (args["guidance"] as? Double) ?? (args["guidance"] as? Int).map(Double.init) ?? (turbo ? 0 : 7)
        if let s = args["seed"] as? Int { r.seed = Int64(s) }
        r.count = max(1, min(4, (args["count"] as? Int) ?? 1))
        if task != .textToImage {
            guard let path = args["image_path"] as? String, !path.isEmpty else { throw ImageToolError.message("image_path is required.") }
            r.initImagePath = resolve(path, workspace: workspace).path
            r.strength = (args["strength"] as? Double) ?? (args["strength"] as? Int).map(Double.init) ?? 0.7
        }
        if let mask = args["mask_path"] as? String, !mask.isEmpty { r.maskPath = resolve(mask, workspace: workspace).path }
        if task == .outpaint {
            r.outpaint = OutpaintPadding(left: args["padding_left"] as? Int ?? 0, right: args["padding_right"] as? Int ?? 0,
                                         top: args["padding_top"] as? Int ?? 0, bottom: args["padding_bottom"] as? Int ?? 0)
        }
        return r
    }
}

struct ImageAgentTool: ToolExecuting {
    let kind: ImageAgentTools.Kind
    let module: ImageStudioModule
    var spec: ToolSpec { kind.spec }

    func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = ToolArgs.object(from: argumentsJSON) ?? [:]
        let service = await MainActor.run { module.service }
        switch kind {
        case .listModels: return await listModels(service: service, query: (args["query"] as? String) ?? "")
        case .downloadModel: return try await download(service: service, args: args)
        case .generate:
            var request = try ImageAgentTools.request(from: args, task: .textToImage, workspace: context.workspaceRoot)
            if let style = args["style"] as? String { service.applyStyles([style], to: &request) }
            return Self.describe(try await module.generateForAgent(request))
        case .edit:
            let mode = (args["mode"] as? String) ?? "image_to_image"
            guard let task = ImageTask(rawValue: mode), task != .textToImage else { throw ImageToolError.message("mode must be image_to_image, inpaint or outpaint.") }
            var request = try ImageAgentTools.request(from: args, task: task, workspace: context.workspaceRoot)
            if let style = args["style"] as? String { service.applyStyles([style], to: &request) }
            return Self.describe(try await module.generateForAgent(request))
        case .upscale:
            guard let path = args["image_path"] as? String, !path.isEmpty else { throw ImageToolError.message("image_path is required.") }
            let factor = (args["factor"] as? Double) ?? (args["factor"] as? Int).map(Double.init) ?? 2
            guard factor >= 2, factor <= 4 else { throw ImageToolError.message("factor must be between 2 and 4.") }
            let item = try service.upscale(path: ImageAgentTools.resolve(path, workspace: context.workspaceRoot).path, factor: factor)
            await MainActor.run { module.reloadHistory() }
            return Self.describe([item])
        case .history:
            let limit = max(1, min(100, (args["limit"] as? Int) ?? 10))
            let items = service.history.items(limit: limit)
            guard !items.isEmpty else { return "The Image studio history is empty." }
            return items.map { item in
                let r = item.record
                return "\(item.id.uuidString) · \(item.url.path)" + (r.map { " · \($0.engine) · \($0.modelName) · \($0.request.width)x\($0.request.height) · \($0.request.steps) steps · seed \($0.seed) · \"\($0.request.prompt.prefix(80))\"" } ?? "")
            }.joined(separator: "\n")
        }
    }

    static func describe(_ items: [ImageHistoryItem]) -> String {
        "Generated \(items.count) image(s) with \(items.first?.record?.engine ?? "?") / \(items.first?.record?.modelName ?? "?"):\n"
            + items.map { "\($0.id.uuidString) · \($0.url.path) · seed \($0.record?.seed ?? 0)" }.joined(separator: "\n")
    }

    private func listModels(service: ImageStudioService, query: String) async -> String {
        var lines: [String] = ["Engines:"]
        for report in await service.reports() {
            lines.append("- \(report.id) (\(report.name)): \(report.status.summary)")
            if case .setup(_, let steps) = report.status { lines.append("  setup: " + steps.joined(separator: " ")) }
            if report.status.isReady {
                let off = ImageFeature.allCases.compactMap { f in report.capabilities.whyNot(f).map { "\(f.rawValue): \($0)" } }.filter { !$0.hasPrefix("upscale") }
                if !off.isEmpty { lines.append("  cannot: " + off.joined(separator: " | ")) }
                if !report.models.isEmpty { lines.append("  models: " + report.models.map(\.id).joined(separator: ", ")) }
            }
        }
        lines.append("Catalogue (download with image_download_model):")
        for row in service.curated() where query.isEmpty || row.entry.name.localizedCaseInsensitiveContains(query) || row.entry.id.contains(query.lowercased()) {
            let e = row.entry
            lines.append("- \(e.id) · \(e.name) · \(e.kind.title) · \(ByteCountFormatter.string(fromByteCount: e.sizeBytes, countStyle: .file)) · \(e.license)"
                         + (e.commercialUse == false ? " (non-commercial)" : "") + (e.gating != .open ? " · gated" : "") + (row.installed ? " · INSTALLED" : "")
                         + " · engines: \(e.engines.joined(separator: ","))")
        }
        let jobs = await service.downloader.snapshot()
        if !jobs.isEmpty { lines.append("Downloads:"); lines += jobs.map { "- \($0.title): \($0.state) \(Int($0.fraction * 100))%" } }
        return lines.joined(separator: "\n")
    }

    private func download(service: ImageStudioService, args: [String: Any]) async throws -> String {
        guard let id = args["model_id"] as? String, let entry = CuratedImageCatalog.entries.first(where: { $0.id == id }) else {
            throw ImageToolError.message("Unknown model_id. Use image_list_models for the catalogue ids.")
        }
        if service.store.isInstalled(entry) { return "\(entry.name) is already installed." }
        if entry.isLargeDownload, (args["confirm_large"] as? Bool) != true {
            throw ImageToolError.message("\(entry.name) is \(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file)). Ask the user, then call again with confirm_large=true.")
        }
        let destination = try service.destination(for: entry)
        let job = await service.downloader.enqueue(entry, to: destination)
        await service.downloader.waitUntilIdle()
        guard let result = await service.downloader.snapshot().first(where: { $0.id == job }) else { return "Download not found." }
        switch result.state {
        case .finished: return "Downloaded \(entry.name) (\(ByteCountFormatter.string(fromByteCount: result.bytesDone, countStyle: .file)))."
        case .failed(let why): throw ImageToolError.message(why)
        default: return "Download ended: \(result.state)."
        }
    }
}

enum ImageToolError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
}
