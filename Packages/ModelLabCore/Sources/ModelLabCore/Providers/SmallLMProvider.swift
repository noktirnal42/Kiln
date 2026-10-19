import Foundation
import MLX
import MLXNN
import MLXOptimizers
import MLXRandom

/// Maps corpus characters to integer ids and back. This is the simplest
/// honest way to get a genuinely "from scratch" language model with no
/// external tokenizer download: the vocabulary is built directly from the
/// training corpus, so there is no pretrained artifact anywhere in this
/// path — model weights, tokenizer, and everything else are produced by
/// this run alone.
public struct CharTokenizer: Codable, Sendable {
    public let charactersByID: [String]
    private let idsByCharacter: [String: Int]

    public var vocabSize: Int { charactersByID.count }

    public init(corpus: String) {
        var seen = Set<String>()
        var ordered: [String] = []
        for character in corpus {
            let s = String(character)
            if !seen.contains(s) {
                seen.insert(s)
                ordered.append(s)
            }
        }
        ordered.sort()
        self.charactersByID = ordered
        var mapping: [String: Int] = [:]
        for (index, character) in ordered.enumerated() { mapping[character] = index }
        self.idsByCharacter = mapping
    }

    public func encode(_ text: String) -> [Int] {
        text.compactMap { idsByCharacter[String($0)] }
    }

    public func decode(_ ids: [Int]) -> String {
        ids.compactMap { $0 >= 0 && $0 < charactersByID.count ? charactersByID[$0] : nil }.joined()
    }
}

public struct TinyLMConfig: Codable, Sendable {
    public var vocabSize: Int
    public var contextLength: Int
    public var dimensions: Int
    public var numHeads: Int
    public var numLayers: Int
    public var mlpDimensions: Int

    public init(vocabSize: Int, contextLength: Int, dimensions: Int, numHeads: Int, numLayers: Int, mlpDimensions: Int) {
        self.vocabSize = vocabSize
        self.contextLength = contextLength
        self.dimensions = dimensions
        self.numHeads = numHeads
        self.numLayers = numLayers
        self.mlpDimensions = mlpDimensions
    }
}

/// One pre-norm decoder block: causal self-attention + an MLP, each with a
/// residual connection. Shape mirrors `MLXNN.TransformerEncoderLayer`
/// (bundled with mlx-swift), adapted to decoder-only causal attention.
final class TinyBlock: Module {
    @ModuleInfo var attention: MultiHeadAttention
    @ModuleInfo var ln1: LayerNorm
    @ModuleInfo var ln2: LayerNorm
    @ModuleInfo var fc1: Linear
    @ModuleInfo var fc2: Linear
    let activation = GELU()

    init(dimensions: Int, numHeads: Int, mlpDimensions: Int) {
        attention = MultiHeadAttention(dimensions: dimensions, numHeads: numHeads)
        ln1 = LayerNorm(dimensions: dimensions)
        ln2 = LayerNorm(dimensions: dimensions)
        fc1 = Linear(dimensions, mlpDimensions)
        fc2 = Linear(mlpDimensions, dimensions)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray) -> MLXArray {
        var h = ln1(x)
        h = attention(h, keys: h, values: h, mask: mask)
        let afterAttention = x + h
        h = ln2(afterAttention)
        h = fc1(h)
        h = activation(h)
        h = fc2(h)
        return afterAttention + h
    }
}

/// A genuine decoder-only transformer with randomly initialized weights —
/// not a fine-tune of any pretrained model. Token + learned positional
/// embeddings feed `numLayers` causal `TinyBlock`s, a final `LayerNorm`, and
/// an output projection tied to the token embedding (`Embedding.asLinear`).
public final class TinyTransformerLM: Module {
    @ModuleInfo var tokenEmbedding: Embedding
    @ModuleInfo var positionEmbedding: Embedding
    let blocks: [TinyBlock]
    @ModuleInfo var normFinal: LayerNorm

    public let config: TinyLMConfig

    public init(config: TinyLMConfig) {
        self.config = config
        tokenEmbedding = Embedding(embeddingCount: config.vocabSize, dimensions: config.dimensions)
        positionEmbedding = Embedding(embeddingCount: config.contextLength, dimensions: config.dimensions)
        blocks = (0 ..< config.numLayers).map { _ in
            TinyBlock(dimensions: config.dimensions, numHeads: config.numHeads, mlpDimensions: config.mlpDimensions)
        }
        normFinal = LayerNorm(dimensions: config.dimensions)
    }

    public func callAsFunction(_ tokens: MLXArray) -> MLXArray {
        let sequenceLength = tokens.dim(1)
        let positions = MLXArray(Array(0 ..< sequenceLength))
        var x = tokenEmbedding(tokens) + positionEmbedding(positions)
        let mask = MultiHeadAttention.createAdditiveCausalMask(sequenceLength, dtype: x.dtype)
        for block in blocks {
            x = block(x, mask: mask)
        }
        x = normFinal(x)
        return tokenEmbedding.asLinear(x)
    }
}

public struct SmallLMPretrainingJob: Sendable {
    public let corpusText: String
    public let contextLength: Int
    public let dimensions: Int
    public let numHeads: Int
    public let numLayers: Int
    public let mlpDimensions: Int
    public let iterations: Int
    public let learningRate: Float
    public let batchSize: Int
    public let outputName: String

    public init(
        corpusText: String,
        contextLength: Int = 64,
        dimensions: Int = 128,
        numHeads: Int = 4,
        numLayers: Int = 4,
        mlpDimensions: Int = 512,
        iterations: Int = 500,
        learningRate: Float = 3e-3,
        batchSize: Int = 32,
        outputName: String
    ) {
        self.corpusText = corpusText
        self.contextLength = contextLength
        self.dimensions = dimensions
        self.numHeads = numHeads
        self.numLayers = numLayers
        self.mlpDimensions = mlpDimensions
        self.iterations = iterations
        self.learningRate = learningRate
        self.batchSize = batchSize
        self.outputName = outputName
    }
}

public struct SmallLMPretrainingResult: Sendable {
    public let relativePath: String
    public let vocabSize: Int
    public let finalLoss: Float?
    public let metrics: [MetricPoint]
}

public enum SmallLMError: LocalizedError {
    case unavailable(reason: String)
    case corpusTooShort(minimumCharacters: Int)
    case invalidConfiguration(String)
    case emptyPrompt
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .corpusTooShort(let minimum):
            "This corpus is too short for the chosen context length — add more text (at least \(minimum) characters)."
        case .invalidConfiguration(let detail):
            "Invalid small language model configuration: \(detail)"
        case .emptyPrompt: "Prompt contains no characters seen during training."
        case .cancelled: "Training was cancelled."
        }
    }
}

/// Trains a compact transformer language model with randomly initialized
/// weights end to end — real forward/backward passes via
/// `MLXNN.valueAndGrad`, a real `Adam` optimizer step per iteration, and a
/// real character-level vocabulary built from the supplied corpus. This is
/// architecturally distinct from `MLXFineTuningProvider`, which only adapts
/// an already-pretrained model's weights via LoRA: here there is no base
/// model at all, and the resulting weights are saved as a plain
/// `.safetensors` file (not a HuggingFace-compatible repo), loadable only by
/// `generate(modelDirectory:prompt:)` below.
///
/// Honest caveat: this exercises the same MLX compute path
/// (`eval`/`asyncEval` on the model's arrays) that this app's own testing
/// found intermittently crashes on this machine's beta OS — see
/// CAPABILITIES.md.
public struct SmallLMPretrainingProvider: Sendable {
    public let name = "Small Language Model (From Scratch)"

    public init() {}

    public func capability() -> CapabilityStatus {
        CapabilityDetector.detectMLX().status
    }

    public func pretrain(
        job: SmallLMPretrainingJob, onProgress: @escaping @Sendable (TrainingProgress) -> Void
    ) async throws -> SmallLMPretrainingResult {
        try Self.validate(job: job)
        guard capability().isAvailable else {
            throw SmallLMError.unavailable(reason: capability().reason ?? "MLX unavailable.")
        }
        let minimumCharacters = job.contextLength * 4
        guard job.corpusText.count >= minimumCharacters else {
            throw SmallLMError.corpusTooShort(minimumCharacters: minimumCharacters)
        }
        try Task.checkCancellation()

        onProgress(TrainingProgress(
            phase: .preparingData,
            message: "Building character vocabulary from \(job.corpusText.count) characters of corpus"
        ))
        let tokenizer = CharTokenizer(corpus: job.corpusText)
        let tokenIDs = tokenizer.encode(job.corpusText)
        guard tokenIDs.count > job.contextLength + 1 else {
            throw SmallLMError.corpusTooShort(minimumCharacters: minimumCharacters)
        }

        let config = TinyLMConfig(
            vocabSize: tokenizer.vocabSize,
            contextLength: job.contextLength,
            dimensions: job.dimensions,
            numHeads: job.numHeads,
            numLayers: job.numLayers,
            mlpDimensions: job.mlpDimensions
        )

        let outputDirectory = LibraryPaths.models.appendingPathComponent(job.outputName, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        onProgress(TrainingProgress(
            phase: .training,
            message: "Training a \(job.numLayers)-layer, \(job.dimensions)-dim transformer from randomly initialized weights, vocab size \(tokenizer.vocabSize)"
        ))

        let model = TinyTransformerLM(config: config)
        eval(model.parameters())

        let lossFunction: (TinyTransformerLM, MLXArray, MLXArray) -> MLXArray = { model, x, y in
            crossEntropy(logits: model(x), targets: y, reduction: .mean)
        }
        let lg = valueAndGrad(model: model, lossFunction)
        let optimizer = Adam(learningRate: job.learningRate)

        var lastLoss: Float?
        var metrics: [MetricPoint] = []
        let reportEvery = max(1, job.iterations / 20)

        for iteration in 1 ... job.iterations {
            if Task.isCancelled { throw SmallLMError.cancelled }

            let (xBatch, yBatch) = Self.sampleBatch(
                tokenIDs: tokenIDs, contextLength: job.contextLength, batchSize: job.batchSize
            )
            let (loss, grads) = lg(model, xBatch, yBatch)
            optimizer.update(model: model, gradients: grads)
            eval(model.parameters(), optimizer)

            let lossValue = loss.item(Float.self)
            lastLoss = lossValue
            if iteration % reportEvery == 0 || iteration == job.iterations {
                onProgress(TrainingProgress(
                    phase: .training,
                    message: "iteration \(iteration)/\(job.iterations): loss \(String(format: "%.4f", lossValue))"
                ))
                metrics.append(MetricPoint(name: "trainingLoss", value: Double(lossValue)))
            }
        }

        if Task.isCancelled { throw SmallLMError.cancelled }

        onProgress(TrainingProgress(phase: .savingArtifact, message: "Saving weights, config, and vocabulary"))
        let flatParameters = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
        try MLX.save(arrays: flatParameters, url: outputDirectory.appendingPathComponent("weights.safetensors"))
        try JSONEncoder().encode(config).write(to: outputDirectory.appendingPathComponent("config.json"))
        try JSONEncoder().encode(tokenizer).write(to: outputDirectory.appendingPathComponent("vocab.json"))

        onProgress(TrainingProgress(phase: .done, message: "Done"))
        if let lastLoss { metrics.append(MetricPoint(name: "finalTrainingLoss", value: Double(lastLoss))) }

        return SmallLMPretrainingResult(
            relativePath: job.outputName,
            vocabSize: tokenizer.vocabSize,
            finalLoss: lastLoss,
            metrics: metrics
        )
    }

    /// Validate parameters before constructing MLX layers. MLX modules assume
    /// these constraints and otherwise tend to fail with low-level shape errors.
    public static func validate(job: SmallLMPretrainingJob) throws {
        guard job.contextLength >= 2 else {
            throw SmallLMError.invalidConfiguration("context length must be at least 2")
        }
        guard job.dimensions > 0, job.numHeads > 0, job.numLayers > 0, job.mlpDimensions > 0 else {
            throw SmallLMError.invalidConfiguration("dimensions, heads, layers, and MLP dimensions must all be positive")
        }
        guard job.dimensions % job.numHeads == 0 else {
            throw SmallLMError.invalidConfiguration("dimensions (\(job.dimensions)) must be divisible by attention heads (\(job.numHeads))")
        }
        guard job.iterations > 0, job.batchSize > 0 else {
            throw SmallLMError.invalidConfiguration("iterations and batch size must both be at least 1")
        }
        guard job.learningRate.isFinite, job.learningRate > 0 else {
            throw SmallLMError.invalidConfiguration("learning rate must be a finite positive number")
        }
    }

    /// Autoregressive generation from a trained-from-scratch model directory
    /// (`config.json` + `vocab.json` + `weights.safetensors`).
    ///
    /// - Parameters:
    ///   - temperature: `0` (the default) means greedy argmax decoding —
    ///     deterministic, no randomness involved. Any value `> 0` divides
    ///     the logits by this before sampling from the real categorical
    ///     distribution (`MLXRandom.categorical`), so higher values flatten
    ///     the distribution toward more random choices.
    ///   - topK: `0` (the default) considers the full vocabulary. Any value
    ///     `> 0` restricts sampling to the `topK` highest-logit tokens at
    ///     each step (masking the rest to `-infinity` before sampling),
    ///     which keeps temperature sampling from wandering into very
    ///     unlikely tokens. Only meaningful when `temperature > 0`.
    public func generate(
        modelDirectory: URL, prompt: String, maxNewTokens: Int = 200,
        temperature: Float = 0, topK: Int = 0
    ) throws -> String {
        let config = try JSONDecoder().decode(
            TinyLMConfig.self, from: Data(contentsOf: modelDirectory.appendingPathComponent("config.json")))
        let tokenizer = try JSONDecoder().decode(
            CharTokenizer.self, from: Data(contentsOf: modelDirectory.appendingPathComponent("vocab.json")))

        let model = TinyTransformerLM(config: config)
        let flat = try MLX.loadArrays(url: modelDirectory.appendingPathComponent("weights.safetensors"))
        model.update(parameters: ModuleParameters.unflattened(flat))
        eval(model.parameters())

        var tokens = tokenizer.encode(prompt)
        guard !tokens.isEmpty else { throw SmallLMError.emptyPrompt }
        let promptLength = tokens.count

        for _ in 0 ..< maxNewTokens {
            let context = Array(tokens.suffix(config.contextLength))
            let input = MLXArray(context, [1, context.count])
            let logits = model(input)
            let lastStepLogits = logits[0, context.count - 1]

            let nextToken: Int
            if temperature > 0 {
                var scaled = lastStepLogits / temperature
                if topK > 0 && topK < config.vocabSize {
                    let threshold = sorted(scaled)[config.vocabSize - topK]
                    scaled = which(scaled .>= threshold, scaled, MLXArray(-Float.infinity))
                }
                nextToken = MLXRandom.categorical(scaled).item(Int.self)
            } else {
                nextToken = lastStepLogits.argMax().item(Int.self)
            }
            tokens.append(nextToken)
        }

        return tokenizer.decode(Array(tokens.dropFirst(promptLength)))
    }

    private static func sampleBatch(
        tokenIDs: [Int], contextLength: Int, batchSize: Int
    ) -> (MLXArray, MLXArray) {
        let maxStart = tokenIDs.count - contextLength - 1
        var xFlat: [Int] = []
        var yFlat: [Int] = []
        xFlat.reserveCapacity(batchSize * contextLength)
        yFlat.reserveCapacity(batchSize * contextLength)
        for _ in 0 ..< batchSize {
            let start = Int.random(in: 0 ... max(0, maxStart))
            for offset in 0 ..< contextLength {
                xFlat.append(tokenIDs[start + offset])
                yFlat.append(tokenIDs[start + offset + 1])
            }
        }
        let x = MLXArray(xFlat, [batchSize, contextLength])
        let y = MLXArray(yFlat, [batchSize, contextLength])
        return (x, y)
    }
}

/// Runs a locally trained `TinyTransformerLM` artifact in the same chat
/// contract as the other Playground backends. The model is intentionally
/// compact, so one complete response is yielded after the local inference
/// pass rather than pretending it streams token by token. `temperature`/
/// `topK` are forwarded to `SmallLMPretrainingProvider.generate` — leave
/// `temperature` at `0` for deterministic greedy decoding.
public struct TinyLMInferenceProvider: InferenceProvider {
    public let name = "Trained Small LM (local)"
    private let modelDirectory: URL
    private let temperature: Float
    private let topK: Int

    public init(modelDirectory: URL, temperature: Float = 0, topK: Int = 0) {
        self.modelDirectory = modelDirectory
        self.temperature = temperature
        self.topK = topK
    }

    public func capability() -> CapabilityStatus {
        CapabilityDetector.detectMLX().status
    }

    public func streamRespond(prompt: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let modelDirectory = modelDirectory
        let temperature = temperature
        let topK = topK
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let status = CapabilityDetector.detectMLX().status
                    guard status.isAvailable else {
                        throw InferenceError.unavailable(reason: status.reason ?? "MLX unavailable.")
                    }
                    let response = try SmallLMPretrainingProvider().generate(
                        modelDirectory: modelDirectory,
                        prompt: prompt,
                        temperature: temperature,
                        topK: topK
                    )
                    if !response.isEmpty {
                        continuation.yield(response)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
