import XCTest
import CryptoKit
@testable import AxiomCore

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let (status, headers, body) = handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class IntelligenceTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824
    private func hardware(_ gb: UInt64) -> HardwareProfile { HardwareProfile(chip: "Test", physicalMemory: gb * gib, performanceCores: 8, efficiencyCores: 4) }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func stubSession() -> URLSession { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [StubProtocol.self]; return URLSession(configuration: c) }
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axiom-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private let revision = String(repeating: "a", count: 40)

    // MARK: Ranking

    func testBudgetAndFitDependOnMemory() {
        let eight = MLXCatalog.curated.first { $0.repoID.contains("Qwen3-8B") }!
        XCTAssertEqual(ModelRanker.fit(eight, on: hardware(8)), .tooLarge)
        XCTAssertEqual(ModelRanker.fit(eight, on: hardware(16)), .comfortable)
        XCTAssertEqual(ModelRanker.fit(eight, on: hardware(64)), .comfortable)
        let thirtyTwo = MLXCatalog.curated.first { $0.repoID.contains("Coder-32B") }!
        XCTAssertEqual(ModelRanker.fit(thirtyTwo, on: hardware(18)), .tooLarge)
        XCTAssertEqual(ModelRanker.fit(thirtyTwo, on: hardware(64)), .comfortable)
    }

    func testRankingPutsBestComfortableModelFirstAndRecommendsIt() throws {
        let ranked = ModelRanker.rank(MLXCatalog.curated, on: hardware(18))
        XCTAssertEqual(ranked.first?.fit, .comfortable)
        XCTAssertTrue(ranked.first?.recommended == true)
        XCTAssertEqual(ranked.filter(\.recommended).count, 1)
        let fits = ranked.map(\.fit)
        XCTAssertEqual(fits, fits.sorted(by: >), "fit classes must be grouped best-first")
        XCTAssertEqual(ranked.last?.fit, .tooLarge)
        let big = ModelRanker.rank(MLXCatalog.curated, on: hardware(128))
        XCTAssertTrue(big.first?.model.parametersBillions ?? 0 > ranked.first?.model.parametersBillions ?? 0, "more memory should recommend a larger model")
    }

    func testGatedModelIsNeverRecommended() {
        let gated = MLXModel(repoID: "mlx-community/Gated-70B-4bit", parametersBillions: 70, quantBits: 4, sizeBytes: 1_000_000_000, gated: true)
        let open = MLXModel(repoID: "mlx-community/Open-1B-4bit", parametersBillions: 1, quantBits: 4, sizeBytes: 500_000_000)
        let ranked = ModelRanker.rank([gated, open], on: hardware(64))
        XCTAssertEqual(ranked.first { $0.recommended }?.model.repoID, open.repoID)
    }

    // MARK: Hugging Face parsing

    func testParseSearchComputesSizeBitsAndFiltersUnsafeIDs() throws {
        let json = """
        [{"id":"mlx-community/Qwen3-8B-4bit","downloads":1234,"likes":5,"gated":false,"sha":"x","tags":["mlx","license:apache-2.0"],
          "config":{"model_type":"qwen3","max_position_embeddings":40960,"quantization_config":{"bits":4}},
          "safetensors":{"parameters":{"BF16":1000000,"U32":1000000000}}},
         {"id":"../evil/model","safetensors":{"parameters":{"U32":10}}},
         {"id":"mlx-community/NoWeights","safetensors":{"parameters":{}}}]
        """
        let models = try HuggingFaceClient.parseSearch(Data(json.utf8))
        XCTAssertEqual(models.count, 1)
        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(model.quantBits, 4)
        XCTAssertEqual(model.sizeBytes, 1_000_000 * 2 + 1_000_000_000 * 4)
        XCTAssertEqual(model.parametersBillions, 8, accuracy: 0.001)
        XCTAssertEqual(model.license, "apache-2.0"); XCTAssertEqual(model.contextLength, 40960)
    }

    func testParseSearchSurfacesAPIError() {
        XCTAssertThrowsError(try HuggingFaceClient.parseSearch(Data(#"{"error":"nope"}"#.utf8)))
    }

    func testManifestKeepsOnlyMLXFilesAndRejectsTraversal() throws {
        let good = """
        [{"type":"file","path":"config.json","size":10,"oid":"aa11"},{"type":"file","path":"README.md","size":5,"oid":"bb22"},
         {"type":"file","path":"model.safetensors","size":100,"oid":"cc33","lfs":{"oid":"abc123"}},{"type":"directory","path":"sub"}]
        """
        let manifest = try HuggingFaceClient.parseManifest(repoID: "mlx-community/x", revision: revision, tree: Data(good.utf8))
        XCTAssertEqual(manifest.files.map(\.path), ["config.json", "model.safetensors"])
        XCTAssertEqual(manifest.totalBytes, 110)
        let evil = #"[{"type":"file","path":"../../etc/x.json","size":1,"oid":"aa"},{"type":"file","path":"config.json","size":1,"oid":"aa"},{"type":"file","path":"m.safetensors","size":1,"oid":"aa"}]"#
        XCTAssertThrowsError(try HuggingFaceClient.parseManifest(repoID: "mlx-community/x", revision: revision, tree: Data(evil.utf8)))
        XCTAssertThrowsError(try HuggingFaceClient.parseManifest(repoID: "mlx-community/x", revision: revision, tree: Data(#"[{"type":"file","path":"config.json","size":1,"oid":"aa"}]"#.utf8)))
    }

    func testRepoIDValidation() {
        XCTAssertTrue(HuggingFaceClient.isSafeRepoID("mlx-community/Qwen3-8B-4bit"))
        for bad in ["", "a", "a/b/c", "../x", "a/..", "a/b c", "a/b;rm", "/a/b"] { XCTAssertFalse(HuggingFaceClient.isSafeRepoID(bad), bad) }
    }

    // MARK: Downloader and shared store

    private func gitID(_ data: Data) -> String { Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data).map { String(format: "%02x", $0) }.joined() }
    private let config = Data(#"{"model_type":"test"}"#.utf8)
    private func makeManifest(_ weights: Data, repo: String = "mlx-community/Tiny-4bit") -> HuggingFaceClient.Manifest {
        HuggingFaceClient.Manifest(repoID: repo, revision: revision, files: [
            .init(path: "config.json", size: UInt64(config.count), gitOID: gitID(config)),
            .init(path: "model.safetensors", size: UInt64(weights.count), sha256: sha(weights), gitOID: "ffff")])
    }
    private func weightsData(_ n: Int = 300_000) -> Data { Data((0..<n).map { UInt8($0 % 251) }) }
    private func serve(_ weights: Data) { StubProtocol.handler = { [config] request in (200, [:], request.url!.path.hasSuffix("config.json") ? config : weights) } }

    func testDownloadUsesHFCacheLayoutAndLinksResolve() async throws {
        let weights = weightsData(); StubProtocol.requests = []; serve(weights)
        let store = ModelStore(root: try tempRoot())
        let model = try await ModelDownloader(store: store, session: stubSession()).install(makeManifest(weights))
        let repo = store.root.appendingPathComponent("models--mlx-community--Tiny-4bit")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8), revision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("blobs/\(sha(weights))").path), "LFS blob is named by sha256")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("blobs/\(gitID(config))").path), "small blob is named by git object id")
        let link = repo.appendingPathComponent("snapshots/\(revision)/model.safetensors").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "../../blobs/\(sha(weights))")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: model.path + "/model.safetensors")), weights)
        XCTAssertEqual(store.installed().map(\.repoID), ["mlx-community/Tiny-4bit"])
    }

    func testSecondInstallAndSharedBlobsAreNotDownloadedAgain() async throws {
        let weights = weightsData(); serve(weights)
        let store = ModelStore(root: try tempRoot()); let downloader = ModelDownloader(store: store, session: stubSession())
        _ = try await downloader.install(makeManifest(weights))
        StubProtocol.requests = []
        _ = try await downloader.install(makeManifest(weights))
        XCTAssertTrue(StubProtocol.requests.isEmpty, "everything already stored: no network")
    }

    func testResumeSendsRangeAndCompletes() async throws {
        let weights = weightsData(); let store = ModelStore(root: try tempRoot())
        let blobs = store.root.appendingPathComponent("models--mlx-community--Tiny-4bit/blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try weights.prefix(100_000).write(to: blobs.appendingPathComponent("\(sha(weights)).incomplete"))
        StubProtocol.requests = []
        StubProtocol.handler = { [config] request in
            if request.url!.path.hasSuffix("config.json") { return (200, [:], config) }
            guard let range = request.value(forHTTPHeaderField: "Range"), let start = Int(range.dropFirst(6).dropLast()) else { return (200, [:], weights) }
            return (206, [:], weights.suffix(from: start))
        }
        let model = try await ModelDownloader(store: store, session: stubSession()).install(makeManifest(weights))
        XCTAssertEqual(StubProtocol.requests.first { $0.url!.path.hasSuffix("safetensors") }?.value(forHTTPHeaderField: "Range"), "bytes=100000-")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: model.path + "/model.safetensors")), weights)
    }

    func testServerIgnoringRangeRestartsCleanly() async throws {
        let weights = weightsData(200_000); serve(weights); let store = ModelStore(root: try tempRoot())
        let blobs = store.root.appendingPathComponent("models--mlx-community--Tiny-4bit/blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 50_000).write(to: blobs.appendingPathComponent("\(sha(weights)).incomplete"))
        let model = try await ModelDownloader(store: store, session: stubSession()).install(makeManifest(weights))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: model.path + "/model.safetensors")), weights)
    }

    func testCorruptedDownloadIsRejectedAndDiscarded() async throws {
        let weights = weightsData(100_000); var corrupted = weights; corrupted[500] ^= 0xFF
        serve(corrupted); let store = ModelStore(root: try tempRoot())
        do { _ = try await ModelDownloader(store: store, session: stubSession()).install(makeManifest(weights)); XCTFail("should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("SHA-256")) }
        XCTAssertTrue(store.installed().isEmpty)
        let blobs = store.root.appendingPathComponent("models--mlx-community--Tiny-4bit/blobs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobs.appendingPathComponent("\(sha(weights)).incomplete").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobs.appendingPathComponent(sha(weights)).path))
    }

    func testInsufficientDiskIsReportedBeforeDownloading() async throws {
        StubProtocol.requests = []; StubProtocol.handler = { _ in (200, [:], Data()) }
        let huge = HuggingFaceClient.Manifest(repoID: "mlx-community/Huge-4bit", revision: revision, files: [.init(path: "config.json", size: 1, gitOID: "aa"), .init(path: "m.safetensors", size: 900_000_000_000_000, sha256: "bb")])
        do { _ = try await ModelDownloader(store: ModelStore(root: try tempRoot()), session: stubSession()).install(huge); XCTFail("should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Not enough disk space")) }
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testUnmountedSymlinkedStoreIsRefusedNotCreated() throws {
        let base = try tempRoot(); let link = base.appendingPathComponent("hub")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Volumes/DefinitelyNotMounted-\(UUID().uuidString)/hub")
        XCTAssertThrowsError(try ModelStore(root: link).ensureAvailable())
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/Volumes/DefinitelyNotMounted"))
    }

    func testRemoveRefusesNonStoreAndInvalidIDs() throws {
        let store = ModelStore(root: try tempRoot())
        XCTAssertThrowsError(try store.remove(repoID: "../x"))
        XCTAssertThrowsError(try store.remove(repoID: "mlx-community/NotThere"))
    }

    // MARK: Adopting another app's plain copy

    func testAdoptAcceptsIdenticalCopyAndRejectsDifferentRevision() throws {
        let weights = weightsData(); let manifest = makeManifest(weights); let store = ModelStore(root: try tempRoot())
        let plain = try tempRoot().appendingPathComponent("their-copy"); try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try config.write(to: plain.appendingPathComponent("config.json")); try weights.write(to: plain.appendingPathComponent("model.safetensors"))
        guard case .adopted(let files, _) = try store.adopt(directory: plain, manifest: manifest) else { return XCTFail("expected adoption") }
        XCTAssertEqual(files, 2)
        XCTAssertEqual(store.installed().first?.repoID, "mlx-community/Tiny-4bit")
        XCTAssertEqual(try store.adopt(directory: plain, manifest: manifest), .duplicate)
        var changed = weights; changed[10] ^= 1; try changed.write(to: plain.appendingPathComponent("model.safetensors"))
        let other = ModelStore(root: try tempRoot())
        guard case .mismatch = try other.adopt(directory: plain, manifest: manifest) else { return XCTFail("expected mismatch") }
        XCTAssertTrue(other.installed().isEmpty)
    }
}
