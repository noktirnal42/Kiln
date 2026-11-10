import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import Kiln

// MARK: Helpers

private func samplePNG(width: Int = 8, height: Int = 8, gray: UInt8 = 120) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: CGFloat(gray) / 255, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try! ImageResampler.encodePNG(context.makeImage()!)
}

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-imgtest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func record(prompt: String = "a fox", seed: Int64 = 42) -> GenerationRecord {
    var request = ImageGenerationRequest(prompt: prompt, model: "stabilityai/sd-turbo")
    request.steps = 2; request.guidance = 0; request.width = 512; request.height = 512
    request.loras = [LoRAWeight(name: "detail", weight: 0.6)]; request.negativePrompt = "blurry"
    return GenerationRecord(request: request, engine: "mlx", modelName: "sd-turbo", seed: seed, seconds: 1.5)
}

// MARK: PNG metadata

@Suite struct PNGMetadataTests {
    @Test func settingsRoundTripThroughPNGTextChunks() throws {
        let png = samplePNG()
        let marked = GenerationMetadata.embed(record(), in: png)
        let back = try #require(GenerationMetadata.read(from: marked))
        #expect(back.request.prompt == "a fox" && back.seed == 42 && back.request.loras == [LoRAWeight(name: "detail", weight: 0.6)])
        #expect(back.request.negativePrompt == "blurry" && back.engine == "mlx")
        #expect(back.rerunRequest.seed == 42 && back.rerunRequest.count == 1)
    }

    @Test func theFileIsStillAValidPNGAndKeepsItsPixels() throws {
        let marked = GenerationMetadata.embed(record(), in: samplePNG(width: 16, height: 8))
        #expect(PNGChunks.isPNG(marked))
        let source = try #require(CGImageSourceCreateWithData(marked as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 16 && image.height == 8)
        let chunks = try #require(PNGChunks.parse(marked))
        #expect(chunks.first?.type == "IHDR" && chunks.last?.type == "IEND")
        #expect(chunks.firstIndex { $0.type == "iTXt" }! < chunks.firstIndex { $0.type == "IDAT" }!)
    }

    @Test func embeddingTwiceReplacesNotDuplicates() {
        let once = GenerationMetadata.embed(record(prompt: "one"), in: samplePNG())
        let twice = GenerationMetadata.embed(record(prompt: "two"), in: once)
        #expect(GenerationMetadata.read(from: twice)?.request.prompt == "two")
        #expect(PNGChunks.textEntries(in: twice).filter { $0.keyword == GenerationMetadata.kilnKeyword }.count == 1)
    }

    @Test func aWebUIStyleParametersChunkIsWrittenForOtherTools() throws {
        let text = try #require(PNGChunks.text(forKeyword: "parameters", in: GenerationMetadata.embed(record(), in: samplePNG())))
        #expect(text.contains("a fox") && text.contains("Negative prompt: blurry") && text.contains("Seed: 42") && text.contains("Size: 512x512"))
    }

    @Test func nonPNGAndForeignPNGsAreHandledGracefully() {
        let junk = Data("not a png".utf8)
        #expect(GenerationMetadata.embed(record(), in: junk) == junk)
        #expect(GenerationMetadata.read(from: samplePNG()) == nil)
    }

    @Test func requestDecodingToleratesMissingFields() throws {
        let decoded = try JSONDecoder().decode(ImageGenerationRequest.self, from: Data(#"{"prompt":"x","model":"m","future":1}"#.utf8))
        #expect(decoded.width == 512 && decoded.task == .textToImage && decoded.loras.isEmpty)
    }
}

// MARK: Catalogue

@Suite struct ImageCatalogTests {
    @Test func curatedEntriesAreUniqueAndComplete() {
        let ids = CuratedImageCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        for entry in CuratedImageCatalog.entries {
            #expect(entry.sizeBytes > 0 && !entry.license.isEmpty, "\(entry.id)")
            if case .huggingFace(_, let files, _) = entry.source { #expect(!files.isEmpty, "\(entry.id)") }
        }
        let kinds = Set(CuratedImageCatalog.entries.map(\.kind))
        #expect(kinds.isSuperset(of: [.checkpoint, .lora, .controlNet, .vae, .upscaler, .refiner]))
    }

    @Test func fluxDevIsGatedNonCommercialAndLargeAndSchnellIsApache() throws {
        let dev = try #require(CuratedImageCatalog.entries.first { $0.id == "flux1-dev" })
        #expect(dev.commercialUse == false && dev.gating == .termsAndToken && dev.isLargeDownload)
        #expect(dev.termsNotice.contains("Non-commercial") && dev.termsNotice.contains("cannot accept terms for you"))
        let schnell = try #require(CuratedImageCatalog.entries.first { $0.id == "flux1-schnell" })
        #expect(schnell.license == "Apache-2.0" && schnell.gating == .termsAndToken)
    }

    @Test func theSmallestModelIsUngatedAndRunsInProcess() throws {
        let turbo = try #require(CuratedImageCatalog.entries.first { $0.id == "sd-turbo" })
        #expect(turbo.gating == .open && turbo.engines == ["mlx"] && !turbo.isLargeDownload && turbo.sizeBytes < 3_000_000_000)
    }

    @Test func drawThingsListParsesModelsLorasAndControlNets() throws {
        let models = #"[{"name":"SDXL Turbo","version":"sdxl_base_v0.9","file":"sd_xl_turbo_f16.ckpt","autoencoder":"sdxl_vae_v1.0_f16.ckpt","clip_encoder":"clip_vit_l14_f16.ckpt","text_encoder":"open_clip_vit_bigg14_f16.ckpt","default_scale":8,"note":"A [link](https://x.y) note"},{"name":"Wan","version":"wan_v2.1_14b","file":"wan.ckpt","frames_per_second":16}]"#
        let loras = #"[{"name":"LCM","version":"sdxl_base_v0.9","file":"lcm_lora_f16.ckpt"}]"#
        let controls = #"[{"name":"Canny","version":"flux1","file":"canny.ckpt","type":"canny"}]"#
        let entries = DrawThingsCatalog.parse(models: Data(models.utf8), loras: Data(loras.utf8), controlNets: Data(controls.utf8))
        #expect(entries.count == 4)
        let turbo = try #require(entries.first { $0.name == "SDXL Turbo" })
        #expect(turbo.family == .sdxl && turbo.engines == ["drawthings"] && turbo.summary.contains("A link note"))
        guard case .files(let urls, let names, _) = turbo.source else { Issue.record("expected files"); return }
        #expect(names == ["sd_xl_turbo_f16.ckpt", "sdxl_vae_v1.0_f16.ckpt", "clip_vit_l14_f16.ckpt", "open_clip_vit_bigg14_f16.ckpt"])
        #expect(urls.first?.absoluteString == "https://static.libnnc.org/sd_xl_turbo_f16.ckpt")
        #expect(entries.first { $0.name == "Wan" }?.notes?.contains("Video") == true)
        #expect(entries.first { $0.kind == .lora }?.name == "LCM" && entries.first { $0.kind == .controlNet }?.family == .flux)
    }

    @Test func huggingFaceSearchParsesGatingAndLicense() throws {
        let json = #"[{"id":"a/xl-model","downloads":1200,"gated":"auto","tags":["diffusers","license:openrail++","stable-diffusion-xl"]},{"id":"b/plain","tags":["license:mit"],"gated":false}]"#
        let rows = HuggingFaceImageSearch.parse(Data(json.utf8))
        #expect(rows.count == 2 && rows[0].gating == .termsAndToken && rows[0].family == .sdxl && rows[0].license == "openrail++")
        #expect(rows[1].gating == .open && rows[1].engines.isEmpty)
    }

    @Test func civitaiSearchParsesPrimarySafetensorsAndChecksum() throws {
        let json = #"{"items":[{"id":7,"name":"Fancy XL","type":"Checkpoint","allowCommercialUse":["Image"],"creator":{"username":"zed"},"modelVersions":[{"id":9,"baseModel":"SDXL 1.0","files":[{"name":"x.ckpt","sizeKB":1},{"name":"fancy.safetensors","sizeKB":2048,"primary":true,"downloadUrl":"https://civitai.com/api/download/models/9","hashes":{"SHA256":"ABCDEF"}}]}]},{"id":8,"name":"Bad","type":"Checkpoint","modelVersions":[{"id":1,"files":[{"name":"b.ckpt"}]}]}]}"#
        let rows = CivitaiSearch.parse(Data(json.utf8))
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.family == .sdxl && row.sizeBytes == 2_097_152 && row.commercialUse == true)
        guard case .url(let url, let name, let sha) = row.source else { Issue.record("expected url"); return }
        #expect(url.host == "civitai.com" && name == "fancy.safetensors" && sha == "abcdef")
    }
}

// MARK: Downloader (loopback server, no internet)

@Suite(.serialized) struct ImageDownloaderTests {
    private func makeEntry(repo: String = "org/tiny", files: [String]) -> ImageModelEntry {
        ImageModelEntry(id: "tiny", name: "Tiny", family: .sd2, summary: "", source: .huggingFace(repo: repo, files: files, preferHalf: true),
                        sizeBytes: 100, license: "MIT", engines: ["mlx"])
    }

    /// Serves `org/tiny` at one commit with the given file contents; LFS-style (sha256) for `big.bin`.
    private func serve(_ server: LoopbackServer, files: [String: Data], commit: String = "c0ffee", badSHA: Bool = false, cutFirst: Int? = nil) {
        let counter = ImgStudioCallCounter()
        server.handler = { request in
            let path = request.path.removingPercentEncoding ?? request.path
            if path == "/api/models/org/tiny" { return .init(body: Data(#"{"sha":"\#(commit)"}"#.utf8)) }
            if path.hasPrefix("/api/models/org/tiny/tree/") {
                let tree = files.map { name, data -> String in
                    let oid = badSHA ? String(repeating: "0", count: 64) : hex(data)
                    return #"{"type":"file","path":"\#(name)","size":\#(data.count),"lfs":{"oid":"\#(oid)"},"oid":"x"}"#
                }
                return .init(body: Data("[\(tree.joined(separator: ","))]".utf8))
            }
            if path.hasPrefix("/org/tiny/resolve/\(commit)/") {
                let name = String(path.dropFirst("/org/tiny/resolve/\(commit)/".count))
                guard let data = files[name] else { return .init(status: 404) }
                var response = LoopbackServer.Response(body: data)
                if let cutFirst, request.rangeStart == nil, counter.next() == 1 { response.cutAfter = cutFirst }
                return response
            }
            return .init(status: 404)
        }
    }

    @Test func downloadsIntoTheHubLayoutAndVerifiesChecksums() async throws {
        let server = try LoopbackServer(); try await server.start(); defer { server.stop() }
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let weights = Data((0..<50_000).map { UInt8($0 % 251) })
        serve(server, files: ["unet/config.json": Data("{}".utf8), "unet/diffusion_pytorch_model.safetensors": weights])
        let downloader = ImageModelDownloader(store: ImageModelStore(hubRoot: root), endpoint: server.baseURL, freeSpace: { _ in .max / 2 })
        let entry = makeEntry(files: ["unet/config.json", "unet/diffusion_pytorch_model.safetensors"])
        let id = await downloader.enqueue(entry)
        await downloader.waitUntilIdle()
        let job = try #require(await downloader.snapshot().first { $0.id == id })
        #expect(job.state == .finished && job.bytesDone == Int64(weights.count + 2))
        let store = ImageModelStore(hubRoot: root)
        let snapshot = try #require(store.currentSnapshot(of: "org/tiny"))
        #expect(snapshot.lastPathComponent == "c0ffee")
        let linked = snapshot.appendingPathComponent("unet/diffusion_pytorch_model.safetensors")
        #expect(try Data(contentsOf: linked) == weights)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: linked.path))?.hasSuffix("blobs/\(hex(weights))") == true)
        #expect(store.isInstalled(entry))
    }

    @Test func aDroppedConnectionResumesWithARangeRequest() async throws {
        let server = try LoopbackServer(); try await server.start(); defer { server.stop() }
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let weights = Data((0..<80_000).map { UInt8(($0 * 7) % 253) })
        serve(server, files: ["w.bin": weights], cutFirst: 30_000)
        let downloader = ImageModelDownloader(store: ImageModelStore(hubRoot: root), endpoint: server.baseURL, freeSpace: { _ in .max / 2 })
        let entry = makeEntry(files: ["w.bin"])
        let first = await downloader.enqueue(entry)
        await downloader.waitUntilIdle()
        guard case .failed = await downloader.snapshot().first(where: { $0.id == first })?.state else { Issue.record("the cut download should fail"); return }
        let partial = root.appendingPathComponent("models--org--tiny/blobs/\(hex(weights)).incomplete")
        let have = ((try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber)?.intValue ?? 0
        #expect(have > 0 && have < weights.count, "the partial file is kept")
        let second = await downloader.enqueue(entry)
        await downloader.waitUntilIdle()
        #expect(await downloader.snapshot().first { $0.id == second }?.state == .finished)
        #expect(server.requests.contains { $0.rangeStart == have }, "the retry asked for the rest only")
        let final = root.appendingPathComponent("models--org--tiny/snapshots/c0ffee/w.bin")
        #expect(try Data(contentsOf: final) == weights)
    }

    @Test func aWrongChecksumDiscardsTheFile() async throws {
        let server = try LoopbackServer(); try await server.start(); defer { server.stop() }
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        serve(server, files: ["w.bin": Data(repeating: 1, count: 4096)], badSHA: true)
        let downloader = ImageModelDownloader(store: ImageModelStore(hubRoot: root), endpoint: server.baseURL, freeSpace: { _ in .max / 2 })
        let id = await downloader.enqueue(makeEntry(files: ["w.bin"]))
        await downloader.waitUntilIdle()
        guard case .failed(let why) = await downloader.snapshot().first(where: { $0.id == id })?.state else { Issue.record("expected a failure"); return }
        #expect(why.contains("checksum"))
        let blobs = root.appendingPathComponent("models--org--tiny/blobs")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: blobs.path)) ?? []).isEmpty)
        #expect(!ImageModelStore(hubRoot: root).isInstalled(makeEntry(files: ["w.bin"])))
    }

    @Test func refusesWhenThereIsNotEnoughDiskSpaceAndWritesNothing() async throws {
        let server = try LoopbackServer(); try await server.start(); defer { server.stop() }
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        serve(server, files: ["w.bin": Data(repeating: 2, count: 10_000)])
        let downloader = ImageModelDownloader(store: ImageModelStore(hubRoot: root), endpoint: server.baseURL, freeSpace: { _ in 5_000 }, safetyMargin: 0)
        let id = await downloader.enqueue(makeEntry(files: ["w.bin"]))
        await downloader.waitUntilIdle()
        guard case .failed(let why) = await downloader.snapshot().first(where: { $0.id == id })?.state else { Issue.record("expected a failure"); return }
        #expect(why.contains("Not enough free space"))
        #expect(!server.requests.contains { $0.path.contains("/resolve/") }, "no bytes were requested")
    }

    @Test func gatedModelsExplainTheTokenAndTermsAndNeverAcceptForTheUser() async throws {
        let server = try LoopbackServer(); try await server.start(); defer { server.stop() }
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        server.handler = { _ in .init(status: 401) }
        let downloader = ImageModelDownloader(store: ImageModelStore(hubRoot: root), endpoint: server.baseURL, freeSpace: { _ in .max / 2 })
        let id = await downloader.enqueue(makeEntry(files: ["w.bin"]))
        await downloader.waitUntilIdle()
        guard case .failed(let why) = await downloader.snapshot().first(where: { $0.id == id })?.state else { Issue.record("expected a failure"); return }
        #expect(why.contains("token") && why.contains("accept"))
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == nil }, "no token was configured, none sent")
    }

    @Test func aStoredTokenIsSentAsABearerHeaderOnly() async throws {
        let server = try LoopbackServer(); try await server.start(); defer { server.stop() }
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 3, count: 2048)
        serve(server, files: ["w.bin": data])
        let downloader = ImageModelDownloader(store: ImageModelStore(hubRoot: root), endpoint: server.baseURL, huggingFaceToken: { "hf_test_token" }, freeSpace: { _ in .max / 2 })
        let id = await downloader.enqueue(makeEntry(files: ["w.bin"]))
        await downloader.waitUntilIdle()
        #expect(await downloader.snapshot().first { $0.id == id }?.state == .finished)
        #expect(server.requests.allSatisfy { $0.headers["authorization"] == "Bearer hf_test_token" })
        #expect(server.requests.allSatisfy { !$0.path.contains("hf_test_token") }, "never in a URL")
    }
}

// MARK: Queue, service, outpaint, upscale

private final class ImgStudioCallCounter: @unchecked Sendable {
    private var value = 0; private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

private struct StubEngine: ImageEngine {
    var id = "stub"
    var displayName = "Stub"
    var kind = ImageEngineKind.external
    var ready = true
    var features: Set<ImageFeature> = [.textToImage, .negativePrompt]
    var modelIDs = ["m1"]
    func status() async -> ImageEngineStatus { ready ? .ready("up") : .setup(reason: "down", steps: ["start it"]) }
    func capabilities(model: String?) async -> ImageEngineCapabilities {
        ImageEngineCapabilities(supported: features, reasons: [.lora: "no LoRA here", .inpaint: "no inpaint here"], maxBatch: 2, sideMultiple: 64)
    }
    func models() async -> [EngineModel] { modelIDs.map { EngineModel(id: $0, name: $0) } }
    func generate(_ request: ImageGenerationRequest, progress: @escaping ImageProgressHandler) async throws -> [GeneratedPicture] {
        (0..<request.count).map { GeneratedPicture(png: samplePNG(width: request.width / 64, height: request.height / 64), seed: (request.seed ?? 1) + Int64($0)) }
    }
}

@Suite struct ImageServiceTests {
    private func service(_ engines: [any ImageEngine], root: URL) -> ImageStudioService {
        ImageStudioService(engines: engines, history: ImageHistory(root: root), prompts: PromptLibrary(root: root), store: ImageModelStore(hubRoot: root))
    }

    @Test func generateFilesPicturesWithEmbeddedSettingsAndTheyCanBeRerun() async throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let s = service([StubEngine()], root: root)
        var request = ImageGenerationRequest(prompt: "hello", model: "m1"); request.seed = 5; request.count = 2; request.width = 500; request.height = 700
        let items = try await s.generate(request)
        #expect(items.count == 2)
        let record = try #require(GenerationMetadata.read(from: Data(contentsOf: items[0].url)))
        #expect(record.request.width == 512 && record.request.height == 704, "sizes snap to the engine's multiple")
        #expect(record.seed == 5 && items[1].record?.seed == 6 && record.engine == "stub")
        #expect(s.history.items().count == 2)
        let rerun = try await s.generate(record.rerunRequest)
        #expect(rerun.first?.record?.seed == 5)
    }

    @Test func anEngineThatCannotDoSomethingSaysWhyInsteadOfDroppingIt() async throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let s = service([StubEngine()], root: root)
        var lora = ImageGenerationRequest(prompt: "x", model: "m1"); lora.loras = [LoRAWeight(name: "a")]; lora.engine = "stub"
        await #expect(throws: ImageStudioError.self) { _ = try await s.generate(lora) }
        do { _ = try await s.generate(lora) } catch { #expect(error.localizedDescription.contains("no LoRA here")) }
        var inpaint = ImageGenerationRequest(prompt: "x", model: "m1", task: .inpaint); inpaint.engine = "stub"
        do { _ = try await s.generate(inpaint); Issue.record("should refuse") } catch { #expect(error.localizedDescription.contains("no inpaint here")) }
    }

    @Test func anEngineThatIsNotSetUpNeverProducesOutput() async throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let s = service([StubEngine(ready: false)], root: root)
        do { _ = try await s.generate(ImageGenerationRequest(prompt: "x", model: "m1")); Issue.record("should refuse") }
        catch { #expect(error.localizedDescription.contains("down")) }
        #expect(s.history.items().isEmpty)
        let reports = await s.reports()
        #expect(reports.first?.status == .setup(reason: "down", steps: ["start it"]))
    }

    @Test func automaticChoiceSkipsEnginesThatCannotAndUsesTheNextReadyOne() async throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let weak = StubEngine(id: "weak", features: [.textToImage])
        let strong = StubEngine(id: "strong", features: [.textToImage, .inpaint, .lora, .outpaint])
        let s = service([weak, strong], root: root)
        var request = ImageGenerationRequest(prompt: "x", model: "m1"); request.loras = [LoRAWeight(name: "a")]
        let items = try await s.generate(request)
        #expect(items.first?.record?.engine == "strong")
    }

    @Test func outpaintBuildsALargerCanvasWithAMaskOverTheNewBorder() throws {
        let source = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(samplePNG(width: 64, height: 64) as CFData, nil)!, 0, nil)!
        let out = try ImageResampler.outpaintCanvas(source: source, padding: OutpaintPadding(left: 0, right: 64, top: 0, bottom: 0))
        #expect(out.width == 128 && out.height == 64)
        let mask = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(out.mask as CFData, nil)!, 0, nil)!
        func gray(_ x: Int, _ y: Int) -> UInt8 {
            let data = (mask.dataProvider!.data! as Data)
            let bytesPerPixel = mask.bitsPerPixel / 8
            return data[y * mask.bytesPerRow + x * bytesPerPixel]
        }
        #expect(gray(100, 30) > 200, "new area is white (repaint)")
        #expect(gray(20, 30) < 50, "original area is black (keep)")
    }

    @Test func upscaleMakesALargerPNGAndKeepsTheSettings() throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let s = service([], root: root)
        let item = try s.history.add(png: samplePNG(width: 32, height: 16), record: record())
        let big = try s.upscale(path: item.url.path, factor: 2)
        let size = ImageResampler.size(of: try Data(contentsOf: big.url))
        #expect(size?.width == 64 && size?.height == 32)
        #expect(big.record?.request.prompt == "a fox" && big.record?.engine == "lanczos")
        #expect(throws: ImageStudioError.self) { _ = try ImageResampler.upscale(samplePNG(), factor: 20) }
    }

    @Test func stylesMergeIntoThePromptAndAreRecorded() {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let s = service([], root: root)
        var request = ImageGenerationRequest(prompt: "a cat", model: "m"); request.negativePrompt = "ugly"
        s.applyStyles(["anime"], to: &request)
        #expect(request.prompt.hasPrefix("a cat, anime style") && request.negativePrompt.hasPrefix("ugly, photo") && request.styles == ["Anime"])
    }

    @Test func promptLibrarySavesAndRemovesPrompts() throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PromptLibrary(root: root)
        let saved = SavedPrompt(title: "Fox", prompt: "a fox")
        try library.add(saved); try library.add(PromptStyle(name: "Mine", prompt: "{prompt}, mine"))
        #expect(library.savedPrompts() == [saved] && library.styles().contains { $0.name == "Mine" })
        try library.removePrompt(id: saved.id)
        #expect(library.savedPrompts().isEmpty)
    }

    @Test func comfyWorkflowChainsLorasAndUsesAMaskForInpaint() throws {
        var r = ImageGenerationRequest(prompt: "p", model: "ckpt.safetensors", task: .inpaint)
        r.loras = [LoRAWeight(name: "a.safetensors", weight: 0.5), LoRAWeight(name: "b.safetensors", weight: 1)]
        let graph = ComfyUIEngine.workflow(for: r, seed: 9, sourceName: "src.png", maskName: "mask.png")
        let types = Set(graph.values.compactMap { ($0 as? [String: Any])?["class_type"] as? String })
        #expect(types.isSuperset(of: ["CheckpointLoaderSimple", "LoraLoader", "SetLatentNoiseMask", "KSampler", "SaveImage", "VAEEncode"]))
        let sampler = try #require((graph["3"] as? [String: Any])?["inputs"] as? [String: Any])
        #expect((sampler["model"] as? [Any])?.first as? String == "lora1" && (sampler["seed"] as? Int64) == 9)
        #expect(JSONSerialization.isValidJSONObject(graph))
    }
}

@Suite struct ImageQueueTests {
    @Test func runsOneAtATimeInOrderAndCancelsQueuedJobs() async {
        let order = OrderLog()
        let queue = ImageJobQueue { request, _ in
            await order.add(request.prompt)
            try await Task.sleep(nanoseconds: 60_000_000)
            return [UUID()]
        }
        let a = await queue.enqueue(ImageGenerationRequest(prompt: "a", model: "m"))
        let b = await queue.enqueue(ImageGenerationRequest(prompt: "b", model: "m"))
        let c = await queue.enqueue(ImageGenerationRequest(prompt: "c", model: "m"))
        await queue.cancel(b)
        await queue.waitUntilIdle()
        #expect(await order.items == ["a", "c"])
        let states = Dictionary(uniqueKeysWithValues: await queue.snapshot().map { ($0.id, $0.state) })
        #expect(states[b] == .cancelled)
        if case .done = states[a] {} else { Issue.record("a should be done") }
        if case .done = states[c] {} else { Issue.record("c should be done") }
    }

    @Test func aRunningJobCanBeStoppedAndAFailureDoesNotBlockTheNext() async {
        let queue = ImageJobQueue { request, _ in
            if request.prompt == "slow" { try await Task.sleep(nanoseconds: 5_000_000_000) }
            if request.prompt == "bad" { throw ImageStudioError.failed("boom") }
            return [UUID()]
        }
        let slow = await queue.enqueue(ImageGenerationRequest(prompt: "slow", model: "m"))
        let bad = await queue.enqueue(ImageGenerationRequest(prompt: "bad", model: "m"))
        let good = await queue.enqueue(ImageGenerationRequest(prompt: "good", model: "m"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        await queue.cancel(slow)
        await queue.waitUntilIdle()
        let states = Dictionary(uniqueKeysWithValues: await queue.snapshot().map { ($0.id, $0.state) })
        #expect(states[slow] == .cancelled && states[bad] == .failed("boom"))
        if case .done = states[good] {} else { Issue.record("good should run after the failure") }
    }
}

private actor OrderLog { var items: [String] = []; func add(_ s: String) { items.append(s) } }

// MARK: Tools

@Suite struct ImageToolTests {
    @Test func specsPermissionsAndPrefix() {
        let specs = Dictionary(uniqueKeysWithValues: ImageAgentTools.Kind.allCases.map { ($0.spec.name, $0.spec) })
        #expect(Set(specs.keys) == ["image_list_models", "image_download_model", "image_generate", "image_edit", "image_upscale", "image_history"])
        for name in ["image_list_models", "image_history"] { #expect(specs[name]?.permission == .read, "\(name)") }
        for name in ["image_download_model", "image_generate", "image_edit", "image_upscale"] { #expect(specs[name]?.permission == .write, "\(name)") }
        for spec in specs.values { #expect(ExecutionPolicy.isModuleTool(spec.name)) }
        #expect(specs["image_generate"]?.parameters.first { $0.name == "prompt" }?.required == true)
        #expect(specs["image_download_model"]?.parameters.first { $0.name == "model_id" }?.required == true)
        #expect(specs["image_download_model"]?.parameters.first { $0.name == "confirm_large" }?.required == false)
        #expect(specs["image_edit"]?.parameters.first { $0.name == "image_path" }?.required == true)
    }

    @MainActor @Test func aReadOnlyRunIsOfferedOnlyTheReadingTools() {
        let registry = ToolRegistry()
        let module = ImageStudioModule()
        ImageAgentTools.register(module: module, into: registry)
        let offered = ExecutionPolicy.readOnly.offeredTools(from: registry, permissions: ToolPermissionSet(enabledTools: ["image_*"], policyByLevel: ToolPermissionSet.conservativeDefaults), workspaceRoot: nil)
        #expect(Set(offered.map(\.name)) == ["image_list_models", "image_history"])
    }

    @Test func workstationAgentProfileEnablesImageTools() {
        let profile = AgentProfile.builtIns.first { $0.name == "Workstation Agent" }
        #expect(profile?.toolPermissions.isEnabled("image_generate") == true)
    }

    @Test func requestsAreBuiltFromArgumentsWithTurboDefaults() throws {
        let r = try ImageAgentTools.request(from: ["prompt": "fox", "model": "stabilityai/sd-turbo", "seed": 3, "count": 9], task: .textToImage, workspace: nil)
        #expect(r.steps == 4 && r.guidance == 0 && r.seed == 3 && r.count == 4)
        let edit = try ImageAgentTools.request(from: ["prompt": "x", "image_path": "a.png", "padding_right": 64], task: .outpaint, workspace: URL(fileURLWithPath: "/proj"))
        #expect(edit.initImagePath == "/proj/a.png" && edit.outpaint?.right == 64)
        #expect(throws: ImageToolError.self) { _ = try ImageAgentTools.request(from: ["prompt": " "], task: .textToImage, workspace: nil) }
        #expect(throws: ImageToolError.self) { _ = try ImageAgentTools.request(from: ["prompt": "x"], task: .imageToImage, workspace: nil) }
    }

    @Test func settingsHasRowsForTheTwoDownloadTokens() {
        let ids = Set(ProviderKeyEntry.all.map(\.id))
        #expect(ids.isSuperset(of: ["huggingface", "civitai"]))
        #expect(ProviderKeyEntry.all.first { $0.id == "huggingface" }?.keysPage?.host == "huggingface.co")
    }
}
