import AppKit
import AVFoundation
import Foundation
import Observation
import SwiftUI

/// Media: a viewer for video, images and audio, a gallery of what Kiln generated, image generation behind a provider protocol,
/// and text to speech / speech to text. Every action here is also an agent and MCP tool (`media_*`).
@MainActor
@Observable
public final class MediaModule: @preconcurrency Module, ModuleDefinition, ModuleUI {
    public nonisolated static let identifier = "com.kiln.media"
    public nonisolated static let displayName = "Media"
    public nonisolated static let version = "1.0.0"
    public nonisolated static let dependencies: [String] = []
    public nonisolated static let requiredCapabilities: ModuleCapabilities = [.fileSystemRead, .fileSystemWrite, .networkClient, .microphoneAccess]

    public static let imageModelKey = "media.image.model"
    public static let imageProviderKey = "media.image.provider"

    public struct Target: Equatable, Sendable { public let url: URL; public let kind: MediaKind; public var title: String }

    /// What the viewer is showing.
    public private(set) var current: Target?
    /// Bumped whenever something outside the Media screen (the agent) asks to see a file, so the window can switch to Media.
    public private(set) var openRequests = 0
    public private(set) var items: [MediaItem] = []
    public private(set) var busy: String?
    public private(set) var message: String?
    public private(set) var lastTranscript: String?
    public private(set) var providerStatuses: [ImageProviderSelector.Status] = []

    public var gallery: MediaGallery = .default
    /// Tests and previews replace the real providers with these.
    @ObservationIgnored public var imageProvidersOverride: [any ImageGenerationProvider]?
    @ObservationIgnored public private(set) lazy var speech = SpeechFileSynthesizer()
    @ObservationIgnored private var context: ModuleContext?
    /// The same recogniser the composer's mic uses; Media only borrows it for dictating into the transcript box.
    @ObservationIgnored public private(set) lazy var voice = VoiceController()

    public nonisolated init() {}

    // MARK: Module lifecycle

    public func initialize(context: ModuleContext) async throws {
        self.context = context
        context.logger.info("Media module initialized")
        reloadGallery()
    }
    public func activate() async throws { reloadGallery(); await refreshProviders() }
    public func deactivate() async throws { voice.stopEverything(); speech.stop() }
    public func shutdown() async throws { voice.stopEverything(); speech.stop(); context = nil }

    public func makeRootView() -> AnyView { AnyView(MediaRootView(module: self)) }

    // MARK: Gallery

    public func reloadGallery() { items = gallery.items() }

    public func deleteItem(_ item: MediaItem) {
        gallery.remove(id: item.id)
        if current?.url == gallery.fileURL(for: item) { current = nil }
        reloadGallery()
    }

    // MARK: Viewing

    /// Shows a file in the viewer. Throws for a missing or unsupported file.
    @discardableResult
    public func open(_ url: URL, title: String? = nil) throws -> MediaKind {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.fileMissing(url.path) }
        guard let kind = MediaKind(url: url) else { throw MediaError.unsupportedFile(url.lastPathComponent) }
        current = Target(url: url, kind: kind, title: title ?? url.lastPathComponent)
        message = nil
        return kind
    }

    /// Opening on behalf of the agent also asks the window to switch to the Media activity.
    @discardableResult
    public func openForAgent(_ url: URL) throws -> MediaKind {
        let kind = try open(url)
        openRequests += 1
        return kind
    }

    public func openItem(_ item: MediaItem) {
        _ = try? open(gallery.fileURL(for: item), title: item.title)
    }

    // MARK: Images

    public func imageSelector() async -> ImageProviderSelector {
        if let imageProvidersOverride { return ImageProviderSelector(providers: imageProvidersOverride) }
        var providers: [any ImageGenerationProvider] = [ApplePlaygroundImageProvider()]
        if let context {
            let base = await context.settings.get("providers.custom.baseURL", as: String.self, fallback: "")
            let model = UserDefaults.standard.string(forKey: Self.imageModelKey) ?? ""
            providers.append(OpenAICompatibleImageProvider(
                baseURL: base, model: model,
                secretProvider: context.keychain.secretProvider(module: providersKeychainModule, key: "custom")))
        }
        return ImageProviderSelector(providers: providers)
    }

    public func refreshProviders() async { providerStatuses = await imageSelector().statuses() }

    /// Generates images and stores them in the gallery. Nothing is produced when no provider is usable.
    public func generateImages(prompt: String, count: Int = 1, providerID: String? = nil) async throws -> [MediaItem] {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MediaError.emptyText }
        let provider = try await imageSelector().select(preferredID: providerID ?? UserDefaults.standard.string(forKey: Self.imageProviderKey))
        busy = "Generating with \(provider.displayName)…"
        defer { busy = nil }
        let images = try await provider.generate(prompt: text, count: count)
        let saved = try images.map {
            try gallery.add(data: $0.data, fileExtension: $0.fileExtension, kind: .image, title: String(text.prefix(60)),
                            origin: .generated, prompt: text, provider: provider.id)
        }
        reloadGallery()
        if let first = saved.first { openItem(first) }
        return saved
    }

    // MARK: Voice

    /// Speaks `text` into an audio file in the gallery; optionally plays it through the speakers as well.
    public func speak(_ text: String, voiceID: String? = nil, rate: Float? = nil, play: Bool = false) async throws -> (item: MediaItem, duration: Double) {
        busy = "Speaking…"
        defer { busy = nil }
        let staged = try gallery.stagingURL(fileExtension: "caf")
        let result: SpeechFileSynthesizer.Result
        do { result = try await speech.synthesize(text, voiceID: voiceID, rate: rate, to: staged) }
        catch { try? FileManager.default.removeItem(at: staged); throw error }
        let item = try gallery.adopt(fileAt: staged, kind: .audio, title: String(text.prefix(60)), origin: .speech, prompt: text, provider: "avspeech:\(result.voiceName)")
        reloadGallery()
        openItem(item)
        if play { try? speech.speakAloud(text, voiceID: voiceID, rate: rate) }
        return (item, result.duration)
    }

    public func transcribe(_ url: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.fileMissing(url.path) }
        busy = "Transcribing…"
        defer { busy = nil }
        let text = try await AudioTranscriber.transcribe(fileAt: url)
        lastTranscript = text
        return text
    }

    public func setMessage(_ text: String?) { message = text }
}
