import Foundation
#if canImport(Metal)
import Metal
#endif
import FoundationModels

/// One capabilities row. Unverified capabilities remain explicitly not checked.
public struct CapabilityReport: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let status: CapabilityStatus
    public let detail: String
    public init(name: String, status: CapabilityStatus, detail: String) {
        self.name = name; self.status = status; self.detail = detail
    }
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
            status: .notChecked,
            detail: "MLX is linked; generation requires a compatible installed model and a successful run."
        )
    }

    public static func detectNetwork() -> CapabilityReport {
        CapabilityReport(
            name: "Hugging Face catalog",
            status: .notChecked,
            detail: "Not checked here. Datasets and Playground report network errors when a request is made."
        )
    }

    /// Checks the actual model catalog endpoint, without downloading model artifacts.
    public static func checkNetwork(session: URLSession = .shared) async -> CapabilityReport {
        let name = "Hugging Face catalog"
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/models?limit=1")!)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return CapabilityReport(name: name, status: .unavailable(reason: "Catalog request returned HTTP \(code)."), detail: "")
            }
            guard (try? JSONSerialization.jsonObject(with: data)) is [Any] else {
                return CapabilityReport(name: name, status: .unavailable(reason: "Catalog returned an unexpected response."), detail: "")
            }
            return CapabilityReport(name: name, status: .available, detail: "The public model catalog responded. Other services may have different connectivity.")
        } catch {
            return CapabilityReport(name: name, status: .unavailable(reason: "Catalog request failed: \(error.localizedDescription)"), detail: "")
        }
    }
}
