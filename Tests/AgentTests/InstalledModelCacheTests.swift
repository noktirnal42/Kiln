import Foundation
import Testing
@testable import Kiln

struct InstalledModelCacheTests {
    @Test func scanResultIsReusedUntilForcedOrTheRootChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-hub-\(UUID().uuidString)", isDirectory: true)
        let snapshot = root.appendingPathComponent("models--org--tiny/snapshots/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try #"{"architectures":["LlamaForCausalLM"]}"#.write(to: snapshot.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "w".write(to: snapshot.appendingPathComponent("model.safetensors"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = UniversalModelStore(root: root)
        #expect(await store.installedOffPool().count == 1)

        try FileManager.default.removeItem(at: snapshot.appendingPathComponent("model.safetensors"))
        #expect(await store.installedOffPool().count == 1)               // cached; nested change is invisible to the root stamp
        #expect(await store.installedOffPool(forceRefresh: true).isEmpty) // an explicit reload sees it
    }
}
