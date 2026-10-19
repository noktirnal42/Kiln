import Foundation
import ModelLabCore

/// Prompt 5 item 11 — artifact export. Every path here either performs a
/// real copy/conversion or reports the SPECIFIC reason it cannot (per
/// AILab CAPABILITIES.md: no fake capabilities). GGUF conversion needs
/// llama.cpp tooling the app does not bundle; the availability probe names
/// exactly what is missing when it is.
public struct ModelExporters: Sendable {
    public enum ExportFormat: String, Sendable, CaseIterable, Identifiable {
        case coreML
        case mlxPackage
        case gguf

        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .coreML: "Core ML (.mlmodel / .mlpackage)"
            case .mlxPackage: "MLX Package (directory)"
            case .gguf: "GGUF (llama.cpp)"
            }
        }
    }

    public enum ExportError: LocalizedError, Equatable {
        case sourceMissing(String)
        case unsupportedFormat(model: String, format: ExportFormat)
        case conversionUnavailable(reason: String)
        case destinationWriteFailed(String)
        case emptySource

        public var errorDescription: String? {
            switch self {
            case .sourceMissing(let path): "Source artifact is missing on disk: \(path)"
            case .unsupportedFormat(let model, let format): "\(model) cannot be exported as \(format.displayName) — no real conversion path exists."
            case .conversionUnavailable(let reason): reason
            case .destinationWriteFailed(let detail): "Writing to the destination failed: \(detail)"
            case .emptySource: "Nothing to export: the artifact has no local files."
            }
        }
    }

    public init() {}

    // MARK: - Availability probes (honest, checked live)

    /// Core ML export is a real copy for artifacts that are ALREADY Core ML
    /// (Create ML training output, imported .mlmodel/.mlpackage). Converting
    /// MLX weights to Core ML needs coremltools on a Python the app can
    /// reach, which a sandboxed app cannot assume — that path reports
    /// unavailable rather than pretending.
    public func coreMLCapability(for record: ModelArtifactRecord, absoluteURL: URL?) -> CapabilityStatus {
        guard record.format == .mlmodel || record.format == .mlpackage else {
            return .unavailable(reason: "\(record.format.displayName) → Core ML conversion requires coremltools (Python) reachable from the app; the sandboxed app cannot run an unbundled Python toolchain, so this path is disabled rather than faked.")
        }
        guard let url = absoluteURL, FileManager.default.fileExists(atPath: url.path) else {
            return .unavailable(reason: "The artifact's local file is missing on disk — re-run the training or re-import the model.")
        }
        return .available
    }

    public func mlxPackageCapability(for record: ModelArtifactRecord, absoluteURL: URL?) -> CapabilityStatus {
        switch record.format {
        case .mlxScratchModel, .mlxFolder, .mlxLoraAdapter:
            guard let url = absoluteURL, FileManager.default.fileExists(atPath: url.path) else {
                return .unavailable(reason: "The artifact's local directory is missing on disk.")
            }
            return .available
        case .mlxHubRepository:
            return .unavailable(reason: "Hub-repository models are cached by MLX outside the app's library; export it as an MLX package after a local run, or download the repo files directly from Hugging Face.")
        default:
            return .unavailable(reason: "\(record.format.displayName) is not an MLX artifact.")
        }
    }

    /// GGUF export requires llama.cpp's HF→GGUF converter. The probe looks
    /// for the converter script/binary in the usual locations; if none is
    /// found the reason says exactly that (and that ONNX export is the
    /// planned later path, per the roadmap).
    public static func ggufCapability() -> CapabilityStatus {
        let candidates = [
            "/opt/homebrew/bin/convert_hf_to_gguf.py",
            "/usr/local/bin/convert_hf_to_gguf.py",
            "/opt/homebrew/bin/llama-convert-hf-to-gguf",
            "/usr/local/bin/llama-convert-hf-to-gguf",
        ]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let converter = found else {
            return .unavailable(reason: "GGUF export needs llama.cpp's convert_hf_to_gguf tool, which is not installed in the standard locations (/opt/homebrew/bin, /usr/local/bin). Install llama.cpp and retry — the app will not fabricate a GGUF file. (ONNX export is the planned later alternative.)")
        }
        // Even when the converter exists, a sandboxed app cannot spawn
        // processes that read outside its container, so the honest answer is
        // still unavailable from inside the sandbox.
        return .unavailable(reason: "Found \(converter), but the app runs inside the macOS App Sandbox: a spawned converter process cannot read the model files it would need. Run llama.cpp's converter directly in Terminal instead — the app will not fabricate a GGUF file.")
    }

    // MARK: - Export

    public func export(
        record: ModelArtifactRecord,
        absoluteURL: URL?,
        format: ExportFormat,
        to destination: URL
    ) throws -> URL {
        switch format {
        case .coreML:
            return try exportCoreML(record: record, absoluteURL: absoluteURL, to: destination)
        case .mlxPackage:
            return try exportMLXPackage(record: record, absoluteURL: absoluteURL, to: destination)
        case .gguf:
            throw ExportError.conversionUnavailable(reason: Self.ggufAvailabilityReason)
        }
    }

    static var ggufAvailabilityReason: String {
        Self.ggufCapability().reason ?? "GGUF conversion is unavailable."
    }

    private func exportCoreML(record: ModelArtifactRecord, absoluteURL: URL?, to destination: URL) throws -> URL {
        guard record.format == .mlmodel || record.format == .mlpackage else {
            throw ExportError.unsupportedFormat(model: record.format.displayName, format: .coreML)
        }
        guard let source = absoluteURL, FileManager.default.fileExists(atPath: source.path) else {
            throw ExportError.sourceMissing(record.localRelativePath)
        }
        return try copyItem(source: source, to: destination)
    }

    /// Bundles an MLX artifact directory (trained small LM, LoRA adapter, or
    /// MLX model folder) into a self-describing package: the artifact files
    /// plus a `modellab-package.json` manifest recording what was exported,
    /// when, and from which experiment.
    private func exportMLXPackage(record: ModelArtifactRecord, absoluteURL: URL?, to destination: URL) throws -> URL {
        switch record.format {
        case .mlxScratchModel, .mlxFolder, .mlxLoraAdapter:
            break
        case .mlxHubRepository:
            throw ExportError.unsupportedFormat(model: record.format.displayName, format: .mlxPackage)
        default:
            throw ExportError.unsupportedFormat(model: record.format.displayName, format: .mlxPackage)
        }
        guard let source = absoluteURL, FileManager.default.fileExists(atPath: source.path) else {
            throw ExportError.sourceMissing(record.localRelativePath)
        }
        let packageURL = try copyItem(source: source, to: destination)
        let manifest = MLXPackageManifest(
            packageVersion: 1,
            artifactName: record.name,
            artifactFormat: record.format.rawValue,
            experimentID: record.experimentID,
            exportedAt: Date(),
            sourceModule: "com.supermeta.modellab"
        )
        let manifestData = try JSONEncoder.prettyEncoder.encode(manifest)
        do {
            try manifestData.write(to: packageURL.appendingPathComponent("modellab-package.json"), options: [.atomic])
        } catch {
            throw ExportError.destinationWriteFailed(error.localizedDescription)
        }
        return packageURL
    }

    private func copyItem(source: URL, to destination: URL) throws -> URL {
        let baseName = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var target = destination.appendingPathComponent(source.lastPathComponent)
        // Never overwrite: a collision gets a numbered suffix.
        if FileManager.default.fileExists(atPath: target.path) {
            for attempt in 1...99 {
                let candidateName = ext.isEmpty ? "\(baseName)-\(attempt)" : "\(baseName)-\(attempt).\(ext)"
                let candidate = destination.appendingPathComponent(candidateName)
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    target = candidate
                    break
                }
            }
        }
        do {
            try FileManager.default.copyItem(at: source, to: target)
            return target
        } catch {
            throw ExportError.destinationWriteFailed(error.localizedDescription)
        }
    }
}

public struct MLXPackageManifest: Codable, Sendable {
    public let packageVersion: Int
    public let artifactName: String
    public let artifactFormat: String
    public let experimentID: String?
    public let exportedAt: Date
    public let sourceModule: String
}

extension JSONEncoder {
    static var prettyEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
