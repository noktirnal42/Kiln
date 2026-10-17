# SuperMetaApp — AI/ML Model Laboratory Module Specification

## Overview

The **Model Lab Module** provides a complete AI/ML model laboratory for creating, training, fine-tuning, distilling, evaluating, and deploying models. It integrates Apple's native frameworks (CoreML, CreateML, FoundationModels), MLX Swift, and Hugging Face ecosystem into a unified environment.

---

## Module Identity

```json
{
  "identifier": "com.supermeta.modellab",
  "displayName": "AI/ML Model Lab",
  "version": "1.0.0",
  "category": "ai",
  "icon": "brain.head.profile.fill",
  "requiredCapabilities": [
    "fileSystem.readWrite",
    "process.spawn",
    "network.client",
    "metalCompute",
    "neuralEngine"
  ],
  "provides": [
    "modelRegistry",
    "training",
    "fineTuning",
    "distillation",
    "inference",
    "evaluation",
    "deployment",
    "datasetManagement",
    "benchmarking",
    "modelConversion"
  ]
}
```

---

## Architecture

```
ModelLabModule/
├── Module.swift
├── ModelRegistry/
│   ├── ModelRegistryView.swift
│   ├── UnifiedModelStore.swift
│   ├── ModelCatalog.swift
│   ├── ModelImporter.swift
│   ├── ModelExporter.swift
│   ├── VersionManager.swift
│   └── MetadataManager.swift
├── Training/
│   ├── TrainingDashboard.swift
│   ├── CreateMLProvider.swift
│   │   ├── TextClassifierTrainer.swift
│   │   ├── TabularClassifierTrainer.swift
│   │   ├── ImageClassifierTrainer.swift
│   │   ├── RecommenderTrainer.swift
│   │   ├── SoundClassifierTrainer.swift
│   │   ├── ActivityClassifierTrainer.swift
│   │   └── ObjectDetectorTrainer.swift
│   ├── MLXFineTuningProvider.swift
│   │   ├── LoRATrainer.swift
│   │   ├── QLoRATrainer.swift
│   │   ├── FullFineTuner.swift
│   │   ├── AdapterManager.swift
│   │   └── TrainingMonitor.swift
│   ├── DistillationProvider.swift
│   │   ├── SyntheticDataGenerator.swift
│   │   ├── TeacherModelManager.swift
│   │   ├── StudentTrainer.swift
│   │   └── DistillationPipeline.swift
│   ├── FromScratchProvider.swift
│   │   ├── CharLevelLMBuilder.swift
│   │   ├── TokenizerTrainer.swift
│   │   ├── ArchitectureDesigner.swift
│   │   └── ScratchTrainer.swift
│   ├── ReinforcementProvider.swift
│   │   ├── RLHFProvider.swift
│   │   ├── DPOTrainer.swift
│   │   ├── GRPOTrainer.swift
│   │   └── RewardModelTrainer.swift
│   ├── DatasetManager.swift
│   ├── HyperparameterTuner.swift
│   └── ExperimentTracker.swift
├── Inference/
│   ├── InferencePlayground.swift
│   ├── MLXInferenceProvider.swift
│   ├── CoreMLInferenceProvider.swift
│   ├── AppleFoundationProvider.swift
│   ├── GGUFInferenceProvider.swift
│   ├── ONNXInferenceProvider.swift
│   ├── InferenceEngine.swift
│   ├── KVCacheManager.swift
│   ├── StreamingManager.swift
│   └── BatchProcessor.swift
├── Evaluation/
│   ├── EvaluationDashboard.swift
│   ├── AutoPromptEngine.swift
│   ├── MetricCalculator.swift
│   │   ├── PerplexityCalculator.swift
│   │   ├── AccuracyCalculator.swift
│   │   ├── F1Calculator.swift
│   │   ├── BLEUCalculator.swift
│   │   ├── ROUGECalculator.swift
│   │   └── CustomMetricCalculator.swift
│   ├── ComparisonDashboard.swift
│   ├── RedTeamHarness.swift
│   ├── BiasDetector.swift
│   ├── SafetyEvaluator.swift
│   └── BenchmarkRunner.swift
├── Deployment/
│   ├── DeploymentManager.swift
│   ├── CoreMLExporter.swift
│   ├── ONNXExporter.swift
│   ├── GGUFExporter.swift
│   ├── MLXPackageExporter.swift
│   ├── TensorRTExporter.swift
│   ├── ModelOptimizer.swift
│   │   ├── Quantizer.swift
│   │   ├── Pruner.swift
│   │   ├── Distiller.swift
│   │   └── Compiler.swift
│   ├── ANECompiler.swift
│   └── MetalShaderGenerator.swift
├── Data/
│   ├── DatasetImporter.swift
│   ├── HuggingFaceDatasetProvider.swift
│   ├── DatasetViewer.swift
│   ├── DataAugmentation.swift
│   ├── TokenizerManager.swift
│   ├── DataSplitter.swift
│   └── PreprocessingPipeline.swift
└── Playground/
    ├── ModelPlaygroundView.swift
    ├── ChatInterface.swift
    ├── CompletionInterface.swift
    ├── EmbeddingInterface.swift
    ├── ImageGenerationInterface.swift
    └── AudioInterface.swift
```

---

## Model Registry

### Unified Model Store

```swift
final class UnifiedModelStore: Sendable {
    // Resolves cache location per Axiom RE pattern:
    // AXIOM_MODELS_DIR → HF_HUB_CACHE → HF_HOME/hub → ~/.cache/huggingface/hub
    
    let cacheRoot: URL
    
    func scanInstalledModels() async -> [InstalledModel] {
        // Walk models--org--repo/snapshots/<rev> layout
    }
    
    func registerModel(_ model: ModelDescriptor) async throws
    func unregisterModel(_ identifier: String) async throws
    func getModel(_ identifier: String) async -> ModelDescriptor?
    func listModels(filter: ModelFilter?) async -> [ModelDescriptor]
    func downloadModel(_ identifier: String, progress: @escaping (Double) -> Void) async throws
    func deleteModel(_ identifier: String) async throws
    func verifyIntegrity(_ identifier: String) async -> VerificationResult
}

struct ModelDescriptor: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let source: ModelSource
    let architecture: ModelArchitecture
    let parameters: ParameterCount
    let quantization: Quantization?
    let contextWindow: Int
    let capabilities: ModelCapabilities
    let license: String
    let localPath: URL?
    let remoteURL: URL?
    let checksum: String?
    let metadata: ModelMetadata
}

enum ModelSource: String, Codable, Sendable {
    case huggingFace, local, mlxCommunity, appleFoundation, custom
}

enum ModelArchitecture: String, Codable, Sendable {
    case llama, mistral, gemma, qwen, phi, falcon, mpt, gpt
    case bert, roberta, deberta, electra
    case vit, clip, siglip
    case whisper, wav2vec, hubert
    case stableDiffusion, flux, sdxl
    case custom(String)
}

struct ModelCapabilities: OptionSet, Codable, Sendable {
    let rawValue: UInt32
    static let textGeneration = ModelCapabilities(rawValue: 1 << 0)
    static let chat = ModelCapabilities(rawValue: 1 << 1)
    static let completion = ModelCapabilities(rawValue: 1 << 2)
    static let embedding = ModelCapabilities(rawValue: 1 << 3)
    static let vision = ModelCapabilities(rawValue: 1 << 4)
    static let audio = ModelCapabilities(rawValue: 1 << 5)
    static let toolCalling = ModelCapabilities(rawValue: 1 << 6)
    static let reasoning = ModelCapabilities(rawValue: 1 << 7)
    static let onDevice = ModelCapabilities(rawValue: 1 << 8)
}
```

### Universal Model Store Integration

```swift
// Shared with Axiom RE, AppleHarness, and other modules
final class UniversalModelStoreManager: Sendable {
    static let shared = UniversalModelStoreManager()
    
    private let store: UnifiedModelStore
    
    func adoptModel(from sourceURL: URL, to destination: ModelDescriptor) async throws
    func shareModel(_ identifier: String, with modules: [String]) async
    func syncAcrossModules() async
}
```

---

## Training Providers

### CreateML Provider (Native Apple)

```swift
final class CreateMLProvider: TrainingProvider {
    func trainTextClassifier(
        dataset: Dataset,
        configuration: TextClassifierConfig
    ) async throws -> TrainingJob {
        let trainer = try MLTextClassifier(
            trainingData: dataset.toMLDataTable(),
            textColumn: configuration.textColumn,
            labelColumn: configuration.labelColumn
        )
        
        let job = TrainingJob(
            id: UUID(),
            type: .textClassification,
            provider: .createML,
            model: trainer.model
        )
        
        // Train with progress reporting
        try await trainer.train { progress in
            job.updateProgress(progress)
        }
        
        // Export to CoreML
        let mlmodel = try trainer.writeModel(to: job.outputURL)
        
        return job.withResult(mlmodel)
    }
    
    func trainTabularClassifier(
        dataset: Dataset,
        configuration: TabularClassifierConfig
    ) async throws -> TrainingJob { ... }
    
    func trainImageClassifier(
        dataset: Dataset,
        configuration: ImageClassifierConfig
    ) async throws -> TrainingJob { ... }
    
    func trainRecommender(
        dataset: Dataset,
        configuration: RecommenderConfig
    ) async throws -> TrainingJob { ... }
}

struct TrainingJob: Identifiable, Sendable {
    let id: UUID
    let type: TrainingType
    let provider: TrainingProviderType
    var status: JobStatus
    var progress: Double
    var metrics: TrainingMetrics
    var model: MLModel?
    var outputURL: URL?
    var logs: [LogEntry]
}
```

### MLX Fine-Tuning Provider

```swift
final class MLXFineTuningProvider: TrainingProvider {
    func trainLoRA(
        baseModel: ModelDescriptor,
        dataset: Dataset,
        configuration: LoRAConfig
    ) async throws -> TrainingJob {
        // 1. Load base model
        let modelContainer = try await MLXModelContainer.load(baseModel)
        
        // 2. Create LoRA adapter
        let loraConfig = LoRAConfiguration(
            rank: configuration.rank,
            alpha: configuration.alpha,
            dropout: configuration.dropout,
            targetModules: configuration.targetModules
        )
        
        let adapter = try LoRAContainer.from(model: modelContainer.model, configuration: loraConfig)
        
        // 3. Prepare dataset
        let trainData = try dataset.toMLXTrainingData()
        
        // 4. Train
        let job = TrainingJob(
            id: UUID(),
            type: .loraFineTuning,
            provider: .mlx,
            model: adapter
        )
        
        try await LoRATrain.train(
            model: modelContainer.model,
            adapter: adapter,
            data: trainData,
            optimizer: configuration.optimizer,
            learningRate: configuration.learningRate,
            batchSize: configuration.batchSize,
            epochs: configuration.epochs,
            progressHandler: { progress in
                job.updateProgress(progress)
            }
        )
        
        // 5. Save adapter
        try LoRATrain.saveLoRAWeights(adapter, to: job.outputURL)
        
        return job.withResult(adapter)
    }
    
    func trainQLoRA(
        baseModel: ModelDescriptor,
        dataset: Dataset,
        configuration: QLoRAConfig
    ) async throws -> TrainingJob { ... }
    
    func trainFull(
        baseModel: ModelDescriptor,
        dataset: Dataset,
        configuration: FullFineTuneConfig
    ) async throws -> TrainingJob { ... }
}
```

### Distillation Provider

```swift
final class DistillationProvider: TrainingProvider {
    func distill(
        teacher: ModelDescriptor,
        student: ModelDescriptor,
        seedPrompts: [String],
        configuration: DistillationConfig
    ) async throws -> TrainingJob {
        // 1. Generate synthetic dataset
        let generator = SyntheticDataGenerator(teacher: teacher)
        let syntheticDataset = try await generator.generate(
            prompts: seedPrompts,
            samplesPerPrompt: configuration.samplesPerPrompt,
            temperature: configuration.temperature
        )
        
        // 2. Save as training data
        let datasetURL = try await syntheticDataset.saveAsJSONL()
        
        // 3. Fine-tune student on synthetic data
        let fineTuneConfig = LoRAConfig(
            rank: configuration.studentLoRARank,
            alpha: configuration.studentLoRAAlpha,
            targetModules: configuration.studentTargetModules
        )
        
        return try await MLXFineTuningProvider.shared.trainLoRA(
            baseModel: student,
            dataset: syntheticDataset,
            configuration: fineTuneConfig
        )
    }
}
```

### From-Scratch Provider

```swift
final class FromScratchProvider: TrainingProvider {
    func trainCharLevelLM(
        corpus: Dataset,
        configuration: CharLMConfig
    ) async throws -> TrainingJob {
        // 1. Build vocabulary
        let vocab = try VocabularyBuilder.build(from: corpus, config: configuration.vocabConfig)
        
        // 2. Create model architecture
        let model = try CharLevelTransformer(configuration: configuration.modelConfig)
        
        // 3. Train
        let job = TrainingJob(...)
        
        let optimizer = Adam(learningRate: configuration.learningRate)
        let lossFn = CrossEntropyLoss()
        
        for epoch in 0..<configuration.epochs {
            for batch in corpus.batches(batchSize: configuration.batchSize) {
                let (loss, grads) = MLX.valueAndGrad(model: model) { model in
                    let logits = model(batch.input)
                    return lossFn(logits, batch.target)
                }
                
                optimizer.update(model, grads: grads)
                job.updateProgress(epoch, loss: loss.item())
            }
        }
        
        // 4. Save artifacts
        let artifacts = FromScratchArtifacts(
            weights: model.parameters,
            config: model.config,
            vocab: vocab
        )
        
        try artifacts.save(to: job.outputURL)
        
        return job.withResult(artifacts)
    }
}
```

---

## Inference Providers

### Unified Inference Engine

```swift
protocol InferenceProvider: Sendable {
    var supportedModels: [ModelArchitecture] { get }
    var capabilities: ProviderCapabilities { get }
    
    func loadModel(_ model: ModelDescriptor) async throws -> LoadedModel
    func unloadModel(_ model: LoadedModel) async
    
    func generate(
        _ request: GenerationRequest,
        model: LoadedModel
    ) async throws -> AsyncThrowingStream<GenerationChunk, Error>
    
    func embed(
        _ texts: [String],
        model: LoadedModel
    ) async throws -> [[Float]]
    
    func benchmark(_ model: LoadedModel) async -> BenchmarkResult
}

struct GenerationRequest: Sendable {
    let prompt: String
    let maxTokens: Int
    let temperature: Double
    let topP: Double
    let topK: Int
    let stopSequences: [String]
    let stream: Bool
    let reasoningConfig: ReasoningConfig?
}

struct GenerationChunk: Sendable {
    let text: String
    let tokenID: Int
    let logprob: Double?
    let isComplete: Bool
    let usage: TokenUsage?
}
```

### MLX Inference Provider

```swift
final class MLXInferenceProvider: InferenceProvider {
    var loadedModels: [String: MLXLoadedModel] = [:]
    
    func loadModel(_ model: ModelDescriptor) async throws -> MLXLoadedModel {
        // Apply MLX compile cache workaround
        MLX.compile(enable: false)
        
        let container = try await MLXModelContainer.load(model)
        let session = MLXLMCommon.ChatSession(model: container.model, tokenizer: container.tokenizer)
        
        let loaded = MLXLoadedModel(
            id: UUID().uuidString,
            model: model,
            container: container,
            session: session
        )
        
        loadedModels[loaded.id] = loaded
        return loaded
    }
    
    func generate(
        _ request: GenerationRequest,
        model: LoadedModel
    ) async throws -> AsyncThrowingStream<GenerationChunk, Error> {
        let mlxModel = model as! MLXLoadedModel
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let stream = mlxModel.session.streamResponse(to: request.prompt)
                    for try await chunk in stream {
                        continuation.yield(GenerationChunk(
                            text: chunk.text,
                            tokenID: chunk.tokenID,
                            logprob: chunk.logprob,
                            isComplete: false
                        ))
                    }
                    continuation.yield(GenerationChunk(text: "", tokenID: 0, isComplete: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
```

### Apple Foundation Models Provider

```swift
final class AppleFoundationProvider: InferenceProvider {
    func loadModel(_ model: ModelDescriptor) async throws -> FoundationLoadedModel {
        let availability = SystemLanguageModel.default.availability
        guard availability == .available else {
            throw InferenceError.modelUnavailable(availability)
        }
        
        let session = LanguageModelSession()
        return FoundationLoadedModel(session: session, model: model)
    }
    
    func generate(
        _ request: GenerationRequest,
        model: LoadedModel
    ) async throws -> AsyncThrowingStream<GenerationChunk, Error> {
        let fmModel = model as! FoundationLoadedModel
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let options = GenerationOptions(
                        temperature: request.temperature,
                        topP: request.topP,
                        maximumResponseTokens: request.maxTokens
                    )
                    
                    let stream = fmModel.session.streamResponse(
                        to: request.prompt,
                        options: options
                    )
                    
                    for try await chunk in stream {
                        continuation.yield(GenerationChunk(
                            text: chunk,
                            tokenID: 0,
                            isComplete: false
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
```

---

## Evaluation System

### Auto Prompt Engine

```swift
final class AutoPromptEngine: Sendable {
    func generatePrompts(
        for task: EvaluationTask,
        count: Int,
        constraints: PromptConstraints
    ) async -> [String] {
        var prompts: [String] = []
        
        // Template-based generation
        prompts.append(contentsOf: generateFromTemplates(task, count: count/2))
        
        // Mutation-based generation
        prompts.append(contentsOf: await mutatePrompts(task.seedPrompts, count: count/4))
        
        // LLM-based generation (using ModelRegistry)
        if let provider = await ModelRegistry.shared.resolveBestProvider(for: .promptGeneration) {
            prompts.append(contentsOf: await generateWithLLM(provider, task, count: count/4))
        }
        
        return Array(Set(prompts)).prefix(count).map { $0 }
    }
    
    func optimizePrompt(
        initial: String,
        evaluator: PromptEvaluator,
        iterations: Int
    ) async -> String {
        var best = initial
        var bestScore = await evaluator.evaluate(best)
        
        for _ in 0..<iterations {
            let candidates = generateVariants(best, count: 8)
            for candidate in candidates {
                let score = await evaluator.evaluate(candidate)
                if score > bestScore {
                    best = candidate
                    bestScore = score
                }
            }
        }
        
        return best
    }
}
```

### Metric Calculator

```swift
protocol MetricCalculator: Sendable {
    func calculate(predictions: [String], references: [String]) async -> MetricResult
}

final class PerplexityCalculator: MetricCalculator {
    func calculate(predictions: [String], references: [String]) async -> MetricResult {
        // Use model to compute perplexity
    }
}

final class BLEUCalculator: MetricCalculator {
    func calculate(predictions: [String], references: [String]) async -> MetricResult {
        // n-gram BLEU
    }
}

final class ROUGECalculator: MetricCalculator {
    func calculate(predictions: [String], references: [String]) async -> MetricResult {
        // ROUGE-1, ROUGE-2, ROUGE-L
    }
}

final class CustomMetricCalculator: MetricCalculator {
    let metric: CustomMetric
    
    func calculate(predictions: [String], references: [String]) async -> MetricResult {
        // Execute custom metric code
    }
}
```

### Red Team Harness

```swift
final class RedTeamHarness: Sendable {
    let attackSuites: [AttackSuite] = [
        JailbreakSuite(),
        PromptInjectionSuite(),
        DataExtractionSuite(),
        HarmfulContentSuite(),
        BiasSuite(),
        PIIExtractionSuite()
    ]
    
    func runAssessment(
        on model: ModelDescriptor,
        suites: [AttackSuite]? = nil
    ) async -> RedTeamReport {
        let targetSuites = suites ?? attackSuites
        var results: [AttackResult] = []
        
        for suite in targetSuites {
            let result = await suite.execute(on: model)
            results.append(result)
        }
        
        return RedTeamReport(
            model: model,
            timestamp: Date(),
            results: results,
            overallScore: calculateOverallScore(results)
        )
    }
}

struct AttackSuite: Sendable {
    let name: String
    let category: AttackCategory
    let prompts: [AttackPrompt]
    func execute(on model: ModelDescriptor) async -> AttackResult
}

enum AttackCategory: String, Sendable {
    case jailbreak, promptInjection, dataExtraction, harmfulContent
    case bias, piiExtraction, hallucination, adversarial
}
```

---

## Deployment & Optimization

### Model Optimizer

```swift
final class ModelOptimizer: Sendable {
    func quantize(
        model: ModelDescriptor,
        config: QuantizationConfig
    ) async throws -> ModelDescriptor {
        switch config.method {
        case .gptq:
            return try await GPTQQuantizer.quantize(model, config: config)
        case .awq:
            return try await AWQQuantizer.quantize(model, config: config)
        case .rtn:
            return try await RTNQuantizer.quantize(model, config: config)
        case .mlx:
            return try await MLXQuantizer.quantize(model, config: config)
        case .coreml:
            return try await CoreMLQuantizer.quantize(model, config: config)
        }
    }
    
    func prune(
        model: ModelDescriptor,
        config: PruningConfig
    ) async throws -> ModelDescriptor { ... }
    
    func distill(
        teacher: ModelDescriptor,
        student: ModelDescriptor,
        config: DistillationConfig
    ) async throws -> ModelDescriptor { ... }
    
    func compileForANE(
        model: ModelDescriptor
    ) async throws -> ModelDescriptor {
        // CoreML → ANE compilation
    }
    
    func compileForMetal(
        model: ModelDescriptor
    ) async throws -> ModelDescriptor {
        // MLX → Metal shader compilation
    }
}
```

### Exporters

```swift
protocol ModelExporter: Sendable {
    func export(
        model: ModelDescriptor,
        to url: URL,
        config: ExportConfig
    ) async throws
}

final class CoreMLExporter: ModelExporter {
    func export(model: ModelDescriptor, to url: URL, config: ExportConfig) async throws {
        // Convert to MLModel via coremltools or MLX → CoreML
    }
}

final class ONNXExporter: ModelExporter {
    func export(model: ModelDescriptor, to url: URL, config: ExportConfig) async throws {
        // Convert via torch.export or MLX → ONNX
    }
}

final class GGUFExporter: ModelExporter {
    func export(model: ModelDescriptor, to url: URL, config: ExportConfig) async throws {
        // Convert to GGUF format for llama.cpp
    }
}

final class MLXPackageExporter: ModelExporter {
    func export(model: ModelDescriptor, to url: URL, config: ExportConfig) async throws {
        // Create .mlx package with weights, config, tokenizer
    }
}
```

---

## Dataset Management

### Dataset Importer

```swift
final class DatasetImporter: Sendable {
    func importFromHuggingFace(
        repo: String,
        split: String?,
        config: ImportConfig
    ) async throws -> Dataset {
        let provider = HuggingFaceDatasetProvider()
        return try await provider.download(repo: repo, split: split)
    }
    
    func importFromFile(
        url: URL,
        format: DatasetFormat
    ) async throws -> Dataset { ... }
    
    func importFromDirectory(
        url: URL,
        structure: DirectoryStructure
    ) async throws -> Dataset { ... }
}

struct Dataset: Identifiable, Sendable {
    let id: UUID
    let name: String
    let format: DatasetFormat
    let splits: [String: DatasetSplit]
    let features: DatasetFeatures
    let statistics: DatasetStatistics
    let localPath: URL
}

enum DatasetFormat: String, Codable, Sendable {
    case json, jsonl, csv, parquet, arrow, text, huggingface
}
```

---

## Playground Interface

### Unified Playground

```swift
struct ModelPlaygroundView: View {
    @State var selectedModel: ModelDescriptor?
    @State var mode: PlaygroundMode = .chat
    @State var reasoningConfig: ReasoningConfig = .default
    
    var body: some View {
        NavigationSplitView {
            ModelSelector(selectedModel: $selectedModel)
        } detail: {
            switch mode {
            case .chat:
                ChatInterface(model: selectedModel, reasoning: reasoningConfig)
            case .completion:
                CompletionInterface(model: selectedModel)
            case .embedding:
                EmbeddingInterface(model: selectedModel)
            case .image:
                ImageGenerationInterface(model: selectedModel)
            case .audio:
                AudioInterface(model: selectedModel)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ReasoningPanel(config: $reasoningConfig)
            }
        }
    }
}

enum PlaygroundMode: String, CaseIterable, Sendable {
    case chat, completion, embedding, image, audio
}
```

---

## Integration with SuperMetaApp

### Cross-Module Workflows

```
┌─────────────────┐     ┌─────────────────┐
│  ModelLab       │────▶│  AgenticConsole │
│  (Create Model) │     │  (Use Model)    │
└─────────────────┘     └─────────────────┘
        │                       │
        ▼                       ▼
┌─────────────────────────────────────────┐
│           Shared Model Registry          │
│  • Universal Model Store                │
│  • Model Metadata                       │
│  • Version History                      │
└─────────────────────────────────────────┘
        │
        ▼
┌─────────────────┐     ┌─────────────────┐
│  DevPlatform    │────▶│  ReverseEng     │
│  (Deploy Model) │     │  (Analyze Model)│
└─────────────────┘     └─────────────────┘
```

### Shared Services Used

| Service | Usage |
|---------|-------|
| ModelRegistry | Central model catalog, provider resolution |
| UniversalModelStore | Shared model cache across modules |
| MCPClient | External training/inference services |
| WorkspaceManager | Dataset storage, experiment tracking |
| TerminalService | Training process management |
| GitService | Experiment versioning |
| SettingsService | Provider configs, hardware preferences |
| KeychainService | API keys, HF tokens |

---

## Hardware Awareness

```swift
final class HardwareProfile: Sendable {
    let chip: ChipType
    let memoryGB: Int
    let hasNeuralEngine: Bool
    let metalTier: MetalTier
    
    func canRun(model: ModelDescriptor) -> CompatibilityResult {
        let requiredMemory = estimateMemoryRequirement(model)
        let availableMemory = memoryGB * 1024 * 1024 * 1024
        
        return CompatibilityResult(
            canRun: requiredMemory <= availableMemory,
            requiredMemory: requiredMemory,
            availableMemory: availableMemory,
            recommendedQuantization: recommendQuantization(availableMemory),
            estimatedSpeed: estimateTokensPerSecond(model),
            warnings: generateWarnings(model)
        )
    }
}
```

---

## Performance Targets

| Operation | Target |
|-----------|--------|
| Model Load (7B 4-bit) | < 5s |
| First Token (local) | < 500ms |
| Token Throughput (M3 Pro) | > 30 tok/s |
| LoRA Train (1B, 1k samples) | < 60s |
| Distillation (8 samples) | < 30s |
| Quantization (7B) | < 120s |
| Export CoreML | < 30s |
| Memory (inference) | Model size + 2GB |
| Memory (training) | Model size + 8GB |

---

## Document Version

- **Version**: 1.0
- **Date**: 2026-10-15
- **Status**: Draft for Review