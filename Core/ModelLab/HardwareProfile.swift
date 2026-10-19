import Foundation
#if canImport(Metal)
import Metal
#endif

/// Memory-aware model compatibility for this host. Everything here is
/// measured live (sysctl/ProcessInfo/Metal) — never cached and never
/// assumed — per the Model Lab rule that hardware claims are
/// environment-sensitive and must be surfaced fresh.
public struct HardwareProfile: Sendable, Equatable {
    public let isAppleSilicon: Bool
    public let memoryGB: Int
    public let coreCount: Int
    public let metalDeviceName: String?

    /// Fraction of unified memory the OS will realistically let one process
    /// use before heavy swapping or jetsam. 18 GB hosts (this project's
    /// reference machine) behave badly past ~70%, so MLX/CoreML loads are
    /// warned well before the raw capacity.
    public static let recommendedMaxMemoryFraction: Double = 0.7

    public init(
        isAppleSilicon: Bool,
        memoryGB: Int,
        coreCount: Int,
        metalDeviceName: String?
    ) {
        self.isAppleSilicon = isAppleSilicon
        self.memoryGB = memoryGB
        self.coreCount = coreCount
        self.metalDeviceName = metalDeviceName
    }

    /// Live probe of the actual host.
    public static func current() -> HardwareProfile {
        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0)
        let processInfo = ProcessInfo.processInfo
        let memoryGB = Int((Double(processInfo.physicalMemory) / 1_073_741_824).rounded())
        var metalName: String?
        #if canImport(Metal)
        if let device = MTLCreateSystemDefaultDevice() {
            metalName = device.name
        }
        #endif
        return HardwareProfile(
            isAppleSilicon: arm == 1,
            memoryGB: memoryGB,
            coreCount: processInfo.activeProcessorCount,
            metalDeviceName: metalName
        )
    }

    /// Bytes of unified memory a single ML workload should stay under on this
    /// host.
    public var recommendedWorkingLimitBytes: Int64 {
        Int64((Double(memoryGB) * 1_073_741_824) * Self.recommendedMaxMemoryFraction)
    }

    public enum Verdict: Equatable, Sendable {
        case fits
        case tight(overheadBytes: Int64)
        case doesNotFit(shortBytes: Int64)

        public var isFits: Bool {
            if case .fits = self { return true }
            return false
        }
    }

    /// Judge whether a model whose weights occupy `weightBytes` can be
    /// loaded here. Inference needs weights + a working-set allowance
    /// (KV cache, activations); training needs a much larger one.
    public func canLoad(weightsBytes: Int64, forTraining: Bool) -> Verdict {
        let overheadBytes: Int64 = forTraining ? 8 * 1_073_741_824 : 2 * 1_073_741_824
        let required = weightsBytes + overheadBytes
        let limit = recommendedWorkingLimitBytes
        if required <= limit {
            return .fits
        }
        if weightsBytes <= limit {
            return .tight(overheadBytes: required - limit)
        }
        return .doesNotFit(shortBytes: weightsBytes - limit)
    }

    /// The quantization level that typically brings `parameterCount`
    /// parameters under this host's working limit, from the sizes actually
    /// observed in mlx-community repos. Returns nil when even 4-bit is out
    /// of reach.
    public func recommendedQuantization(parameterCount: Double) -> QuantizationAdvice? {
        // bytes-per-parameter by quant: 4-bit ~0.55 (weights + scales), 8-bit ~1.1, 16-bit ~2.05
        let fourBit = Int64(parameterCount * 0.55)
        let eightBit = Int64(parameterCount * 1.1)
        let sixteenBit = Int64(parameterCount * 2.05)
        let limit = recommendedWorkingLimitBytes
        if fourBit <= limit { return .fourBit }
        if eightBit <= limit { return .eightBit }
        if sixteenBit <= limit { return .sixteenBit }
        return nil
    }

    /// Human-readable warnings for a concrete model size, or nil when the
    /// load is comfortable. Each string names the actual numbers so the UI
    /// never says just "may be slow".
    public func warnings(weightsBytes: Int64, forTraining: Bool) -> [String] {
        var result: [String] = []
        if !isAppleSilicon {
            result.append("MLX and on-device Apple Intelligence require Apple silicon; this host is Intel.")
        }
        if metalDeviceName == nil {
            result.append("No Metal-capable GPU found; MLX cannot run.")
        }
        switch canLoad(weightsBytes: weightsBytes, forTraining: forTraining) {
        case .fits:
            break
        case .tight(let overheadBytes):
            let needed = Self.formatBytes(overheadBytes)
            result.append("Tight fit: this load needs about \(needed) more than the recommended \(Int(recommendedWorkingLimitBytes / 1_073_741_824)) GB working limit on a \(memoryGB) GB host. Expect swapping and degraded throughput.")
        case .doesNotFit(let shortBytes):
            let short = Self.formatBytes(shortBytes)
            result.append("Does not fit: weights alone exceed this host's \(Int(recommendedWorkingLimitBytes / 1_073_741_824)) GB recommended working limit by \(short) on a \(memoryGB) GB host. Use a smaller or more aggressively quantized model.")
        }
        if forTraining && memoryGB < 24 {
            result.append("Training on a \(memoryGB) GB unified-memory host: keep batch sizes small and prefer LoRA over full fine-tuning.")
        }
        return result
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

public enum QuantizationAdvice: String, Sendable {
    case fourBit = "4-bit"
    case eightBit = "8-bit"
    case sixteenBit = "16-bit"

    public var bytesPerParameter: Double {
        switch self {
        case .fourBit: 0.55
        case .eightBit: 1.1
        case .sixteenBit: 2.05
        }
    }
}
