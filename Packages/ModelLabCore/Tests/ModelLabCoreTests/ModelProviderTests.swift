import Foundation
import Testing
@testable import ModelLabCore

struct ModelProviderTests {
    @Test func detectsLikelyMLXCompatibleModelDetails() throws {
        let details = ModelDetails(
            id: "mlx-community/example",
            name: "mlx-community/example",
            downloads: 10,
            likes: 2,
            pipelineTag: "text-generation",
            libraryName: "mlx",
            license: "apache-2.0",
            tags: ["mlx", "safetensors"],
            files: [
                ModelFileInfo(path: "config.json", sizeBytes: 100, downloadURL: URL(string: "https://example.com/config.json")!),
                ModelFileInfo(path: "tokenizer.json", sizeBytes: 100, downloadURL: URL(string: "https://example.com/tokenizer.json")!),
                ModelFileInfo(path: "model.safetensors", sizeBytes: 100, downloadURL: URL(string: "https://example.com/model.safetensors")!)
            ],
            sourceURL: URL(string: "https://huggingface.co/mlx-community/example")!
        )

        #expect(details.isLikelyMLXCompatible)
    }

    @Test func listsAndDeletesModelCacheEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repo = root.appendingPathComponent("models--mlx-community--Example")
        let snapshot = repo.appendingPathComponent("snapshots/main")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try "weights".write(to: snapshot.appendingPathComponent("model.safetensors"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ModelCacheStore(cacheRoot: root)
        let entries = try store.listModelCaches()
        #expect(entries.count == 1)
        #expect(entries[0].repoID == "mlx-community/Example")
        #expect(entries[0].snapshotCount == 1)

        try store.deleteCache(repoID: "mlx-community/Example")
        #expect(try store.listModelCaches().isEmpty)
    }
}
