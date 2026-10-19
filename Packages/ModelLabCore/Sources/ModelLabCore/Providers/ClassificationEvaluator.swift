import Foundation

public struct ConfusionMatrixCell: Identifiable, Sendable, Hashable {
    public var id: String { "\(actual)|\(predicted)" }
    public let actual: String
    public let predicted: String
    public let count: Int
}

public struct ClassificationEvaluationResult: Sendable {
    public let sampleCount: Int
    public let correctCount: Int
    public let accuracy: Double
    public let labels: [String]
    public let confusionMatrix: [ConfusionMatrixCell]
    public let samplePredictions: [ClassificationSamplePrediction]
}

public struct ClassificationSamplePrediction: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let input: String
    public let actual: String
    public let predicted: String
    public let confidence: Double
}

public struct ClassificationEvaluator: Sendable {
    private let importer = DatasetImporter()
    private let classifier = CoreMLClassificationProvider()

    public init() {}

    public func evaluate(
        modelURL: URL,
        datasetURL: URL,
        textColumn: String,
        labelColumn: String,
        maxRows: Int = 200
    ) throws -> ClassificationEvaluationResult {
        let table = try importer.table(at: datasetURL)
        let rows = table.rows.prefix(maxRows).filter {
            ($0[textColumn]?.isEmpty == false) && ($0[labelColumn]?.isEmpty == false)
        }

        var predictions: [ClassificationSamplePrediction] = []
        var counts: [String: [String: Int]] = [:]
        var labels = Set<String>()
        var correct = 0

        for row in rows {
            guard let input = row[textColumn], let actual = row[labelColumn] else { continue }
            let ranked = try classifier.classify(modelURL: modelURL, text: input)
            let predicted = ranked.first?.label ?? ""
            let confidence = ranked.first?.confidence ?? 0
            if predicted == actual { correct += 1 }
            labels.insert(actual)
            labels.insert(predicted)
            counts[actual, default: [:]][predicted, default: 0] += 1
            if predictions.count < 30 {
                predictions.append(ClassificationSamplePrediction(
                    input: input,
                    actual: actual,
                    predicted: predicted,
                    confidence: confidence
                ))
            }
        }

        let sortedLabels = labels.sorted()
        let matrix = sortedLabels.flatMap { actual in
            sortedLabels.map { predicted in
                ConfusionMatrixCell(
                    actual: actual,
                    predicted: predicted,
                    count: counts[actual]?[predicted] ?? 0
                )
            }
        }
        let sampleCount = rows.count
        return ClassificationEvaluationResult(
            sampleCount: sampleCount,
            correctCount: correct,
            accuracy: sampleCount == 0 ? 0 : Double(correct) / Double(sampleCount),
            labels: sortedLabels,
            confusionMatrix: matrix,
            samplePredictions: predictions
        )
    }
}
