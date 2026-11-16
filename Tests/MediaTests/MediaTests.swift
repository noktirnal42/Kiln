import AVFoundation
import Foundation
import Testing
@testable import Kiln

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-media-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct StubProvider: ImageGenerationProvider {
    let id: String
    let displayName: String
    let state: ImageProviderAvailability
    var png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    func availability() async -> ImageProviderAvailability { state }
    func generate(prompt: String, count: Int) async throws -> [GeneratedImage] {
        (0..<count).map { _ in GeneratedImage(data: png) }
    }
}

struct MediaKindTests {
    @Test func extensionsDecideTheKind() {
        #expect(MediaKind(url: URL(fileURLWithPath: "/a/clip.MOV")) == .video)
        #expect(MediaKind(url: URL(fileURLWithPath: "/a/pic.heic")) == .image)
        #expect(MediaKind(url: URL(fileURLWithPath: "/a/song.m4a")) == .audio)
        #expect(MediaKind(url: URL(fileURLWithPath: "/a/notes.txt")) == nil)
    }
}

struct MediaGalleryTests {
    @Test func addedItemsAreListedNewestFirstAndSurviveReload() throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let gallery = MediaGallery(root: root)
        let first = try gallery.add(data: Data([1]), fileExtension: "png", kind: .image, title: "one", origin: .generated, prompt: "a cat", provider: "stub")
        Thread.sleep(forTimeInterval: 0.01)
        let second = try gallery.add(data: Data([2]), fileExtension: "caf", kind: .audio, title: "two", origin: .speech)
        let reopened = MediaGallery(root: root)
        #expect(reopened.items().map(\.id) == [second.id, first.id])
        #expect(reopened.item(id: first.id)?.prompt == "a cat")
        #expect(try Data(contentsOf: reopened.fileURL(for: first)) == Data([1]))
        #expect(reopened.fileURL(for: first).deletingLastPathComponent().path.hasPrefix(root.path))
    }

    @Test func removalDeletesTheFileAndTheEntry() throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let gallery = MediaGallery(root: root)
        let item = try gallery.add(data: Data([1]), fileExtension: "png", kind: .image, title: "x", origin: .generated)
        #expect(gallery.remove(id: item.id))
        #expect(gallery.items().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: gallery.fileURL(for: item).path))
        #expect(!gallery.remove(id: item.id))
    }

    @Test func entriesWhoseFileVanishedAreHidden() throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let gallery = MediaGallery(root: root)
        let item = try gallery.add(data: Data([1]), fileExtension: "png", kind: .image, title: "x", origin: .generated)
        try FileManager.default.removeItem(at: gallery.fileURL(for: item))
        #expect(gallery.items().isEmpty)
    }

    @Test func extensionsCannotEscapeTheFolder() throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let gallery = MediaGallery(root: root)
        let item = try gallery.add(data: Data([1]), fileExtension: "../../evil", kind: .image, title: "x", origin: .generated)
        #expect(!item.fileName.contains("/") && !item.fileName.contains(".."))
    }
}

struct ImageProviderSelectionTests {
    @Test func theFirstAvailableProviderIsChosenInOrder() async throws {
        let selector = ImageProviderSelector(providers: [
            StubProvider(id: "a", displayName: "A", state: .unavailable("off")),
            StubProvider(id: "b", displayName: "B", state: .available),
            StubProvider(id: "c", displayName: "C", state: .available),
        ])
        #expect(try await selector.select().id == "b")
        #expect(try await selector.select(preferredID: "c").id == "c")
    }

    @Test func aNamedButUnavailableProviderIsAnErrorNotAFallback() async {
        let selector = ImageProviderSelector(providers: [
            StubProvider(id: "a", displayName: "A", state: .unavailable("no model")),
            StubProvider(id: "b", displayName: "B", state: .available),
        ])
        await #expect(throws: MediaError.noImageProvider("A: no model")) { _ = try await selector.select(preferredID: "a") }
        await #expect(throws: MediaError.self) { _ = try await selector.select(preferredID: "nope") }
    }

    @Test func withNothingUsableTheErrorListsEveryReason() async {
        let selector = ImageProviderSelector(providers: [
            StubProvider(id: "a", displayName: "A", state: .unavailable("off")),
            StubProvider(id: "b", displayName: "B", state: .unavailable("no key")),
        ])
        do { _ = try await selector.select(); Issue.record("should have thrown") }
        catch let error as MediaError {
            let text = error.localizedDescription
            #expect(text.contains("No image provider is configured") && text.contains("A: off") && text.contains("B: no key"))
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func theCustomEndpointNeedsABaseURLAndAModel() async {
        #expect(await OpenAICompatibleImageProvider(baseURL: "", model: "m").availability() != .available)
        #expect(await OpenAICompatibleImageProvider(baseURL: "https://x.test/v1", model: "").availability() != .available)
        #expect(await OpenAICompatibleImageProvider(baseURL: "https://x.test/v1/", model: "m").availability() == .available)
    }

    @Test func theCustomEndpointDecodesB64Images() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 9])
        let body = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png.base64EncodedString()]]])
        let images = try await OpenAICompatibleImageProvider(baseURL: "https://x.test", model: "m").decode(body)
        #expect(images.count == 1 && images[0].data == png && images[0].fileExtension == "png")
        await #expect(throws: MediaError.self) { _ = try await OpenAICompatibleImageProvider(baseURL: "https://x.test", model: "m").decode(Data("{}".utf8)) }
    }
}

@MainActor
struct MediaToolTests {
    private func registry(_ module: MediaModule) -> ToolRegistry {
        let registry = ToolRegistry(tools: [])
        MediaAgentTools.register(module: module, into: registry)
        return registry
    }

    @Test func fiveToolsWithThePrefixAndTheRightPermissionLevels() {
        let specs = Dictionary(uniqueKeysWithValues: registry(MediaModule()).allSpecs().map { ($0.name, $0) })
        #expect(Set(specs.keys) == ["media_open", "media_list", "media_generate_image", "media_speak", "media_transcribe"])
        #expect(specs["media_open"]?.permission == .read)
        #expect(specs["media_list"]?.permission == .read)
        for name in ["media_generate_image", "media_speak", "media_transcribe"] { #expect(specs[name]?.permission == .write, "\(name)") }
        for spec in specs.values { #expect(ExecutionPolicy.isModuleTool(spec.name)) }
        #expect(specs["media_generate_image"]?.parameters.first { $0.name == "prompt" }?.required == true)
        #expect(specs["media_transcribe"]?.parameters.first { $0.name == "path" }?.required == true)
        #expect(specs["media_open"]?.parameters.allSatisfy { !$0.required } == true)
    }

    @Test func readOnlyRunsAreOfferedOnlyTheViewingTools() {
        let reg = registry(MediaModule())
        let readOnly = ExecutionPolicy.readOnly.offeredTools(from: reg, permissions: ToolPermissionSet(enabledTools: ["media_*"], policyByLevel: ToolPermissionSet.conservativeDefaults), workspaceRoot: nil)
        #expect(Set(readOnly.map(\.name)) == ["media_open", "media_list"], "a read-only run is offered the viewing tools and none that write")
    }

    @Test func generateImageStoresIntoTheGalleryThroughTheSelectedProvider() async throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let module = MediaModule()
        module.gallery = MediaGallery(root: root)
        module.imageProvidersOverride = [
            StubProvider(id: "off", displayName: "Off", state: .unavailable("no")),
            StubProvider(id: "on", displayName: "On", state: .available),
        ]
        let tool = try #require(registry(module).tool(named: "media_generate_image"))
        let out = try await tool.execute(argumentsJSON: #"{"prompt":"a red kiln","count":2}"#, context: ToolExecutionContext(workspaceRoot: nil, conversationID: UUID()))
        #expect(out.contains("Generated 2 image(s) with on"))
        #expect(module.gallery.items().count == 2)
        #expect(module.gallery.items().allSatisfy { $0.provider == "on" && $0.prompt == "a red kiln" })
    }

    @Test func noProviderMeansAClearErrorAndNoFile() async throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let module = MediaModule()
        module.gallery = MediaGallery(root: root)
        module.imageProvidersOverride = [StubProvider(id: "off", displayName: "Off", state: .unavailable("not set up"))]
        let tool = try #require(registry(module).tool(named: "media_generate_image"))
        do {
            _ = try await tool.execute(argumentsJSON: #"{"prompt":"x"}"#, context: ToolExecutionContext(workspaceRoot: nil, conversationID: UUID()))
            Issue.record("should have thrown")
        } catch { #expect(error.localizedDescription.contains("No image provider is configured")) }
        #expect(module.gallery.items().isEmpty)
    }

    @Test func openResolvesRelativePathsAndRejectsOtherFiles() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("pic.png"))
        try Data([1]).write(to: dir.appendingPathComponent("notes.txt"))
        let module = MediaModule()
        let tool = try #require(registry(module).tool(named: "media_open"))
        let ctx = ToolExecutionContext(workspaceRoot: dir, conversationID: UUID())
        _ = try await tool.execute(argumentsJSON: #"{"path":"pic.png"}"#, context: ctx)
        #expect(module.current?.kind == .image && module.openRequests == 1)
        await #expect(throws: MediaError.self) { _ = try await tool.execute(argumentsJSON: #"{"path":"notes.txt"}"#, context: ctx) }
        await #expect(throws: MediaError.self) { _ = try await tool.execute(argumentsJSON: #"{"path":"gone.png"}"#, context: ctx) }
    }

    @Test func missingRequiredArgumentsAreRejected() async throws {
        let tool = try #require(registry(MediaModule()).tool(named: "media_speak"))
        await #expect(throws: (any Error).self) { _ = try await tool.execute(argumentsJSON: "{}", context: ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())) }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct SpeechFileTests {
    /// Real speech synthesis needs the Mac's audio services. Hosted CI runners do not reliably provide them (the run hung here for
    /// over an hour), so it runs on a developer's Mac and not under CI, where GitHub sets CI=true.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "needs real audio services; skipped on CI"))
    func speechIsSynthesisedToARealAudioFile() async throws {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let module = MediaModule()
        module.gallery = MediaGallery(root: root)
        let (item, duration) = try await module.speak("Hello from Kiln. This is a test of speech.")
        #expect(duration > 0.5)
        let file = try AVAudioFile(forReading: module.gallery.fileURL(for: item))
        #expect(file.length > 1000)
        #expect(item.kind == .audio && item.origin == .speech)
        let peaks = await Waveform.peaks(of: module.gallery.fileURL(for: item), buckets: 50)
        #expect(peaks.count == 50 && peaks.max() == 1)
    }

    @Test func emptyTextIsRefused() async {
        await #expect(throws: MediaError.emptyText) { _ = try await MediaModule().speak("   ") }
    }
}
