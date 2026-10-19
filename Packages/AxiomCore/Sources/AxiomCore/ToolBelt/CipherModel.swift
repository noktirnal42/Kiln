import Foundation

// Cipher classifier (docs/ML_MODELS_PLAN.md §1, v1): a multinomial logistic regression over the
// CipherFeatures vector, classes {aes, chacha20, rc4, blowfish, xor, unknown}. The trained
// artifact is a small JSON file (weights + bias + layout), loaded from the app bundle or a file;
// inference is a single matrix-vector product, deterministic, on-device, sub-millisecond.
// Output is always a ranked hypothesis with confidence — never a conclusion (docs/SPEC.md
// Intelligence section); AutoDecryptor's validator gate stays authoritative regardless.

public struct CipherClassifierModel: Codable, Sendable {
    public var formatVersion = 1
    public var name: String
    public var classes: [String]
    public var layout: FeatureLayout
    /// Weights[class][feature], bias[class] — trained artifact, exported by the training pipeline.
    public var weights: [[Double]]
    public var bias: [Double]
    public var trainingNotes: String

    public init(name: String, classes: [String], layout: FeatureLayout, weights: [[Double]], bias: [Double], trainingNotes: String = "") {
        self.name = name; self.classes = classes; self.layout = layout
        self.weights = weights; self.bias = bias; self.trainingNotes = trainingNotes
    }
}

public struct CipherSuggestion: Sendable, Equatable {
    public let className: String
    public let confidence: Double
}

public enum CipherClassifier {
    public static let bundledModelName = "cipher-classifier-v1"

    /// Loads the model bundled with the app (Resources/cipher-classifier-v1.json), or nil when
    /// absent — callers must treat nil as "no classifier", never guess.
    /// No classifier artifact ships with the ported engine, so this is nil.
    public static func bundled() -> CipherClassifierModel? {
        nil
    }

    public static func load(from url: URL) throws -> CipherClassifierModel {
        let model = try JSONDecoder().decode(CipherClassifierModel.self, from: Data(contentsOf: url))
        try validate(model)
        return model
    }

    static func validate(_ model: CipherClassifierModel) throws {
        guard model.formatVersion == 1 else { throw AxiomError.message("Unsupported classifier artifact version \(model.formatVersion).") }
        guard model.classes.count == model.weights.count, model.classes.count == model.bias.count else {
            throw AxiomError.message("Classifier artifact is inconsistent: \(model.classes.count) classes, \(model.weights.count) weight rows.")
        }
        for row in model.weights where row.count != model.layout.dimension {
            throw AxiomError.message("Classifier weights have \(row.count) features; layout expects \(model.layout.dimension).")
        }
    }

    /// Ranked class probabilities via softmax over the feature vector.
    public static func classify(_ data: Data, model: CipherClassifierModel) -> [CipherSuggestion] {
        let features = FeatureExtractor.extract(data, layout: model.layout)
        let scores = zip(model.weights, model.bias).map { row, bias in
            zip(row, features).reduce(bias) { $0 + $1.0 * $1.1 }
        }
        let peak = scores.max() ?? 0
        let exponentials = scores.map { exp($0 - peak) }   // numerically stable softmax
        let sum = exponentials.reduce(0, +)
        let ranked = zip(model.classes, exponentials).map { CipherSuggestion(className: $0.0, confidence: $0.1 / sum) }
            .sorted { $0.confidence > $1.confidence }
        return ranked
    }

    /// Maps a class name onto the transforms the sweep can actually run. Classes without a
    /// transform yet (none in v1) map to nothing, and the caller must not pretend otherwise.
    public static func ciphers(for className: String) -> [Cipher] {
        switch className {
        case "aes": return [.aes256CBC, .aes128CBC, .aes256ECB, .aes128ECB, .aes256GCM]
        case "chacha20": return [.chacha20Poly1305]
        case "rc4": return [.rc4]
        case "blowfish": return [.blowfish64CBC, .blowfish64ECB]
        case "xor": return [.xor]
        default: return []
        }
    }
}
