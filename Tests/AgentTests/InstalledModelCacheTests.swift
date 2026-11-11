import Foundation
import Testing
@testable import Kiln

struct InstalledModelCacheTests {
    @Test func catalogFiltersAndEstimatesFitWithoutTreatingUnknownAsCompatible() {
        let host = HardwareProfile(isAppleSilicon: true, memoryGB: 18, coreCount: 8, metalDeviceName: "Apple GPU")
        func model(_ name: String, _ bytes: UInt64, language: Bool = true) -> InstalledModel {
            InstalledModel(repoID: name, revision: "main", path: "/unused", totalBytes: bytes, isLanguageModel: language)
        }
        let small = model("org/Small", 2_000_000_000)
        let large = model("org/Large", 16_000_000_000)
        let unknown = model("org/Unknown", 0)
        let image = model("org/Image", 100, language: false)
        let all = [large, unknown, small, image]
        #expect(InstalledModelCatalog.fit(small, hardware: host) == .estimatedFit)
        #expect(InstalledModelCatalog.fit(large, hardware: host) == .tooLarge)
        #expect(InstalledModelCatalog.fit(unknown, hardware: host) == .unknown)
        #expect(InstalledModelCatalog.select(all, query: "ORG", fitsOnly: true, sort: .name, hardware: host) == [small])
        #expect(InstalledModelCatalog.select(all, query: "", fitsOnly: false, sort: .largest, hardware: host) == [large, small, unknown])
        let intel = HardwareProfile(isAppleSilicon: false, memoryGB: 64, coreCount: 8, metalDeviceName: nil)
        #expect(InstalledModelCatalog.fit(small, hardware: intel) == .unavailable)
    }

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
