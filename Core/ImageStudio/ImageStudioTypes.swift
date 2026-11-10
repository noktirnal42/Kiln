import Foundation

// The vocabulary of the Image studio: what a generation request is, what an engine can do, and what it reports.
// Everything here is plain data so the GUI, the agent tools and the history all speak the same types.

/// What a request asks an engine to do. Outpainting is prepared by the service (the canvas is padded and the new border
/// becomes the mask) and then runs as an inpaint, so an engine only ever implements the first three.
public enum ImageTask: String, Codable, CaseIterable, Sendable {
    case textToImage = "text_to_image"
    case imageToImage = "image_to_image"
    case inpaint
    case outpaint

    public var title: String {
        switch self {
        case .textToImage: "Text to image"
        case .imageToImage: "Image to image"
        case .inpaint: "Inpaint"
        case .outpaint: "Outpaint"
        }
    }
}

public struct LoRAWeight: Codable, Equatable, Hashable, Sendable {
    /// The LoRA's name as the engine knows it (file stem or the engine's own id).
    public var name: String
    public var weight: Double
    public init(name: String, weight: Double = 1.0) { self.name = name; self.weight = weight }
}

public struct OutpaintPadding: Codable, Equatable, Sendable {
    public var left: Int, right: Int, top: Int, bottom: Int
    public init(left: Int = 0, right: Int = 0, top: Int = 0, bottom: Int = 0) {
        self.left = left; self.right = right; self.top = top; self.bottom = bottom
    }
    public var isEmpty: Bool { left <= 0 && right <= 0 && top <= 0 && bottom <= 0 }
}

/// One generation, fully described. It is what gets embedded in every PNG, so "re-run" is just decoding it again.
public struct ImageGenerationRequest: Codable, Equatable, Sendable {
    public var task: ImageTask = .textToImage
    public var prompt: String
    public var negativePrompt: String = ""
    /// The engine-native model: a folder id for the in-process engine, a checkpoint name for external ones.
    public var model: String
    /// Engine id ("mlx", "drawthings", "comfyui", "a1111"). Nil lets the service pick the first ready engine that can.
    public var engine: String?
    public var width: Int = 512
    public var height: Int = 512
    public var steps: Int = 4
    public var guidance: Double = 0
    /// Nil picks a random seed; the seed that was used is always reported back.
    public var seed: Int64?
    /// Images per run.
    public var count: Int = 1
    public var sampler: String?
    /// How far image-to-image and inpaint depart from the source (0 keeps it, 1 ignores it).
    public var strength: Double = 0.75
    public var loras: [LoRAWeight] = []
    /// Source image for image-to-image, inpaint and outpaint (a file path).
    public var initImagePath: String?
    /// White = repaint, black = keep. Inpaint only.
    public var maskPath: String?
    public var outpaint: OutpaintPadding?
    /// Style names applied (already merged into `prompt` and `negativePrompt`; kept so the history can show them).
    public var styles: [String] = []

    public init(prompt: String, model: String, task: ImageTask = .textToImage) {
        self.prompt = prompt; self.model = model; self.task = task
    }

    enum CodingKeys: String, CodingKey {
        case task, prompt, negativePrompt, model, engine, width, height, steps, guidance, seed, count, sampler
        case strength, loras, initImagePath, maskPath, outpaint, styles
    }

    /// Tolerant decoding: a record written by an older or newer Kiln still opens.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decode(String.self, forKey: .prompt)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        task = try c.decodeIfPresent(ImageTask.self, forKey: .task) ?? .textToImage
        negativePrompt = try c.decodeIfPresent(String.self, forKey: .negativePrompt) ?? ""
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 512
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 512
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 4
        guidance = try c.decodeIfPresent(Double.self, forKey: .guidance) ?? 0
        seed = try c.decodeIfPresent(Int64.self, forKey: .seed)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
        sampler = try c.decodeIfPresent(String.self, forKey: .sampler)
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 0.75
        loras = try c.decodeIfPresent([LoRAWeight].self, forKey: .loras) ?? []
        initImagePath = try c.decodeIfPresent(String.self, forKey: .initImagePath)
        maskPath = try c.decodeIfPresent(String.self, forKey: .maskPath)
        outpaint = try c.decodeIfPresent(OutpaintPadding.self, forKey: .outpaint)
        styles = try c.decodeIfPresent([String].self, forKey: .styles) ?? []
    }
}

public struct ImageSampler: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum ImageFeature: String, CaseIterable, Sendable {
    case textToImage, imageToImage, inpaint, outpaint, lora, controlNet, negativePrompt, samplers, upscale
}

/// What an engine can do right now, and for each thing it cannot, why. The UI disables a control and shows the reason;
/// the service refuses a request that needs it. Nothing is silently dropped.
public struct ImageEngineCapabilities: Equatable, Sendable {
    public var supported: Set<ImageFeature>
    public var reasons: [ImageFeature: String]
    public var samplers: [ImageSampler]
    public var maxBatch: Int
    public var maxSide: Int
    public var minSide: Int
    public var sideMultiple: Int

    public init(supported: Set<ImageFeature>, reasons: [ImageFeature: String] = [:], samplers: [ImageSampler] = [],
                maxBatch: Int = 4, maxSide: Int = 2048, minSide: Int = 256, sideMultiple: Int = 64) {
        self.supported = supported; self.reasons = reasons; self.samplers = samplers
        self.maxBatch = maxBatch; self.maxSide = maxSide; self.minSide = minSide; self.sideMultiple = sideMultiple
    }

    public func supports(_ feature: ImageFeature) -> Bool { supported.contains(feature) }

    /// Why a feature is off, or nil when it is on.
    public func whyNot(_ feature: ImageFeature) -> String? {
        supported.contains(feature) ? nil : (reasons[feature] ?? "This engine does not support it.")
    }

    public func canRun(_ task: ImageTask) -> Bool {
        switch task {
        case .textToImage: supported.contains(.textToImage)
        case .imageToImage: supported.contains(.imageToImage)
        case .inpaint: supported.contains(.inpaint)
        case .outpaint: supported.contains(.inpaint) && supported.contains(.outpaint)
        }
    }

    /// The reason a task cannot run, or nil when it can.
    public func whyNot(_ task: ImageTask) -> String? {
        if canRun(task) { return nil }
        switch task {
        case .textToImage: return whyNot(ImageFeature.textToImage)
        case .imageToImage: return whyNot(ImageFeature.imageToImage)
        case .inpaint: return whyNot(ImageFeature.inpaint)
        case .outpaint: return whyNot(ImageFeature.inpaint) ?? whyNot(ImageFeature.outpaint)
        }
    }

    public static let none = ImageEngineCapabilities(supported: [])
}

public enum ImageEngineStatus: Equatable, Sendable {
    case ready(String)
    /// Not usable yet: what is missing and what to do about it. Never faked output.
    case setup(reason: String, steps: [String])

    public var isReady: Bool { if case .ready = self { true } else { false } }

    public var summary: String {
        switch self {
        case .ready(let detail): detail
        case .setup(let reason, _): reason
        }
    }
}

public enum ImageEngineKind: String, Sendable { case inProcess, external }

/// A model an engine can use right now.
public struct EngineModel: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: ImageModelKind
    /// Free-text family such as "SDXL" or "SD 2.x" when known.
    public var family: String?
    public init(id: String, name: String, kind: ImageModelKind = .checkpoint, family: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.family = family
    }
}

public struct ImageProgress: Equatable, Sendable {
    public var phase: String
    /// 0...1 when known.
    public var fraction: Double?
    public init(phase: String, fraction: Double? = nil) { self.phase = phase; self.fraction = fraction }
}

public struct GeneratedPicture: Sendable {
    public let png: Data
    public let seed: Int64
    public init(png: Data, seed: Int64) { self.png = png; self.seed = seed }
}

public typealias ImageProgressHandler = @Sendable (ImageProgress) -> Void

/// Something that turns a request into pictures. Engines are real or they say they are not set up; none fabricates output.
public protocol ImageEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    var kind: ImageEngineKind { get }
    func status() async -> ImageEngineStatus
    func capabilities(model: String?) async -> ImageEngineCapabilities
    func models() async -> [EngineModel]
    func generate(_ request: ImageGenerationRequest, progress: @escaping ImageProgressHandler) async throws -> [GeneratedPicture]
}

public enum ImageStudioError: LocalizedError, Equatable {
    case invalid(String)
    case engineUnavailable(String)
    case unsupported(String)
    case modelMissing(String)
    case failed(String)
    case downloadFailed(String)
    case insufficientSpace(needed: Int64, available: Int64, volume: String)
    case checksumMismatch(file: String)
    case needsToken(String)
    case needsAcceptance(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalid(let m), .engineUnavailable(let m), .unsupported(let m), .modelMissing(let m), .failed(let m),
             .downloadFailed(let m), .needsToken(let m), .needsAcceptance(let m):
            m
        case .insufficientSpace(let needed, let available, let volume):
            "Not enough free space on \(volume): this needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) and " +
            "\(ByteCountFormatter.string(fromByteCount: max(0, available), countStyle: .file)) is free."
        case .checksumMismatch(let file): "The downloaded file \(file) does not match its published checksum, so it was discarded."
        case .cancelled: "Cancelled."
        }
    }
}
