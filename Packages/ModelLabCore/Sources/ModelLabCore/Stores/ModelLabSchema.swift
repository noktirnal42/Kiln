import Foundation
import SwiftData

/// The single SwiftData container backing Model Lab's structured metadata
/// (dataset records, model artifact records, experiment records). Actual
/// dataset/model bytes never live in SwiftData — only paths into
/// `LibraryPaths` do.
public enum ModelLabSchema {
    public static func makeContainer() throws -> ModelContainer {
        let schema = Schema([DatasetRecord.self, ModelArtifactRecord.self, ExperimentRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: LibraryPaths.storeFile)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
