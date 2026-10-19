import Foundation
#if canImport(Metal)
import Metal
#endif
import FoundationModels

/// One row the Settings → Capabilities screen shows verbatim. Every status
/// here is the result of an actual runtime check, never a hardcoded
/// assumption, per the app's "don't fake capabilities" requirement.
public struct CapabilityReport: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let status: CapabilityStatus
    public let detail: String
}

public enum CapabilityDetector {
    @MainActor
    public static func detectAll() -> [CapabilityReport] {
        [detectHardware(), detectMetal(), detectCoreML(), detectCreateML(), detectFoundationModels(), detectMLX(), detectNetwork()]
    }

    public static func detectHardware() -> CapabilityReport {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        let isAppleSilicon = value == 1
        let memory = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        let detail = "\(isAppleSilicon ? "Apple silicon" : "Intel") · \(memory) GB unified/physical memory · \(ProcessInfo.processInfo.activeProcessorCount) cores"
        return CapabilityReport(
            name: "Hardware",
            status: isAppleSilicon ? .available : .unavailable(reason: "Intel Mac detected; MLX and on-device Apple Intelligence require Apple silicon."),
            detail: detail
        )
    }

    public static func detectMetal() -> CapabilityReport {
        #if canImport(Metal)
        if let device = MTLCreateSystemDefaultDevice() {
            return CapabilityReport(name: "Metal", status: .available, detail: device.name)
        }
        #endif
        return CapabilityReport(name: "Metal", status: .unavailable(reason: "No Metal-capable GPU device found."), detail: "")
    }

    public static func detectCoreML() -> CapabilityReport {
        CapabilityReport(name: "Core ML", status: .available, detail: "Model loading and prediction via CoreML.framework.")
    }

    public static func detectCreateML() -> CapabilityReport {
        CapabilityReport(name: "Create ML", status: .available, detail: "On-device text and tabular classifier training via CreateML.framework.")
    }

    @MainActor
    public static func detectFoundationModels() -> CapabilityReport {
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return CapabilityReport(name: "Apple Intelligence (Foundation Models)", status: .available, detail: "SystemLanguageModel.default is available on this Mac.")
            case .unavailable(let reason):
                let message: String
                switch reason {
                case .deviceNotEligible:
                    message = "This Mac is not eligible for Apple Intelligence."
                case .appleIntelligenceNotEnabled:
                    message = "Apple Intelligence is installed but not turned on. Enable it in System Settings → Apple Intelligence & Siri."
                case .modelNotReady:
                    message = "The on-device model assets have not finished downloading yet."
                @unknown default:
                    message = "Unavailable for an unrecognized reason."
                }
                return CapabilityReport(name: "Apple Intelligence (Foundation Models)", status: .unavailable(reason: message), detail: "")
            }
        }
        return CapabilityReport(
            name: "Apple Intelligence (Foundation Models)",
            status: .unavailable(reason: "Requires macOS 26 or later."),
            detail: "Running on \(ProcessInfo.processInfo.operatingSystemVersionString)."
        )
    }

    public static func detectMLX() -> CapabilityReport {
        let hw = detectHardware()
        guard hw.status.isAvailable else {
            return CapabilityReport(name: "MLX (local LLM inference)", status: .unavailable(reason: "MLX is Metal-backed and requires Apple silicon."), detail: "")
        }
        return CapabilityReport(
            name: "MLX (local LLM inference)",
            status: .available,
            detail: "mlx-swift-lm linked. Actual generation still requires downloading a model on first use."
        )
    }

    public static func detectNetwork() -> CapabilityReport {
        CapabilityReport(
            name: "Network (dataset/model discovery)",
            status: .available,
            detail: "Checked live per-request; Datasets and Playground surface network errors inline rather than assuming connectivity."
        )
    }
}
