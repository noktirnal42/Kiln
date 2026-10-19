import Foundation
import SwiftData

@MainActor
public struct DemoDataStore {
    private let context: ModelContext
    private let importer = DatasetImporter()

    public init(context: ModelContext) {
        self.context = context
    }

    public func createSentimentDemo() throws -> (dataset: DatasetRecord, experiment: ExperimentRecord) {
        let fileName = "demo-sentiment.csv"
        let destination = LibraryPaths.datasets.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: LibraryPaths.datasets, withIntermediateDirectories: true)
        try Self.sentimentCSV.write(to: destination, atomically: true, encoding: .utf8)

        let preview = try importer.preview(at: destination)
        let dataset = DatasetRecord(
            id: "demo-sentiment-\(UUID().uuidString)",
            name: "Demo Sentiment",
            datasetDescription: "Small built-in text classification dataset for verifying Create ML training.",
            sourceKind: .localImport,
            license: "Synthetic demo data",
            tags: ["demo", "text-classification"],
            sizeBytes: try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64,
            localRelativePath: fileName,
            format: .csv,
            downloadStatus: .completed,
            columns: preview.columns,
            rowCount: preview.rowCount,
            trainSplitFraction: 0.8
        )

        let experiment = ExperimentRecord(
            name: "Demo Sentiment Classifier",
            notes: "Created by the one-click demo flow.",
            task: .textClassification,
            datasetID: dataset.id,
            textColumn: "text",
            labelColumn: "label",
            hyperparameters: ["validationFraction": "0.2", "source": "built-in-demo"]
        )

        context.insert(dataset)
        context.insert(experiment)
        try context.save()
        return (dataset, experiment)
    }

    private static let sentimentCSV = """
text,label
"I loved the thoughtful pacing and warm ending.",positive
"The interface feels fast and polished.",positive
"This result is exactly what I needed.",positive
"The model answer was clear and useful.",positive
"Setup was smooth and the output made sense.",positive
"The feature saved me a lot of time.",positive
"I would happily use this again.",positive
"The experience felt reliable and calm.",positive
"The app crashed and lost my work.",negative
"The prediction was confusing and wrong.",negative
"The download failed without a helpful message.",negative
"The tool felt slow and unreliable.",negative
"The labels were mixed up and unhelpful.",negative
"I could not finish the workflow.",negative
"The output missed the point completely.",negative
"The training run ended with an error.",negative
"""
}
