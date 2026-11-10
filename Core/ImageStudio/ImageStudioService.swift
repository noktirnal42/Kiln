import CoreGraphics
import Foundation

public struct EngineReport: Sendable {
    public let id: String
    public let name: String
    public let kind: ImageEngineKind
    public let status: ImageEngineStatus
    public let capabilities: ImageEngineCapabilities
    public let models: [EngineModel]
}

/// The one entry point the GUI, the agent tools and the MCP server share: picks an engine, checks the request against what
/// the engine can do, runs it, embeds the settings in each picture and files it in the history.
public final class ImageStudioService: @unchecked Sendable {
    public let engines: [any ImageEngine]
    public let history: ImageHistory
    public let prompts: PromptLibrary
    public let store: ImageModelStore
    public let downloader: ImageModelDownloader

    public init(engines: [any ImageEngine], history: ImageHistory = .default, prompts: PromptLibrary = .default,
                store: ImageModelStore = ImageModelStore(), downloader: ImageModelDownloader? = nil) {
        self.engines = engines; self.history = history; self.prompts = prompts; self.store = store
        self.downloader = downloader ?? ImageModelDownloader(store: store)
    }

    /// The engines Kiln ships: in-process MLX, Draw Things, AUTOMATIC1111/Forge and ComfyUI, with Hugging Face and Civitai tokens read from the Keychain on demand.
    public static func makeDefault() -> ImageStudioService {
        let store = ImageModelStore()
        let keychain = KeychainService()
        let downloader = ImageModelDownloader(
            store: store,
            huggingFaceToken: keychain.secretProvider(module: providersKeychainModule, key: "huggingface"),
            civitaiToken: keychain.secretProvider(module: providersKeychainModule, key: "civitai"))
        let defaults = UserDefaults.standard
        func port(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
        return ImageStudioService(
            engines: [MLXDiffusionEngine(store: store), A1111CompatibleEngine.drawThings(port: port("image.port.drawthings", 7860)),
                      ComfyUIEngine(port: port("image.port.comfyui", 8188)), A1111CompatibleEngine.automatic1111(port: port("image.port.a1111", 7861))],
            store: store, downloader: downloader)
    }

    public func engine(id: String) -> (any ImageEngine)? { engines.first { $0.id == id } }

    public func reports() async -> [EngineReport] {
        var out: [EngineReport] = []
        for engine in engines {
            let status = await engine.status()
            let ready = status.isReady
            out.append(EngineReport(id: engine.id, name: engine.displayName, kind: engine.kind, status: status,
                                    capabilities: ready ? await engine.capabilities(model: nil) : .none, models: ready ? await engine.models() : []))
        }
        return out
    }

    // MARK: Catalogue

    public struct CatalogRow: Identifiable, Sendable {
        public var id: String { entry.id }
        public let entry: ImageModelEntry
        public let installed: Bool
    }

    public func curated() -> [CatalogRow] {
        CuratedImageCatalog.entries.map { CatalogRow(entry: $0, installed: store.isInstalled($0)) }
    }

    /// Where a downloaded entry should go: the store for diffusers repos, the tool's folder for single files.
    public func destination(for entry: ImageModelEntry) throws -> DownloadDestination {
        switch entry.source {
        case .huggingFace(_, let files, _) where files.isEmpty || files.contains("model_index.json"): return .universalStore
        default: break
        }
        if entry.engines.contains("drawthings"), entry.origin == "Draw Things" || entry.engines == ["drawthings"] {
            guard let folder = ExternalModelFolders.folder(for: .drawThings) else {
                throw ImageStudioError.invalid("Draw Things' Models folder was not found. Open Draw Things once, or set its folder in Image studio → Settings.")
            }
            return .folder(folder)
        }
        if entry.engines.contains("comfyui"), let folder = ExternalModelFolders.folder(for: .comfyUI) { return .folder(folder) }
        if entry.engines.contains("a1111"), let folder = ExternalModelFolders.folder(for: .automatic1111) { return .folder(folder) }
        return .universalStore
    }

    // MARK: Generation

    public func applyStyles(_ names: [String], to request: inout ImageGenerationRequest) {
        let all = prompts.styles()
        for name in names {
            guard let style = all.first(where: { $0.name.lowercased() == name.lowercased() }) else { continue }
            let merged = style.apply(to: request.prompt, negative: request.negativePrompt)
            request.prompt = merged.prompt; request.negativePrompt = merged.negative
            request.styles.append(style.name)
        }
    }

    func pickEngine(for request: ImageGenerationRequest) async throws -> (any ImageEngine, ImageEngineCapabilities, String) {
        func check(_ engine: any ImageEngine, explicit: Bool) async throws -> (any ImageEngine, ImageEngineCapabilities, String)? {
            let status = await engine.status()
            guard status.isReady else {
                if explicit { throw ImageStudioError.engineUnavailable("\(engine.displayName) is not ready: \(status.summary)") }
                return nil
            }
            let caps = await engine.capabilities(model: request.model)
            if let why = caps.whyNot(request.task) {
                if explicit { throw ImageStudioError.unsupported("\(engine.displayName) cannot do \(request.task.title.lowercased()): \(why)") }
                return nil
            }
            if !request.loras.isEmpty, let why = caps.whyNot(.lora) {
                if explicit { throw ImageStudioError.unsupported("\(engine.displayName) cannot apply LoRAs: \(why)") }
                return nil
            }
            let models = await engine.models().filter { $0.kind == .checkpoint }
            var model = request.model
            if model.isEmpty { guard let first = models.first else { return nil }; model = first.id }
            else if !models.contains(where: { $0.id == model }) {
                if explicit { throw ImageStudioError.modelMissing("\(engine.displayName) has no model \"\(model)\". It has: \(models.prefix(8).map(\.id).joined(separator: ", "))") }
                return nil
            }
            return (engine, caps, model)
        }
        if let id = request.engine, !id.isEmpty {
            guard let engine = engine(id: id) else { throw ImageStudioError.invalid("There is no engine \"\(id)\". Engines: \(engines.map(\.id).joined(separator: ", ")).") }
            return try await check(engine, explicit: true)!
        }
        for engine in engines { if let hit = try await check(engine, explicit: false) { return hit } }
        let reports = await reports()
        let reasons = reports.map { "\($0.name): \($0.status.summary)" }.joined(separator: " ")
        throw ImageStudioError.engineUnavailable("No engine can run this request. \(reasons)")
    }

    @discardableResult
    public func generate(_ original: ImageGenerationRequest, progress: @escaping ImageProgressHandler = { _ in }) async throws -> [ImageHistoryItem] {
        var request = original
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImageStudioError.invalid("The prompt is empty.") }
        let (engine, caps, model) = try await pickEngine(for: request)
        request.model = model; request.engine = engine.id
        let multiple = max(8, caps.sideMultiple)
        func fit(_ side: Int) -> Int { min(caps.maxSide, max(caps.minSide, (side + multiple / 2) / multiple * multiple)) }
        request.width = fit(request.width); request.height = fit(request.height)
        request.count = max(1, min(request.count, caps.maxBatch))
        request.steps = max(1, request.steps)
        if request.sampler != nil, caps.whyNot(.samplers) != nil { request.sampler = nil }
        if request.task == .imageToImage || request.task == .inpaint || request.task == .outpaint {
            guard let path = request.initImagePath, FileManager.default.fileExists(atPath: path) else { throw ImageStudioError.invalid("\(request.task.title) needs a source image that exists.") }
        }
        var run = request
        if request.task == .outpaint {
            guard let padding = request.outpaint, !padding.isEmpty, let path = request.initImagePath, let source = MLXDiffusionEngine.loadCGImage(path) else {
                throw ImageStudioError.invalid("Outpainting needs a source image and padding on at least one side.")
            }
            let canvas = try ImageResampler.outpaintCanvas(source: source, padding: padding)
            let canvasURL = try history.stagingURL(), maskURL = try history.stagingURL()
            try canvas.canvas.write(to: canvasURL); try canvas.mask.write(to: maskURL)
            run.task = .inpaint; run.initImagePath = canvasURL.path; run.maskPath = maskURL.path
            run.width = canvas.width; run.height = canvas.height
            run.strength = max(request.strength, 0.9)
        }
        let started = Date()
        let pictures = try await engine.generate(run, progress: progress)
        try Task.checkCancellation()
        let seconds = Date().timeIntervalSince(started) / Double(max(1, pictures.count))
        var items: [ImageHistoryItem] = []
        for picture in pictures {
            let record = GenerationRecord(request: request, engine: engine.id, modelName: model, seed: picture.seed, seconds: seconds)
            items.append(try history.add(png: picture.png, record: record))
        }
        return items
    }

    /// Lanczos upscale of a history picture or any PNG/JPEG file. Honest about being resampling, not AI upscaling.
    public func upscale(path: String, factor: Double) throws -> ImageHistoryItem {
        guard let data = FileManager.default.contents(atPath: path) else { throw ImageStudioError.invalid("Cannot read \(path).") }
        let out = try ImageResampler.upscale(data, factor: factor)
        var request = GenerationMetadata.read(from: data)?.request ?? ImageGenerationRequest(prompt: "Upscaled \(URL(fileURLWithPath: path).lastPathComponent)", model: "lanczos")
        request.styles.append("upscale ×\(factor)")
        let size = ImageResampler.size(of: out)
        request.width = size?.width ?? request.width; request.height = size?.height ?? request.height
        let record = GenerationRecord(request: request, engine: "lanczos", modelName: "Lanczos resampling", seed: GenerationMetadata.read(from: data)?.seed ?? 0, seconds: 0)
        return try history.add(png: out, record: record)
    }

    /// Files a picture in the Media gallery. The gallery keeps its own copy.
    @discardableResult
    public func sendToMedia(_ item: ImageHistoryItem, gallery: MediaGallery = .default) throws -> MediaItem {
        let data = try Data(contentsOf: item.url)
        return try gallery.add(data: data, fileExtension: "png", kind: .image, title: String((item.record?.request.prompt ?? "Image studio").prefix(60)),
                               origin: .generated, prompt: item.record?.request.prompt, provider: "image-studio:\(item.record?.engine ?? "?")")
    }
}
