import Foundation

/// Prompt 5 item 8 — evaluation metrics. Pure, deterministic functions with
/// known-answer test vectors. The `LabMetric` protocol is the extension
/// point for custom metrics (item 8's "custom metric protocol").
public protocol LabMetric: Sendable {
    var name: String { get }
    /// Higher is better unless `lowerIsBetter` says otherwise (perplexity).
    var lowerIsBetter: Bool { get }
    func score(predictions: [String], references: [String]) throws -> Double
}

public struct MetricOutcome: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let metricName: String
    public let value: Double
    public let lowerIsBetter: Bool
    public let sampleCount: Int
    public let calculatedAt: Date

    public init(metricName: String, value: Double, lowerIsBetter: Bool, sampleCount: Int, calculatedAt: Date = Date()) {
        self.id = UUID()
        self.metricName = metricName
        self.value = value
        self.lowerIsBetter = lowerIsBetter
        self.sampleCount = sampleCount
        self.calculatedAt = calculatedAt
    }
}

public enum MetricError: LocalizedError, Equatable {
    case countMismatch(predictions: Int, references: Int)
    case emptyInput

    public var errorDescription: String? {
        switch self {
        case .countMismatch(let p, let r): "predictions (\(p)) and references (\(r)) must have the same count."
        case .emptyInput: "Cannot compute a metric over zero samples."
        }
    }
}

// MARK: - Accuracy / F1 (classification)

public struct AccuracyMetric: LabMetric {
    public let name = "accuracy"
    public let lowerIsBetter = false
    public init() {}

    public func score(predictions: [String], references: [String]) throws -> Double {
        guard !predictions.isEmpty else { throw MetricError.emptyInput }
        guard predictions.count == references.count else { throw MetricError.countMismatch(predictions: predictions.count, references: references.count) }
        let correct = zip(predictions, references).filter { normalize($0) == normalize($1) }.count
        return Double(correct) / Double(predictions.count)
    }

    private func normalize(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Macro-averaged F1 over the labels actually present in the references.
public struct F1Metric: LabMetric {
    public let name = "f1"
    public let lowerIsBetter = false
    public init() {}

    public func score(predictions: [String], references: [String]) throws -> Double {
        guard !predictions.isEmpty else { throw MetricError.emptyInput }
        guard predictions.count == references.count else { throw MetricError.countMismatch(predictions: predictions.count, references: references.count) }
        let labels = Set(references.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var f1Sum: Double = 0
        for label in labels {
            var tp = 0.0, fp = 0.0, fn = 0.0
            for (prediction, reference) in zip(predictions, references) {
                let p = prediction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let r = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if p == label && r == label { tp += 1 }
                if p == label && r != label { fp += 1 }
                if p != label && r == label { fn += 1 }
            }
            let precision = (tp + fp) > 0 ? tp / (tp + fp) : 0
            let recall = (tp + fn) > 0 ? tp / (tp + fn) : 0
            let f1 = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0
            f1Sum += f1
        }
        return f1Sum / Double(labels.count)
    }
}

// MARK: - BLEU

/// Corpus BLEU with brevity penalty over 1–4 gram precision (the standard
/// formulation from Papineni et al., the same shape as NLTK/sacrebleu's
/// single-reference mode). Tokenization is whitespace + punctuation split.
public struct BLEUMetric: LabMetric {
    public let name = "bleu"
    public let lowerIsBetter = false
    public let maxN: Int
    public init(maxN: Int = 4) { self.maxN = maxN }

    public func score(predictions: [String], references: [String]) throws -> Double {
        guard !predictions.isEmpty else { throw MetricError.emptyInput }
        guard predictions.count == references.count else { throw MetricError.countMismatch(predictions: predictions.count, references: references.count) }

        var clippedByN = [Double](repeating: 0, count: maxN)
        var totalByN = [Double](repeating: 0, count: maxN)
        var hypothesisLength = 0
        var referenceLength = 0

        for (prediction, reference) in zip(predictions, references) {
            let hypothesisTokens = Self.tokenize(prediction)
            let referenceTokens = Self.tokenize(reference)
            hypothesisLength += hypothesisTokens.count
            referenceLength += referenceTokens.count
            for n in 1...maxN {
                let hypothesisCounts = Self.ngramCounts(hypothesisTokens, n: n)
                let referenceCounts = Self.ngramCounts(referenceTokens, n: n)
                var clipped = 0
                var total = 0
                for (gram, count) in hypothesisCounts {
                    total += count
                    clipped += min(count, referenceCounts[gram] ?? 0)
                }
                clippedByN[n - 1] += Double(clipped)
                totalByN[n - 1] += Double(total)
            }
        }

        guard hypothesisLength > 0 else { return 0 }

        var logPrecisionSum = 0.0
        for n in 0..<maxN {
            guard totalByN[n] > 0, clippedByN[n] > 0 else { return 0 }
            logPrecisionSum += log(clippedByN[n] / totalByN[n])
        }
        let logAveragePrecision = logPrecisionSum / Double(maxN)

        let brevityPenalty: Double = hypothesisLength >= referenceLength ? 1.0 : exp(1.0 - Double(referenceLength) / Double(hypothesisLength))
        return brevityPenalty * exp(logAveragePrecision)
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { $0.isWhitespace || $0.isNewline || $0.isPunctuation }
            .map(String.init)
    }

    static func ngramCounts(_ tokens: [String], n: Int) -> [String: Int] {
        guard n <= tokens.count else { return [:] }
        var counts: [String: Int] = [:]
        for index in 0...(tokens.count - n) {
            let gram = tokens[index..<(index + n)].joined(separator: " ")
            counts[gram, default: 0] += 1
        }
        return counts
    }
}

// MARK: - ROUGE

public struct ROUGEMetric: LabMetric {
    public let name: String
    public let lowerIsBetter = false
    public let variant: Variant
    public enum Variant: String, Sendable, CaseIterable {
        case rouge1
        case rouge2
        case rougeL
    }

    public init(_ variant: Variant) {
        self.variant = variant
        self.name = variant.rawValue
    }

    public func score(predictions: [String], references: [String]) throws -> Double {
        guard !predictions.isEmpty else { throw MetricError.emptyInput }
        guard predictions.count == references.count else { throw MetricError.countMismatch(predictions: predictions.count, references: references.count) }
        var f1Sum: Double = 0
        for (prediction, reference) in zip(predictions, references) {
            let hypothesisTokens = BLEUMetric.tokenize(prediction)
            let referenceTokens = BLEUMetric.tokenize(reference)
            let recall: Double
            let precision: Double
            switch variant {
            case .rouge1, .rouge2:
                let n = variant == .rouge1 ? 1 : 2
                let hypothesisCounts = BLEUMetric.ngramCounts(hypothesisTokens, n: n)
                let referenceCounts = BLEUMetric.ngramCounts(referenceTokens, n: n)
                let referenceTotal = referenceTokens.count - n + 1
                let hypothesisTotal = hypothesisTokens.count - n + 1
                guard referenceTotal > 0 else { continue }
                if hypothesisTotal <= 0 {
                    f1Sum += 0
                    continue
                }
                var overlapping = 0
                for (gram, count) in hypothesisCounts {
                    overlapping += min(count, referenceCounts[gram] ?? 0)
                }
                recall = Double(overlapping) / Double(referenceTotal)
                precision = Double(overlapping) / Double(hypothesisTotal)
            case .rougeL:
                let common = Self.longestCommonSubsequence(hypothesisTokens, referenceTokens)
                guard !referenceTokens.isEmpty else { continue }
                if hypothesisTokens.isEmpty {
                    f1Sum += 0
                    continue
                }
                recall = Double(common) / Double(referenceTokens.count)
                precision = Double(common) / Double(hypothesisTokens.count)
            }
            let f1 = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0
            f1Sum += f1
        }
        return f1Sum / Double(predictions.count)
    }

    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    table[i][j] = table[i - 1][j - 1] + 1
                } else {
                    table[i][j] = max(table[i - 1][j], table[i][j - 1])
                }
            }
        }
        return table[a.count][b.count]
    }
}

// MARK: - Perplexity

/// Perplexity from per-token negative log-likelihoods (natural log), the
/// standard exp(mean NLL). The provider supplies the NLLs: a CoreML/MLX
/// model's scored tokens, or `Self.nll(fromLogProbabilities:)` when the
/// backend exposes base-e log-probs per token.
public struct PerplexityMetric: LabMetric {
    public let name = "perplexity"
    public let lowerIsBetter = true
    public init() {}

    public func score(predictions: [String], references: [String]) throws -> Double {
        throw MetricError.emptyInput
    }

    public func perplexity(fromNegativeLogLikelihoods nlls: [Double]) throws -> Double {
        guard !nlls.isEmpty else { throw MetricError.emptyInput }
        return exp(nlls.reduce(0, +) / Double(nlls.count))
    }

    public func perplexity(fromLogProbabilities logProbs: [Double]) throws -> Double {
        try perplexity(fromNegativeLogLikelihoods: logProbs.map { -$0 })
    }
}

// MARK: - Evaluation runner

public struct EvaluationRun: Sendable {
    public let id: UUID
    public let modelName: String
    public let outcomes: [MetricOutcome]

    public init(modelName: String, outcomes: [MetricOutcome]) {
        self.id = UUID()
        self.modelName = modelName
        self.outcomes = outcomes
    }
}

public struct EvaluationRunner: Sendable {
    public init() {}

    /// Run every metric over paired predictions/references and collect the
    /// outcomes. A metric that throws (e.g. empty input) aborts the run with
    /// the specific error rather than skipping silently.
    public func evaluate(
        modelName: String,
        predictions: [String],
        references: [String],
        metrics: [any LabMetric]
    ) throws -> EvaluationRun {
        var outcomes: [MetricOutcome] = []
        for metric in metrics {
            let value = try metric.score(predictions: predictions, references: references)
            outcomes.append(MetricOutcome(
                metricName: metric.name,
                value: value,
                lowerIsBetter: metric.lowerIsBetter,
                sampleCount: predictions.count
            ))
        }
        return EvaluationRun(modelName: modelName, outcomes: outcomes)
    }

    /// Perplexity is computed from likelihoods, not strings, so it is added
    /// to a run separately when a backend provides token NLLs.
    public func perplexityOutcome(nlls: [Double]) throws -> MetricOutcome {
        let metric = PerplexityMetric()
        let value = try metric.perplexity(fromNegativeLogLikelihoods: nlls)
        return MetricOutcome(
            metricName: metric.name,
            value: value,
            lowerIsBetter: true,
            sampleCount: nlls.count
        )
    }
}
