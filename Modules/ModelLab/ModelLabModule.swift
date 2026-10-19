import Foundation
import SwiftUI
import Observation
import SwiftData
import ModelLabCore
import MLX

/// The Model Lab module: the verified ModelLabCore engine (ported verbatim
/// from AILab into `Packages/ModelLabCore`) wrapped in Kiln's module
/// system, plus the Prompt 5 additions (hardware profile, evaluation
/// metrics, experiment comparison, auto-prompt engine, red-team harness,
/// exporters) that live in `Core/ModelLab`.
@MainActor
@Observable
public final class ModelLabModule: @preconcurrency Module, @preconcurrency ModuleDefinition, ModuleUI {
    public nonisolated static let identifier = "com.kiln.modellab"
    public nonisolated static let displayName = "Model Lab"
    public nonisolated static let version = "1.0.0"
    public nonisolated static let dependencies: [String] = []
    public nonisolated static let requiredCapabilities: ModuleCapabilities = [
        .fileSystemRead, .fileSystemWrite, .networkClient, .metalCompute, .neuralEngine,
    ]

    // MARK: State

    public private(set) var container: ModelContainer? = nil
    public private(set) var bootstrapError: String? = nil
    public private(set) var hardware = HardwareProfile.current()
    public private(set) var capabilityReports: [CapabilityReport] = []
    public private(set) var seededDemo = false

    // Lazy: the coordinators are @MainActor types, so they cannot be default-
    // initialized inside the module's nonisolated `init()` (required by
    // ModuleDefinition). They are created on first MainActor access instead.
    @ObservationIgnored public private(set) lazy var createMLCoordinator = TrainingCoordinator()
    @ObservationIgnored public private(set) lazy var mlxFineTuningCoordinator = MLXFineTuningCoordinator()
    @ObservationIgnored public private(set) lazy var smallLMCoordinator = SmallLMCoordinator()
    @ObservationIgnored public private(set) lazy var distillationCoordinator = DistillationCoordinator()

    private var context: ModuleContext? = nil

    public nonisolated init() {}

    // MARK: Module lifecycle

    public func initialize(context: ModuleContext) async throws {
        self.context = context
        context.logger.info("Model Lab module initialized")

        // The MLX compile-cache workaround (CAPABILITIES.md): a real segfault
        // in MLX's C++ graph-compilation cache on this machine. Disabling the
        // cache is MLX's documented global switch; runs once per process
        // before any MLX work, so the training paths get the same protection
        // `MLXInferenceProvider` gives inference.
        MLX.compile(enable: false)

        do {
            let container = try ModelLabSchema.makeContainer()
            self.container = container
            let mainContext = container.mainContext
            try ModelLabCore.ModelRegistry(context: mainContext).reconcile()
            seedDemoDataIfNeeded(context: mainContext)
        } catch {
            bootstrapError = "Model Lab store unavailable: \(error.localizedDescription)"
            context.logger.error("\(bootstrapError ?? "")")
        }

        refreshCapabilities()
    }

    public func activate() async throws {
        refreshCapabilities()
        context?.logger.info("Model Lab activated (hardware: \(hardware.metalDeviceName ?? "no Metal") , \(hardware.memoryGB) GB)")
    }

    public func deactivate() async throws {
        context?.logger.info("Model Lab deactivated")
    }

    public func shutdown() async throws {
        context = nil
    }

    // MARK: UI

    public nonisolated func contributeMenus() -> [MenuContribution] {
        [MenuContribution(title: "Model Lab", items: ["New Experiment…", "Import Dataset…"])]
    }

    public nonisolated func contributeCommands() -> [CommandContribution] {
        [
            CommandContribution(identifier: "modellab.newExperiment", title: "New Model Lab Experiment", shortcut: "⌘⇧E", category: "Model Lab"),
            CommandContribution(identifier: "modellab.importDataset", title: "Import Dataset", shortcut: "⌘⇧D", category: "Model Lab"),
        ]
    }

    public func makeRootView() -> AnyView {
        AnyView(ModelLabRootView(module: self))
    }

    // MARK: Capability enforcement

    /// Every engine entry point that maps to a declared capability routes
    /// through here so an ungranted capability fails cleanly with the
    /// capability named (never a silent no-op).
    public func requireCapabilities(_ capabilities: ModuleCapabilities) throws {
        guard let context else { throw ModuleFailure.notLoaded(Self.identifier) }
        try context.requireCapability(capabilities)
    }

    // MARK: Engine access

    public var mainContext: ModelContext? {
        container?.mainContext
    }

    public func refreshCapabilities() {
        capabilityReports = CapabilityDetector.detectAll()
        hardware = HardwareProfile.current()
    }

    /// On first run, seed the built-in sentiment demo so a fresh install has
    /// something real to train without network access or imports.
    public func seedDemoDataIfNeeded(context modelContext: ModelContext) {
        guard !seededDemo else { return }
        let descriptor = FetchDescriptor<DatasetRecord>()
        let datasetCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        if datasetCount == 0 {
            _ = try? DemoDataStore(context: modelContext).createSentimentDemo()
        }
        seededDemo = true
    }

    // MARK: Training entry points

    /// Create ML classifier training (text/tabular/image), the verified
    /// engine path. Dataset import + training write artifacts, so both file
    /// capabilities are required.
    public func startCreateMLTraining(experiment: ExperimentRecord, job: TrainingJob) throws {
        try requireCapabilities([.fileSystemWrite, .neuralEngine])
        guard let mainContext else {
            throw ModelLabModuleError.storeUnavailable(bootstrapError ?? "The Model Lab store failed to open.")
        }
        createMLCoordinator.start(experiment: experiment, job: job, provider: CreateMLTrainingProvider(), context: mainContext)
    }

    /// MLX LoRA fine-tuning (verified engine path; see CAPABILITIES.md for
    /// the machine-sensitivity note — status is live, never cached).
    public func startMLXLoRA(experiment: ExperimentRecord, job: FineTuningJob) throws {
        try requireCapabilities([.fileSystemWrite, .metalCompute])
        guard let mainContext else {
            throw ModelLabModuleError.storeUnavailable(bootstrapError ?? "The Model Lab store failed to open.")
        }
        mlxFineTuningCoordinator.start(experiment: experiment, job: job, provider: MLXFineTuningProvider(), context: mainContext)
    }

    /// From-scratch char-level transformer (verified: 500-iter run,
    /// loss 3.1 → 1.0).
    public func startSmallLMPretraining(experiment: ExperimentRecord, job: SmallLMPretrainingJob) throws {
        try requireCapabilities([.fileSystemWrite, .metalCompute])
        guard let mainContext else {
            throw ModelLabModuleError.storeUnavailable(bootstrapError ?? "The Model Lab store failed to open.")
        }
        smallLMCoordinator.start(experiment: experiment, job: job, provider: SmallLMPretrainingProvider(), context: mainContext)
    }

    /// Automated distillation: teacher generates → jsonl dataset → student
    /// LoRA (verified end-to-end).
    public func startDistillation(experiment: ExperimentRecord, job: DistillationJob) throws {
        try requireCapabilities([.fileSystemWrite, .metalCompute])
        guard let mainContext else {
            throw ModelLabModuleError.storeUnavailable(bootstrapError ?? "The Model Lab store failed to open.")
        }
        distillationCoordinator.start(experiment: experiment, job: job, provider: DistillationProvider(), context: mainContext)
    }

    // MARK: Discovery (network capability gated)

    public func searchHuggingFaceModels(query: String) async throws -> [ModelSearchResult] {
        try requireCapabilities([.networkClient])
        return try await HuggingFaceModelProvider().search(query: query)
    }

    public func searchHuggingFaceDatasets(query: String) async throws -> [DatasetSearchResult] {
        try requireCapabilities([.networkClient])
        return try await HuggingFaceDatasetProvider().search(query: query)
    }

    /// Memory-aware compatibility verdict for a Hugging Face repo, using the
    /// file sizes its API reports. Returns nil when sizes are unknown — the
    /// UI then shows "unknown size" rather than a fabricated verdict.
    public func compatibilityVerdict(for details: ModelDetails, forTraining: Bool) -> HardwareProfile.Verdict? {
        let weightBytes = details.files
            .filter { $0.path.hasSuffix(".safetensors") || $0.path.hasSuffix(".gguf") || $0.path.hasSuffix(".bin") }
            .compactMap(\.sizeBytes)
            .reduce(0, +)
        guard weightBytes > 0 else { return nil }
        return hardware.canLoad(weightsBytes: weightBytes, forTraining: forTraining)
    }
}

public enum ModelLabModuleError: LocalizedError {
    case storeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable(let reason): reason
        }
    }
}
