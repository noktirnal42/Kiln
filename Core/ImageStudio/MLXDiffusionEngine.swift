import CoreGraphics
import Foundation
import ImageIO
import KilnDiffusion
import MLX
import UniformTypeIdentifiers

/// In-process generation on Apple silicon with MLX: SD 2.x-architecture models (SD-Turbo) and SDXL-architecture models
/// (SDXL-Turbo, SDXL base and fine-tunes) from diffusers folders in the universal model store.
public actor MLXDiffusionEngine: ImageEngine {
    public nonisolated let id = "mlx"
    public nonisolated let displayName = "MLX (on this Mac)"
    public nonisolated let kind = ImageEngineKind.inProcess

    private let store: ImageModelStore
    private var loadedID: String?
    private var loaded: LoadedGenerators?

    public init(store: ImageModelStore = ImageModelStore()) { self.store = store }

    /// Generators are MLX modules, not Sendable; the actor serialises every use of them.
    private final class LoadedGenerators: @unchecked Sendable {
        let configuration: StableDiffusionConfiguration
        let text: TextToImageGenerator
        let image: ImageToImageGenerator?
        init(configuration: StableDiffusionConfiguration, text: TextToImageGenerator, image: ImageToImageGenerator?) {
            self.configuration = configuration; self.text = text; self.image = image
        }
    }

    public func status() async -> ImageEngineStatus {
        let installed = store.installedDiffusers().filter { Self.supports(family: $0.family) }
        if installed.isEmpty {
            return .setup(reason: "No image model is installed for the MLX engine.",
                          steps: ["Open Models, choose SD-Turbo (2.6 GB) and download it.", "SDXL-Turbo and SDXL fine-tunes (about 7 GB each) also run here."])
        }
        return .ready("\(installed.count) model\(installed.count == 1 ? "" : "s") installed")
    }

    static func supports(family: String) -> Bool { family == "sd2" || family == "sdxl" }

    public func capabilities(model: String?) async -> ImageEngineCapabilities {
        ImageEngineCapabilities(
            supported: [.textToImage, .imageToImage, .negativePrompt],
            reasons: [
                .inpaint: "The MLX engine has no inpainting. Use Draw Things, ComfyUI or Forge.",
                .outpaint: "Outpainting needs inpainting, which the MLX engine does not have.",
                .lora: "LoRA is not implemented in the MLX engine. Use Draw Things, ComfyUI or Forge.",
                .controlNet: "ControlNet is not implemented in the MLX engine.",
                .samplers: "The MLX engine picks the sampler itself (Euler ancestral for Turbo models, Euler otherwise).",
                .upscale: "Upscaling is done by the Image studio, not the engine.",
            ],
            samplers: [], maxBatch: 4, maxSide: 1024, minSide: 256, sideMultiple: 64)
    }

    public func models() async -> [EngineModel] {
        store.installedDiffusers().filter { Self.supports(family: $0.family) }
            .map { EngineModel(id: $0.repoID, name: $0.repoID.split(separator: "/").last.map(String.init) ?? $0.repoID,
                               kind: .checkpoint, family: $0.family == "sdxl" ? "SDXL" : "SD 2.x") }
    }

    public func generate(_ request: ImageGenerationRequest, progress: @escaping ImageProgressHandler) async throws -> [GeneratedPicture] {
        guard request.task == .textToImage || request.task == .imageToImage else {
            throw ImageStudioError.unsupported("The MLX engine cannot do \(request.task.title.lowercased()).")
        }
        guard let model = store.installedDiffusers().first(where: { $0.repoID == request.model }) else {
            throw ImageStudioError.modelMissing("\(request.model) is not installed. Download it in Image studio → Models.")
        }
        guard Self.supports(family: model.family) else { throw ImageStudioError.unsupported("\(model.family) models do not run in the MLX engine.") }
        progress(ImageProgress(phase: "Loading \(model.repoID)"))
        let generators = try load(model)
        var sourceArray: MLXArray?
        if request.task == .imageToImage {
            guard let path = request.initImagePath, let cg = Self.loadCGImage(path) else { throw ImageStudioError.invalid("Image to image needs a readable source image.") }
            guard generators.image != nil else { throw ImageStudioError.unsupported("This model cannot do image to image in the MLX engine.") }
            let scaled = Self.resized(cg, width: request.width, height: request.height)
            sourceArray = (KilnDiffusion.Image(image: scaled).data.asType(.float32) / 255) * 2 - 1
        }
        let source = ArrayBox(sourceArray)
        var pictures: [GeneratedPicture] = []
        let total = max(1, min(request.count, 4))
        for index in 0..<total {
            try Task.checkCancellation()
            let seed = (request.seed ?? Int64.random(in: 0..<Int64(Int32.max))) &+ Int64(index)
            var draft = generators.configuration.defaultParameters
            draft.prompt = request.prompt
            draft.negativePrompt = request.negativePrompt
            draft.steps = max(1, request.steps)
            draft.cfgWeight = Float(request.guidance)
            draft.seed = UInt64(bitPattern: seed)
            draft.latentSize = [request.height / 8, request.width / 8]
            let parameters = draft
            let png: Data = try await Self.onWorkerThread {
                let latents: DenoiseIterator
                if let array = source.value, let imageGenerator = generators.image {
                    latents = imageGenerator.generateLatents(image: array, parameters: parameters, strength: Float(request.strength))
                } else {
                    latents = generators.text.generateLatents(parameters: parameters)
                }
                let steps = max(1, latents.underestimatedCount)
                var last: MLXArray?
                var n = 0
                for xt in latents {
                    eval(xt); last = xt; n += 1
                    progress(ImageProgress(phase: "Image \(index + 1) of \(total): step \(n) of \(steps)",
                                           fraction: (Double(index) + Double(n) / Double(steps)) / Double(total)))
                }
                guard let last else { throw ImageStudioError.failed("The model produced no latents.") }
                var raster = (generators.text.decode(xt: last)[0] * 255).asType(.uint8)
                eval(raster)
                raster = raster.squeezed()
                guard let data = Self.png(KilnDiffusion.Image(raster).asCGImage()) else { throw ImageStudioError.failed("The image could not be encoded.") }
                return data
            }
            pictures.append(GeneratedPicture(png: png, seed: seed))
        }
        return pictures
    }

    private final class ArrayBox: @unchecked Sendable {
        let value: MLXArray?
        init(_ value: MLXArray?) { self.value = value }
    }

    private func load(_ model: InstalledImageModel) throws -> LoadedGenerators {
        if loadedID == model.repoID, let loaded { return loaded }
        loaded = nil
        Memory.clearCache()
        let family: DiffusionFamily = model.family == "sdxl" ? .sdxl : .sd2
        let configuration = StableDiffusionConfiguration(id: model.repoID, directory: URL(fileURLWithPath: model.path), family: family, distilled: model.distilled)
        let options = LoadConfiguration(float16: true, quantize: false)
        guard let text = try configuration.textToImageGenerator(configuration: options) else { throw ImageStudioError.unsupported("This model has no text-to-image generator.") }
        let image = try configuration.imageToImageGenerator(configuration: options)
        text.ensureLoaded()
        let result = LoadedGenerators(configuration: configuration, text: text, image: image)
        loaded = result; loadedID = model.repoID
        return result
    }

    // MARK: Helpers

    static func onWorkerThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }

    static func loadCGImage(_ path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
