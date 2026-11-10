import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// History, prompt library, upscaling and outpaint preparation: the parts of the studio that are not an engine.

// MARK: - History

public struct ImageHistoryItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let record: GenerationRecord?
    public var createdAt: Date { record?.createdAt ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
}

/// Every picture the studio makes, as a PNG that carries its own settings. The folder is the source of truth:
/// there is no separate index to lose, and a PNG copied in from elsewhere with Kiln metadata shows up too.
public final class ImageHistory: @unchecked Sendable {
    public static let `default` = ImageHistory(root: AgentPaths.supportDirectory.appendingPathComponent("ImageStudio", isDirectory: true))

    public let root: URL
    private let lock = NSLock()
    public init(root: URL) { self.root = root }

    public var directory: URL { root.appendingPathComponent("History", isDirectory: true) }
    public var stagingDirectory: URL { root.appendingPathComponent("Staging", isDirectory: true) }

    @discardableResult
    public func add(png: Data, record: GenerationRecord) throws -> ImageHistoryItem {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let url = directory.appendingPathComponent("\(id.uuidString).png")
        try GenerationMetadata.embed(record, in: png).write(to: url, options: .atomic)
        return ImageHistoryItem(id: id, url: url, record: record)
    }

    /// Newest first.
    public func items(limit: Int = 500) -> [ImageHistoryItem] {
        lock.lock(); defer { lock.unlock() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let items = names.filter { $0.lowercased().hasSuffix(".png") }.compactMap { name -> ImageHistoryItem? in
            let url = directory.appendingPathComponent(name)
            guard let id = UUID(uuidString: (name as NSString).deletingPathExtension) else { return nil }
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            return ImageHistoryItem(id: id, url: url, record: data.flatMap(GenerationMetadata.read(from:)))
        }
        return Array(items.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    public func item(id: UUID) -> ImageHistoryItem? { items().first { $0.id == id } }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let url = directory.appendingPathComponent("\(id.uuidString).png")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    func stagingURL(_ ext: String = "png") throws -> URL {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        return stagingDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }
}

// MARK: - Prompts and styles

public struct PromptStyle: Codable, Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    /// `{prompt}` is replaced by the user's prompt; without it the text is appended.
    public var prompt: String
    public var negative: String
    public init(name: String, prompt: String, negative: String = "") { self.name = name; self.prompt = prompt; self.negative = negative }

    public func apply(to text: String, negative existing: String) -> (prompt: String, negative: String) {
        let merged = prompt.contains("{prompt}") ? prompt.replacingOccurrences(of: "{prompt}", with: text) : [text, prompt].filter { !$0.isEmpty }.joined(separator: ", ")
        return (merged, [existing, negative].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

public struct SavedPrompt: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var prompt: String
    public var negative: String = ""
    public init(title: String, prompt: String, negative: String = "") { self.title = title; self.prompt = prompt; self.negative = negative }
}

public final class PromptLibrary: @unchecked Sendable {
    public static let builtInStyles: [PromptStyle] = [
        PromptStyle(name: "Photo", prompt: "{prompt}, photograph, natural light, sharp focus, 35mm", negative: "painting, drawing, illustration, blurry"),
        PromptStyle(name: "Cinematic", prompt: "{prompt}, cinematic still, dramatic lighting, shallow depth of field, film grain", negative: "flat lighting, cartoon"),
        PromptStyle(name: "Anime", prompt: "{prompt}, anime style, clean line art, vibrant colors", negative: "photo, realistic, 3d render"),
        PromptStyle(name: "Watercolor", prompt: "{prompt}, watercolor painting, soft washes, paper texture", negative: "photo, sharp edges"),
        PromptStyle(name: "Pixel art", prompt: "{prompt}, pixel art, 16-bit, limited palette", negative: "blurry, smooth gradients"),
        PromptStyle(name: "Line drawing", prompt: "{prompt}, black ink line drawing, white background", negative: "color, shading"),
        PromptStyle(name: "3D render", prompt: "{prompt}, 3d render, octane, soft studio lighting", negative: "flat, sketch"),
        PromptStyle(name: "Isometric", prompt: "{prompt}, isometric illustration, clean vector shapes", negative: "perspective distortion"),
    ]

    private struct Store: Codable { var prompts: [SavedPrompt] = []; var styles: [PromptStyle] = [] }
    private let url: URL
    private let lock = NSLock()
    public init(root: URL) { url = root.appendingPathComponent("prompts.json") }
    public static let `default` = PromptLibrary(root: AgentPaths.supportDirectory.appendingPathComponent("ImageStudio", isDirectory: true))

    private func load() -> Store { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store() }
    private func save(_ store: Store) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(store).write(to: url, options: .atomic)
    }

    public func savedPrompts() -> [SavedPrompt] { lock.lock(); defer { lock.unlock() }; return load().prompts }
    public func styles() -> [PromptStyle] { lock.lock(); defer { lock.unlock() }; return Self.builtInStyles + load().styles }

    public func add(_ prompt: SavedPrompt) throws { lock.lock(); defer { lock.unlock() }; var s = load(); s.prompts.append(prompt); try save(s) }
    public func removePrompt(id: UUID) throws { lock.lock(); defer { lock.unlock() }; var s = load(); s.prompts.removeAll { $0.id == id }; try save(s) }
    public func add(_ style: PromptStyle) throws {
        lock.lock(); defer { lock.unlock() }
        var s = load(); s.styles.removeAll { $0.name == style.name }; s.styles.append(style); try save(s)
    }
}

// MARK: - Upscale and outpaint canvas

public enum ImageResampler {
    /// Lanczos resampling through Core Image. It makes a bigger picture, not a sharper one: say so wherever it is offered.
    public static func upscale(_ png: Data, factor: Double) throws -> Data {
        guard factor > 1, factor <= 8 else { throw ImageStudioError.invalid("The upscale factor must be between 1 and 8.") }
        guard let input = CIImage(data: png) else { throw ImageStudioError.invalid("That is not an image.") }
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(factor, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage else { throw ImageStudioError.failed("Upscaling failed.") }
        let context = CIContext()
        guard let cg = context.createCGImage(output, from: output.extent) else { throw ImageStudioError.failed("Upscaling failed.") }
        return try encodePNG(cg)
    }

    public static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ImageStudioError.failed("Cannot encode PNG.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageStudioError.failed("Cannot encode PNG.") }
        return data as Data
    }

    public static func size(of png: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// A larger canvas holding the source image, and a mask that is white where new content must be made.
    /// Canvas sides are rounded up to a multiple of 8, with the extra going to the right and bottom.
    public static func outpaintCanvas(source: CGImage, padding: OutpaintPadding) throws -> (canvas: Data, mask: Data, width: Int, height: Int) {
        let l = max(0, padding.left), r = max(0, padding.right), t = max(0, padding.top), b = max(0, padding.bottom)
        let width = (source.width + l + r + 7) / 8 * 8, height = (source.height + t + b + 7) / 8 * 8
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func context() throws -> CGContext {
            guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ImageStudioError.failed("Cannot make the canvas.") }
            return c
        }
        let canvas = try context()
        canvas.setFillColor(CGColor(gray: 0.5, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CoreGraphics' origin is bottom-left: the top padding is the space above the picture.
        let origin = CGRect(x: l, y: height - t - source.height, width: source.width, height: source.height)
        canvas.draw(source, in: origin)
        let mask = try context()
        mask.setFillColor(CGColor(gray: 1, alpha: 1)); mask.fill(CGRect(x: 0, y: 0, width: width, height: height))
        mask.setFillColor(CGColor(gray: 0, alpha: 1))
        // Keep a few pixels of the original repaintable so the seam blends.
        let inset: CGFloat = 4
        mask.fill(origin.insetBy(dx: l > 0 || r > 0 ? inset : 0, dy: t > 0 || b > 0 ? inset : 0))
        guard let canvasImage = canvas.makeImage(), let maskImage = mask.makeImage() else { throw ImageStudioError.failed("Cannot make the canvas.") }
        return (try encodePNG(canvasImage), try encodePNG(maskImage), width, height)
    }
}

// MARK: - Queue

public struct ImageQueueJob: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case queued, running, done([UUID]), failed(String), cancelled }
    public let id: UUID
    public var request: ImageGenerationRequest
    public var state: State = .queued
    public var phase: String = ""
    public var fraction: Double = 0
}

/// Runs generation requests one at a time, in order; each can be cancelled while queued or running.
public actor ImageJobQueue {
    public typealias Runner = @Sendable (ImageGenerationRequest, @escaping ImageProgressHandler) async throws -> [UUID]
    private let runner: Runner
    private var jobs: [ImageQueueJob] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var running = false
    private var observer: (@Sendable (ImageQueueJob) -> Void)?

    public init(runner: @escaping Runner) { self.runner = runner }
    public func setObserver(_ observer: (@Sendable (ImageQueueJob) -> Void)?) { self.observer = observer }
    public func snapshot() -> [ImageQueueJob] { jobs }

    @discardableResult
    public func enqueue(_ request: ImageGenerationRequest) -> UUID {
        let job = ImageQueueJob(id: UUID(), request: request)
        jobs.append(job); observer?(job); pump()
        return job.id
    }

    public func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[index].state == .queued { jobs[index].state = .cancelled; observer?(jobs[index]) }
        else if jobs[index].state == .running { tasks[id]?.cancel() }
    }

    public func clearFinished() { jobs.removeAll { if case .queued = $0.state { false } else if case .running = $0.state { false } else { true } } }

    public func waitUntilIdle() async {
        while running || jobs.contains(where: { $0.state == .queued }) { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func set(_ id: UUID, _ change: (inout ImageQueueJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index]); observer?(jobs[index])
    }

    private func pump() {
        guard !running, let next = jobs.first(where: { $0.state == .queued }) else { return }
        running = true
        set(next.id) { $0.state = .running }
        let id = next.id, request = next.request
        tasks[id] = Task { [self] in
            do {
                let ids = try await runner(request) { progress in
                    Task { await self.set(id) { $0.phase = progress.phase; if let f = progress.fraction { $0.fraction = f } } }
                }
                set(id) { $0.state = .done(ids); $0.fraction = 1 }
            } catch is CancellationError {
                set(id) { $0.state = .cancelled }
            } catch {
                set(id) { $0.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            }
            tasks[id] = nil; running = false; pump()
        }
    }
}
