import Foundation
import CoreML

/// Runs an arbitrary imported or locally trained `.mlmodel`/`.mlpackage`.
/// This provider is used both for the classification models this app trains
/// itself (single-shot prediction, not chat) and for generic imported Core
/// ML models where we can introspect the input/output feature descriptions
/// at runtime instead of assuming a fixed schema.
public struct CoreMLClassificationProvider: Sendable {
    public init() {}

    public func capability() -> CapabilityStatus {
        .available
    }

    /// Loads the model fresh per call. Model Lab's classification jobs are
    /// interactive spot-checks, not a high-throughput serving path, so the
    /// simplicity of not managing a cache outweighs the reload cost.
    public func classify(modelURL: URL, text: String) throws -> [(label: String, confidence: Double)] {
        let model = try MLModel(contentsOf: compiledURL(for: modelURL))
        guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first(where: {
            model.modelDescription.inputDescriptionsByName[$0]?.type == .string
        }) else {
            throw InferenceError.invalidInput("Model has no String input feature.")
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: text])
        let output = try model.prediction(from: provider)
        return try rankedPredictions(from: output)
    }

    /// Classifies a photo against an image-classification `.mlmodel`/
    /// `.mlpackage`, e.g. one trained by `CreateMLTrainingProvider`'s
    /// `.imageClassification` path. The model's own `MLImageConstraint`
    /// (expected pixel size/format) drives the resize, so callers don't
    /// need to pre-process the image themselves.
    public func classifyImage(modelURL: URL, imageURL: URL) throws -> [(label: String, confidence: Double)] {
        let model = try MLModel(contentsOf: compiledURL(for: modelURL))
        guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first(where: {
            model.modelDescription.inputDescriptionsByName[$0]?.type == .image
        }), let constraint = model.modelDescription.inputDescriptionsByName[inputName]?.imageConstraint else {
            throw InferenceError.invalidInput("Model has no Image input feature.")
        }
        let featureValue = try MLFeatureValue(imageAt: imageURL, constraint: constraint, options: nil)
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: featureValue])
        let output = try model.prediction(from: provider)
        return try rankedPredictions(from: output)
    }

    private func rankedPredictions(from output: MLFeatureProvider) throws -> [(label: String, confidence: Double)] {
        guard let labelName = output.featureNames.first(where: { output.featureValue(for: $0)?.type == .string }),
              let label = output.featureValue(for: labelName)?.stringValue else {
            throw InferenceError.invalidInput("Model produced no String label output.")
        }

        if let probsName = output.featureNames.first(where: { output.featureValue(for: $0)?.type == .dictionary }),
           let probs = output.featureValue(for: probsName)?.dictionaryValue as? [String: NSNumber] {
            return probs.map { (label: $0.key, confidence: $0.value.doubleValue) }
                .sorted { $0.confidence > $1.confidence }
        }
        return [(label: label, confidence: 1.0)]
    }

    /// Compiles a `.mlmodel` to `.mlmodelc` on first use (CoreML requires a
    /// compiled model to load); `.mlpackage` bundles load directly.
    private func compiledURL(for url: URL) throws -> URL {
        guard url.pathExtension == "mlmodel" else { return url }
        let compiledPath = url.deletingPathExtension().appendingPathExtension("mlmodelc")
        if FileManager.default.fileExists(atPath: compiledPath.path) {
            return compiledPath
        }
        let compiled = try MLModel.compileModel(at: url)
        try? FileManager.default.removeItem(at: compiledPath)
        try FileManager.default.copyItem(at: compiled, to: compiledPath)
        return compiledPath
    }
}
