import Foundation
import Testing
@testable import Kiln

/// Downloads SD-Turbo (2.6 GB) into the universal model store and generates real pictures with the MLX engine.
/// Opt-in: `TEST_RUNNER_KILN_LIVE_IMAGE=1`. History goes to a temporary folder, never Application Support.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE_IMAGE"] == "1"), .serialized)
struct LiveImageStudioTests {
    @Test func downloadSDTurboAndGenerate() async throws {
        let store = ImageModelStore()
        let entry = CuratedImageCatalog.entries.first { $0.id == "sd-turbo" }!
        let downloader = ImageModelDownloader(store: store)
        if !store.isInstalled(entry) {
            let id = await downloader.enqueue(entry)
            await downloader.waitUntilIdle()
            let job = await downloader.snapshot().first { $0.id == id }
            print("IMG download state: \(String(describing: job?.state)) bytes \(job?.bytesDone ?? 0)")
            #expect(job?.state == .finished)
        }
        #expect(store.isInstalled(entry))

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-img-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let service = ImageStudioService(engines: [MLXDiffusionEngine(store: store)], history: ImageHistory(root: temp),
                                         prompts: PromptLibrary(root: temp), store: store, downloader: downloader)
        var request = ImageGenerationRequest(prompt: "a red fox sitting in a snowy forest, golden hour, detailed photograph", model: "stabilityai/sd-turbo")
        request.steps = 2; request.seed = 7; request.width = 512; request.height = 512
        let start = Date()
        let items = try await service.generate(request)
        let first = Date().timeIntervalSince(start)
        let second = Date()
        request.seed = 8
        let again = try await service.generate(request)
        print("IMG first run (incl. model load) \(String(format: "%.1f", first)) s; second \(String(format: "%.1f", Date().timeIntervalSince(second))) s")
        #expect(items.count == 1 && again.count == 1)
        let data = try Data(contentsOf: items[0].url)
        #expect(GenerationMetadata.read(from: data)?.seed == 7)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-img-live-fox.png")
        try data.write(to: out)
        try Data(contentsOf: again[0].url).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("kiln-img-live-fox2.png"))
        print("IMG wrote \(out.path)")

        // image to image from the first picture
        var edit = ImageGenerationRequest(prompt: "the same fox at night under the stars", model: "stabilityai/sd-turbo", task: .imageToImage)
        edit.initImagePath = out.path; edit.steps = 4; edit.strength = 0.6; edit.seed = 3
        let edited = try await service.generate(edit)
        try Data(contentsOf: edited[0].url).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("kiln-img-live-fox-night.png"))
        let peak = ProcessInfo.processInfo.physicalMemory
        print("IMG img2img ok; physical memory \(peak / 1_000_000_000) GB")
    }
}
