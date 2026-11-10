// Copyright © 2024 Apple Inc.

import Foundation
import MLX
import MLXNN

// port of https://github.com/ml-explore/mlx-examples/blob/main/stable_diffusion/stable_diffusion/model_io.py

/// Errors that can occur when loading stable diffusion models.
public enum StableDiffusionError: LocalizedError {
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let filename):
            return "Required model file '\(filename)' is missing from the model folder."
        }
    }
}

/// Configuration for loading stable diffusion weights.
///
/// These options can be tuned to conserve memory.
public struct LoadConfiguration: Sendable {

    /// convert weights to float16
    public var float16 = true

    /// quantize weights
    public var quantize = false

    public var dType: DType {
        float16 ? .float16 : .float32
    }

    public init(float16: Bool = true, quantize: Bool = false) {
        self.float16 = float16
        self.quantize = quantize
    }
}

/// Parameters for evaluating a stable diffusion prompt and generating latents
public struct EvaluateParameters: Sendable {

    /// `cfg` value from the preset
    public var cfgWeight: Float

    /// number of steps -- default is from the preset
    public var steps: Int

    /// number of images to generate at a time
    public var imageCount = 1
    public var decodingBatchSize = 1

    /// size of the latent tensor -- the result image is a factor of 8 larger than this
    public var latentSize = [64, 64]

    public var seed: UInt64
    public var prompt = ""
    public var negativePrompt = ""

    public init(
        cfgWeight: Float, steps: Int, imageCount: Int = 1, decodingBatchSize: Int = 1,
        latentSize: [Int] = [64, 64], seed: UInt64? = nil, prompt: String = "",
        negativePrompt: String = ""
    ) {
        self.cfgWeight = cfgWeight
        self.steps = steps
        self.imageCount = imageCount
        self.decodingBatchSize = decodingBatchSize
        self.latentSize = latentSize
        self.seed = seed ?? UInt64(Date.timeIntervalSinceReferenceDate * 1000)
        self.prompt = prompt
        self.negativePrompt = negativePrompt
    }
}

/// File types, as relative paths inside a diffusers-layout model folder.
enum FileKey: CaseIterable {
    case unetConfig, unetWeights
    case textEncoderConfig, textEncoderWeights
    case textEncoderConfig2, textEncoderWeights2
    case vaeConfig, vaeWeights
    case diffusionConfig
    case tokenizerVocabulary, tokenizerMerges
    case tokenizerVocabulary2, tokenizerMerges2

    var path: String {
        switch self {
        case .unetConfig: "unet/config.json"
        case .unetWeights: "unet/diffusion_pytorch_model.safetensors"
        case .textEncoderConfig: "text_encoder/config.json"
        case .textEncoderWeights: "text_encoder/model.safetensors"
        case .textEncoderConfig2: "text_encoder_2/config.json"
        case .textEncoderWeights2: "text_encoder_2/model.safetensors"
        case .vaeConfig: "vae/config.json"
        case .vaeWeights: "vae/diffusion_pytorch_model.safetensors"
        case .diffusionConfig: "scheduler/scheduler_config.json"
        case .tokenizerVocabulary: "tokenizer/vocab.json"
        case .tokenizerMerges: "tokenizer/merges.txt"
        case .tokenizerVocabulary2: "tokenizer_2/vocab.json"
        case .tokenizerMerges2: "tokenizer_2/merges.txt"
        }
    }

    var isWeights: Bool {
        switch self {
        case .unetWeights, .textEncoderWeights, .textEncoderWeights2, .vaeWeights: true
        default: false
        }
    }
}

/// The architecture a diffusers-layout folder holds.
public enum DiffusionFamily: String, Codable, Sendable {
    /// Stable Diffusion 2.x architecture (OpenCLIP-H text encoder): SD 2.1, SD-Turbo.
    case sd2
    /// Stable Diffusion XL architecture (two text encoders): SDXL base, SDXL-Turbo, Lightning, fine-tunes.
    case sdxl

    /// The files a download must fetch, preferring the half-precision variant when the repo has one.
    public var requiredFiles: [String] { Self.files(for: self).map(\.path) }

    static func files(for family: DiffusionFamily) -> [FileKey] {
        switch family {
        case .sd2:
            [.unetConfig, .unetWeights, .textEncoderConfig, .textEncoderWeights, .vaeConfig, .vaeWeights,
             .diffusionConfig, .tokenizerVocabulary, .tokenizerMerges]
        case .sdxl:
            FileKey.allCases
        }
    }

    /// Relative path of the half-precision twin of a weights file (`unet/x.safetensors` -> `unet/x.fp16.safetensors`).
    public static func fp16Path(_ path: String) -> String {
        guard path.hasSuffix(".safetensors") else { return path }
        return String(path.dropLast(".safetensors".count)) + ".fp16.safetensors"
    }
}

/// A model folder plus what to do with it. `distilled` models (Turbo, Lightning) use the Euler-ancestral sampler
/// and no classifier-free guidance by default.
public struct StableDiffusionConfiguration: Sendable {
    public let id: String
    public let directory: URL
    public let family: DiffusionFamily
    public let distilled: Bool

    public init(id: String, directory: URL, family: DiffusionFamily, distilled: Bool) {
        self.id = id; self.directory = directory; self.family = family; self.distilled = distilled
    }

    public var defaultParameters: EvaluateParameters {
        distilled ? EvaluateParameters(cfgWeight: 0, steps: family == .sdxl ? 2 : 1)
                  : EvaluateParameters(cfgWeight: 7.5, steps: 30)
    }

    /// Resolves a file in the folder; weights prefer the `.fp16.safetensors` twin when present.
    func url(_ key: FileKey) throws -> URL {
        let fm = FileManager.default
        if key.isWeights {
            let half = directory.appendingPathComponent(DiffusionFamily.fp16Path(key.path))
            if fm.fileExists(atPath: half.path) { return half }
        }
        let plain = directory.appendingPathComponent(key.path)
        guard fm.fileExists(atPath: plain.path) else { throw StableDiffusionError.fileNotFound(key.path) }
        return plain
    }

    public func textToImageGenerator(configuration: LoadConfiguration) throws -> TextToImageGenerator? {
        try make(configuration) as? TextToImageGenerator
    }

    public func imageToImageGenerator(configuration: LoadConfiguration) throws -> ImageToImageGenerator? {
        try make(configuration) as? ImageToImageGenerator
    }

    private func make(_ load: LoadConfiguration) throws -> StableDiffusion {
        switch family {
        case .sd2:
            let sd = try StableDiffusionBase(configuration: self, dType: load.dType)
            if load.quantize {
                quantize(model: sd.textEncoder, filter: { _, m in m is Linear })
                quantize(model: sd.unet, groupSize: 32, bits: 8)
            }
            return sd
        case .sdxl:
            let sd = try StableDiffusionXL(configuration: self, dType: load.dType)
            if load.quantize {
                quantize(model: sd.textEncoder, filter: { _, m in m is Linear })
                quantize(model: sd.textEncoder2, filter: { _, m in m is Linear })
                quantize(model: sd.unet, groupSize: 32, bits: 8)
            }
            return sd
        }
    }
}

// MARK: - Key Mapping

func keyReplace(_ replace: String, _ with: String) -> @Sendable (String) -> String? {
    return { [replace, with] key in
        if key.contains(replace) {
            return key.replacingOccurrences(of: replace, with: with)
        }
        return nil
    }
}

func dropPrefix(_ prefix: String) -> @Sendable (String) -> String? {
    return { [prefix] key in
        if key.hasPrefix(prefix) {
            return String(key.dropFirst(prefix.count))
        }
        return nil
    }
}

// see map_unet_weights()

let unetRules: [@Sendable (String) -> String?] = [
    // Map up/downsampling
    keyReplace("downsamplers.0.conv", "downsample"),
    keyReplace("upsamplers.0.conv", "upsample"),

    // Map the mid block
    keyReplace("mid_block.resnets.0", "mid_blocks.0"),
    keyReplace("mid_block.attentions.0", "mid_blocks.1"),
    keyReplace("mid_block.resnets.1", "mid_blocks.2"),

    // Map attention layers
    keyReplace("to_k", "key_proj"),
    keyReplace("to_out.0", "out_proj"),
    keyReplace("to_q", "query_proj"),
    keyReplace("to_v", "value_proj"),

    // Map transformer ffn
    keyReplace("ff.net.2", "linear3"),
]

func unetRemap(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var key = key
    var value = value

    for rule in unetRules {
        key = rule(key) ?? key
    }

    // Map transformer ffn
    if key.contains("ff.net.0") {
        let k1 = key.replacingOccurrences(of: "ff.net.0.proj", with: "linear1")
        let k2 = key.replacingOccurrences(of: "ff.net.0.proj", with: "linear2")
        let (v1, v2) = value.split()
        return [(k1, v1), (k2, v2)]
    }

    if key.contains("conv_shortcut.weight") {
        value = value.squeezed()
    }

    // Transform the weights from 1x1 convs to linear
    if value.ndim == 4 && (key.contains("proj_in") || key.contains("proj_out")) {
        value = value.squeezed()
    }

    if value.ndim == 4 {
        value = value.transposed(0, 2, 3, 1)
        value = value.reshaped(-1).reshaped(value.shape)
    }

    return [(key, value)]
}

let clipRules: [@Sendable (String) -> String?] = [
    dropPrefix("text_model."),
    dropPrefix("embeddings."),
    dropPrefix("encoder."),

    // Map attention layers
    keyReplace("self_attn.", "attention."),
    keyReplace("q_proj.", "query_proj."),
    keyReplace("k_proj.", "key_proj."),
    keyReplace("v_proj.", "value_proj."),

    // Map ffn layers
    keyReplace("mlp.fc1", "linear1"),
    keyReplace("mlp.fc2", "linear2"),
]

func clipRemap(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var key = key

    for rule in clipRules {
        key = rule(key) ?? key
    }

    // not used
    if key == "position_ids" {
        return []
    }

    return [(key, value)]
}

let vaeRules: [@Sendable (String) -> String?] = [
    // Map up/downsampling
    keyReplace("downsamplers.0.conv", "downsample"),
    keyReplace("upsamplers.0.conv", "upsample"),

    // Map attention layers
    keyReplace("to_k", "key_proj"),
    keyReplace("to_out.0", "out_proj"),
    keyReplace("to_q", "query_proj"),
    keyReplace("to_v", "value_proj"),

    // Map the mid block
    keyReplace("mid_block.resnets.0", "mid_blocks.0"),
    keyReplace("mid_block.attentions.0", "mid_blocks.1"),
    keyReplace("mid_block.resnets.1", "mid_blocks.2"),

    keyReplace("mid_blocks.1.key.", "mid_blocks.1.key_proj."),
    keyReplace("mid_blocks.1.query.", "mid_blocks.1.query_proj."),
    keyReplace("mid_blocks.1.value.", "mid_blocks.1.value_proj."),
    keyReplace("mid_blocks.1.proj_attn.", "mid_blocks.1.out_proj."),

]

func vaeRemap(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var key = key
    var value = value

    for rule in vaeRules {
        key = rule(key) ?? key
    }

    // Map the quant/post_quant layers
    if key.contains("quant_conv") {
        key = key.replacingOccurrences(of: "quant_conv", with: "quant_proj")
        value = value.squeezed()
    }

    // Map the conv_shortcut to linear
    if key.contains("conv_shortcut.weight") {
        value = value.squeezed()
    }

    if value.ndim == 4 {
        value = value.transposed(0, 2, 3, 1)
        value = value.reshaped(-1).reshaped(value.shape)
    }

    return [(key, value)]
}

func loadWeights(
    url: URL, model: Module, mapper: (String, MLXArray) -> [(String, MLXArray)], dType: DType
) throws {
    let weights = try loadArrays(url: url).flatMap { mapper($0.key, $0.value.asType(dType)) }

    // Note: not using verifier because some shapes change upon load
    try model.update(parameters: ModuleParameters.unflattened(weights), verify: .none)
}

// MARK: - Loading

func resolve(configuration: StableDiffusionConfiguration, key: FileKey) throws -> URL {
    try configuration.url(key)
}

func loadConfiguration<T: Decodable>(configuration: StableDiffusionConfiguration, key: FileKey, type: T.Type) throws -> T {
    let url = try resolve(configuration: configuration, key: key)
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

func loadUnet(configuration: StableDiffusionConfiguration, dType: DType) throws -> UNetModel {
    let unetConfiguration = try loadConfiguration(configuration: configuration, key: .unetConfig, type: UNetConfiguration.self)
    let model = UNetModel(configuration: unetConfiguration)
    let weightsURL = try resolve(configuration: configuration, key: .unetWeights)
    try loadWeights(url: weightsURL, model: model, mapper: unetRemap, dType: dType)
    return model
}

func loadTextEncoder(
    configuration: StableDiffusionConfiguration,
    configKey: FileKey = .textEncoderConfig, weightsKey: FileKey = .textEncoderWeights, dType: DType
) throws -> CLIPTextModel {
    let clipConfiguration = try loadConfiguration(configuration: configuration, key: configKey, type: CLIPTextModelConfiguration.self)
    let model = CLIPTextModel(configuration: clipConfiguration)
    let weightsURL = try resolve(configuration: configuration, key: weightsKey)
    try loadWeights(url: weightsURL, model: model, mapper: clipRemap, dType: dType)
    return model
}

func loadAutoEncoder(configuration: StableDiffusionConfiguration, dType: DType) throws -> Autoencoder {
    let autoEncoderConfiguration = try loadConfiguration(configuration: configuration, key: .vaeConfig, type: AutoencoderConfiguration.self)
    let model = Autoencoder(configuration: autoEncoderConfiguration)
    let weightsURL = try resolve(configuration: configuration, key: .vaeWeights)
    try loadWeights(url: weightsURL, model: model, mapper: vaeRemap, dType: dType)
    return model
}

func loadDiffusionConfiguration(configuration: StableDiffusionConfiguration) throws -> DiffusionConfiguration {
    try loadConfiguration(configuration: configuration, key: .diffusionConfig, type: DiffusionConfiguration.self)
}

// MARK: - Tokenizer

func loadTokenizer(
    configuration: StableDiffusionConfiguration,
    vocabulary: FileKey = .tokenizerVocabulary, merges: FileKey = .tokenizerMerges
) throws -> CLIPTokenizer {
    let vocabularyURL = try resolve(configuration: configuration, key: vocabulary)
    let mergesURL = try resolve(configuration: configuration, key: merges)
    let vocabulary = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: vocabularyURL))
    let merges = try String(contentsOf: mergesURL, encoding: .utf8)
        .components(separatedBy: .newlines)
        .dropFirst()
        .filter { !$0.isEmpty }
    return CLIPTokenizer(merges: merges, vocabulary: vocabulary)
}
