import AppKit
import Foundation
import Observation
import SwiftUI

/// Image studio: generate, edit and upscale pictures with models that run on this Mac or in a local engine, and download
/// the models. Everything here is also an agent and MCP tool (`image_*`).
@MainActor
@Observable
public final class ImageStudioModule: @preconcurrency Module, ModuleDefinition, ModuleUI {
    public nonisolated static let identifier = "com.kiln.imagestudio"
    public nonisolated static let displayName = "Images"
    public nonisolated static let version = "1.0.0"
    public nonisolated static let dependencies: [String] = []
    public nonisolated static let requiredCapabilities: ModuleCapabilities = [.fileSystemRead, .fileSystemWrite, .networkClient]

    public enum CatalogSource: String, CaseIterable, Identifiable, Sendable {
        case curated = "Curated", drawThings = "Draw Things", huggingFace = "Hugging Face", civitai = "Civitai"
        public var id: String { rawValue }
    }

    @ObservationIgnored public nonisolated let service: ImageStudioService
    public private(set) var reports: [EngineReport] = []
    public private(set) var history: [ImageHistoryItem] = []
    public private(set) var downloads: [DownloadJob] = []
    public private(set) var queue: [ImageQueueJob] = []
    public private(set) var catalogRows: [ImageModelEntry] = []
    public private(set) var catalogBusy = false
    public private(set) var catalogMessage: String?
    public private(set) var installedIDs: Set<String> = []
    public var selected: ImageHistoryItem?
    public var message: String?
    /// The settings the inspector edits. "Use as reference" and "Re-run" write into it.
    public var draft = ImageGenerationRequest(prompt: "", model: "")
    public var selectedStyles: Set<String> = []
    /// Bumped when the agent generates something, so the window can switch to Images.
    public private(set) var openRequests = 0
    @ObservationIgnored private var jobQueue: ImageJobQueue?
    @ObservationIgnored private var started = false

    public nonisolated init() { self.service = ImageStudioService.makeDefault() }

    public func initialize(context: ModuleContext) async throws { context.logger.info("Image studio initialized") }
    public func activate() async throws { await start(); await refresh() }
    public func deactivate() async throws {}
    public func shutdown() async throws {}
    public func makeRootView() -> AnyView { AnyView(ImageStudioRootView(module: self)) }

    func start() async {
        guard !started else { return }
        started = true
        let service = self.service
        let queue = ImageJobQueue { request, progress in try await service.generate(request, progress: progress).map(\.id) }
        jobQueue = queue
        await queue.setObserver { [weak self] job in Task { @MainActor in self?.apply(job) } }
        await service.downloader.setObserver { [weak self] job in Task { @MainActor in self?.apply(job) } }
    }

    private func apply(_ job: ImageQueueJob) {
        if let index = queue.firstIndex(where: { $0.id == job.id }) { queue[index] = job } else { queue.append(job) }
        if case .done = job.state { reloadHistory(); selected = history.first }
        if case .failed(let why) = job.state { message = why }
    }

    private func apply(_ job: DownloadJob) {
        if let index = downloads.firstIndex(where: { $0.id == job.id }) { downloads[index] = job } else { downloads.append(job) }
        if job.state == .finished { refreshInstalled() }
        if case .failed(let why) = job.state { catalogMessage = "\(job.title): \(why)" }
    }

    // MARK: Refreshing

    public func refresh() async {
        reports = await service.reports()
        reloadHistory()
        refreshInstalled()
        if catalogRows.isEmpty { catalogRows = CuratedImageCatalog.entries }
        if draft.model.isEmpty, let first = reports.first(where: { $0.status.isReady && !$0.models.isEmpty }) {
            draft.model = first.models.first { $0.kind == .checkpoint }?.id ?? ""
            draft.engine = first.id
            applyModelDefaults()
        }
    }

    public func reloadHistory() { history = service.history.items() }

    func refreshInstalled() {
        let store = service.store
        let rows = catalogRows
        Task.detached {
            let ids = Set(rows.filter { store.isInstalled($0, folder: nil) || ImageStudioModule.isInstalledInFolder($0, store: store) }.map(\.id))
            await MainActor.run { self.installedIDs = ids }
        }
    }

    nonisolated static func isInstalledInFolder(_ entry: ImageModelEntry, store: ImageModelStore) -> Bool {
        for tool in ExternalModelFolders.Tool.allCases {
            if let folder = ExternalModelFolders.folder(for: tool), store.isInstalled(entry, folder: folder) { return true }
        }
        return false
    }

    /// Picks the sensible steps, guidance and size for the chosen model when the catalogue knows it.
    public func applyModelDefaults() {
        let id = draft.model.lowercased()
        if let entry = CuratedImageCatalog.entries.first(where: { if case .huggingFace(let repo, _, _) = $0.source { repo.lowercased() == id } else { false } }) {
            draft.steps = entry.defaultSteps; draft.guidance = entry.defaultGuidance
            draft.width = min(entry.nativeSide, 1024); draft.height = min(entry.nativeSide, 1024)
        } else if id.contains("turbo") || id.contains("lightning") {
            draft.steps = 4; draft.guidance = 0
        }
    }

    // MARK: Generating

    public var capabilities: ImageEngineCapabilities? {
        let engine = draft.engine.flatMap { id in reports.first { $0.id == id } } ?? reports.first { $0.status.isReady }
        return engine?.capabilities
    }

    @discardableResult
    public func enqueue(_ request: ImageGenerationRequest) async -> UUID? {
        await start()
        var run = request
        service.applyStyles(Array(selectedStyles).sorted(), to: &run)
        message = nil
        return await jobQueue?.enqueue(run)
    }

    public func cancel(_ id: UUID) { Task { await jobQueue?.cancel(id) } }
    public func clearFinishedJobs() { Task { await jobQueue?.clearFinished(); queue = await jobQueue?.snapshot() ?? [] } }

    /// Agent entry: runs now (not through the visible queue's ordering) and shows the result.
    func generateForAgent(_ request: ImageGenerationRequest) async throws -> [ImageHistoryItem] {
        let items = try await service.generate(request)
        reloadHistory(); selected = items.first; openRequests += 1
        return items
    }

    public func rerun(_ item: ImageHistoryItem) async {
        guard let record = item.record else { message = "That picture has no embedded settings."; return }
        draft = record.rerunRequest
        _ = await enqueue(draft)
    }

    /// Loads a picture's settings into the inspector without running it.
    public func loadSettings(from item: ImageHistoryItem) {
        guard let record = item.record else { message = "That picture has no embedded settings."; return }
        draft = record.request; draft.seed = record.seed
    }

    public func useAsReference(_ item: ImageHistoryItem) {
        draft.initImagePath = item.url.path
        if draft.task == .textToImage { draft.task = .imageToImage }
    }

    public func upscale(_ item: ImageHistoryItem, factor: Double) {
        do { let made = try service.upscale(path: item.url.path, factor: factor); reloadHistory(); selected = made }
        catch { message = error.localizedDescription }
    }

    public func sendToMedia(_ item: ImageHistoryItem) {
        do { _ = try service.sendToMedia(item); message = "Added to the Media gallery." }
        catch { message = error.localizedDescription }
    }

    public func delete(_ item: ImageHistoryItem) {
        service.history.remove(id: item.id)
        if selected?.id == item.id { selected = nil }
        reloadHistory()
    }

    // MARK: Models

    public func showCatalog(_ source: CatalogSource, query: String) async {
        catalogBusy = true; catalogMessage = nil
        defer { catalogBusy = false }
        let keychain = KeychainService()
        do {
            switch source {
            case .curated: catalogRows = CuratedImageCatalog.entries
            case .drawThings:
                let all = try await DrawThingsCatalog.fetch()
                catalogRows = query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
            case .huggingFace:
                guard !query.isEmpty else { catalogMessage = "Type a search above."; return }
                catalogRows = try await HuggingFaceImageSearch.search(query, token: keychain.secretProvider(module: providersKeychainModule, key: "huggingface"))
            case .civitai:
                guard !query.isEmpty else { catalogMessage = "Type a search above."; return }
                catalogRows = try await CivitaiSearch.search(query, token: keychain.secretProvider(module: providersKeychainModule, key: "civitai"))
            }
            if catalogRows.isEmpty { catalogMessage = "Nothing found." }
        } catch { catalogMessage = error.localizedDescription }
        refreshInstalled()
    }

    public func download(_ entry: ImageModelEntry) async {
        do {
            let destination = try service.destination(for: entry)
            _ = await service.downloader.enqueue(entry, to: destination)
        } catch { catalogMessage = error.localizedDescription }
    }

    public func cancelDownload(_ id: UUID) { Task { await service.downloader.cancel(id) } }
}
