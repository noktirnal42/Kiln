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

    private static func peakResidentGB() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_000_000_000   // bytes on macOS
    }

    /// SDXL-Turbo (6.94 GB) into the hub folder named by KILN_LIVE_IMAGE_HUB, then real generations; PNGs go to KILN_LIVE_IMAGE_OUT.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE_IMAGE_HUB"] != nil)) func sdxlTurboDownloadAndGenerate() async throws {
        let env = ProcessInfo.processInfo.environment
        let hub = URL(fileURLWithPath: env["KILN_LIVE_IMAGE_HUB"]!)
        let out = URL(fileURLWithPath: env["KILN_LIVE_IMAGE_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        let store = ImageModelStore(hubRoot: hub)
        let entry = CuratedImageCatalog.entries.first { $0.id == "sdxl-turbo" }!
        let downloader = ImageModelDownloader(store: store)
        if !store.isInstalled(entry) {
            let t0 = Date()
            let id = await downloader.enqueue(entry)
            await downloader.waitUntilIdle()
            let job = await downloader.snapshot().first { $0.id == id }
            print("IMG sdxl download \(String(describing: job?.state)) \(job?.bytesDone ?? 0) bytes in \(Int(Date().timeIntervalSince(t0))) s")
            #expect(job?.state == .finished)
        }
        #expect(store.isInstalled(entry))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-img-sdxl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let service = ImageStudioService(engines: [MLXDiffusionEngine(store: store)], history: ImageHistory(root: temp),
                                         prompts: PromptLibrary(root: temp), store: store, downloader: downloader)
        var request = ImageGenerationRequest(prompt: "a lighthouse on a cliff at sunset, dramatic clouds, detailed photograph", model: "stabilityai/sdxl-turbo")
        request.steps = 2; request.guidance = 0; request.seed = 11; request.width = 512; request.height = 512
        let t1 = Date()
        let first = try await service.generate(request)
        let loadAndRun = Date().timeIntervalSince(t1)
        let rssAfterFirst = Self.peakResidentGB()
        let t2 = Date()
        request.seed = 12
        _ = try await service.generate(request)
        print("IMG sdxl first (load+run) \(String(format: "%.1f", loadAndRun)) s, second \(String(format: "%.1f", Date().timeIntervalSince(t2))) s, peak RSS after first \(String(format: "%.1f", rssAfterFirst)) GB")
        request.seed = 11; request.width = 768; request.height = 768; request.steps = 4
        let t3 = Date()
        let big = try await service.generate(request)
        print("IMG sdxl 768 x 4 steps \(String(format: "%.1f", Date().timeIntervalSince(t3))) s, peak RSS \(String(format: "%.1f", Self.peakResidentGB())) GB")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let a = out.appendingPathComponent("sdxl-turbo-lighthouse-512-seed11.png"), b = out.appendingPathComponent("sdxl-turbo-lighthouse-768-4step-seed11.png")
        try Data(contentsOf: first[0].url).write(to: a); try Data(contentsOf: big[0].url).write(to: b)
        #expect(GenerationMetadata.read(from: try Data(contentsOf: a))?.request.model == "stabilityai/sdxl-turbo")
        print("IMG wrote \(a.path) and \(b.path)")
    }

    /// Queue, history, determinism from embedded settings, and upscale with the real MLX engine and SD-Turbo.
    @Test func queueHistoryRerunAndUpscaleWithTheRealEngine() async throws {
        let store = ImageModelStore()
        let entry = CuratedImageCatalog.entries.first { $0.id == "sd-turbo" }!
        try #require(store.isInstalled(entry), "run the SD-Turbo test first")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-img-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let service = ImageStudioService(engines: [MLXDiffusionEngine(store: store)], history: ImageHistory(root: temp),
                                         prompts: PromptLibrary(root: temp), store: store)
        let queue = ImageJobQueue { request, progress in try await service.generate(request, progress: progress).map(\.id) }
        var one = ImageGenerationRequest(prompt: "a lighthouse at dawn", model: "stabilityai/sd-turbo"); one.steps = 2; one.seed = 21
        var two = one; two.prompt = "a paper boat on a pond"; two.seed = 22
        let a = await queue.enqueue(one), b = await queue.enqueue(two)
        await queue.waitUntilIdle()
        let jobs = await queue.snapshot()
        for id in [a, b] { if case .done(let ids)? = jobs.first(where: { $0.id == id })?.state { #expect(ids.count == 1) } else { Issue.record("job \(id) did not finish: \(String(describing: jobs.first { $0.id == id }?.state))") } }
        let items = service.history.items()
        #expect(items.count == 2 && items.allSatisfy { $0.record != nil })
        // Re-running from the embedded settings reproduces the same pixels.
        let original = try #require(items.first { $0.record?.seed == 21 })
        let again = try await service.generate(try #require(original.record).rerunRequest)
        let x = try Data(contentsOf: original.url), y = try Data(contentsOf: again[0].url)
        let strip: (Data) -> Data = { PNGChunks.serialize((PNGChunks.parse($0) ?? []).filter { $0.type == "IDAT" }) }
        print("IMG rerun identical pixels: \(strip(x) == strip(y))")
        #expect(strip(x) == strip(y))
        let up = try service.upscale(path: original.url.path, factor: 2)
        let size = ImageResampler.size(of: try Data(contentsOf: up.url))
        print("IMG upscale 512 -> \(size?.width ?? 0)")
        #expect(size?.width == 1024)
        let outDir = ProcessInfo.processInfo.environment["KILN_LIVE_IMAGE_OUT"].map { URL(fileURLWithPath: $0) }
        if let outDir { try? Data(contentsOf: up.url).write(to: outDir.appendingPathComponent("sd-turbo-lighthouse-upscaled-x2.png")) }
    }
}
