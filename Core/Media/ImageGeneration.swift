import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(ImagePlayground)
import ImagePlayground
#endif

public struct GeneratedImage: Sendable {
    public let data: Data
    public let fileExtension: String
    public init(data: Data, fileExtension: String = "png") { self.data = data; self.fileExtension = fileExtension }
}

public enum ImageProviderAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

/// Something that can turn a prompt into pictures. Real providers only: a provider that cannot produce an image says so.
public protocol ImageGenerationProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func availability() async -> ImageProviderAvailability
    func generate(prompt: String, count: Int) async throws -> [GeneratedImage]
}

/// Chooses the provider for a request: the named one when it is usable, otherwise the first usable one in order.
public struct ImageProviderSelector: Sendable {
    public let providers: [any ImageGenerationProvider]
    public init(providers: [any ImageGenerationProvider]) { self.providers = providers }

    public struct Status: Sendable, Equatable { public let id: String; public let name: String; public let availability: ImageProviderAvailability }

    public func statuses() async -> [Status] {
        var list: [Status] = []
        for provider in providers {
            list.append(Status(id: provider.id, name: provider.displayName, availability: await provider.availability()))
        }
        return list
    }

    /// Throws `MediaError.noImageProvider` with every provider's reason when nothing is usable.
    public func select(preferredID: String? = nil) async throws -> any ImageGenerationProvider {
        var reasons: [String] = []
        if let preferredID, !preferredID.isEmpty {
            guard let named = providers.first(where: { $0.id == preferredID }) else {
                let known = providers.map(\.id).joined(separator: ", ")
                throw MediaError.noImageProvider("There is no provider named \"\(preferredID)\". Known providers: \(known.isEmpty ? "none" : known).")
            }
            switch await named.availability() {
            case .available: return named
            case .unavailable(let why): throw MediaError.noImageProvider("\(named.displayName): \(why)")
            }
        }
        for provider in providers {
            switch await provider.availability() {
            case .available: return provider
            case .unavailable(let why): reasons.append("\(provider.displayName): \(why)")
            }
        }
        throw MediaError.noImageProvider(reasons.isEmpty ? "Kiln has no image providers." : reasons.joined(separator: " "))
    }
}

// MARK: - Apple Image Playground

/// On-device generation through Apple's Image Playground, when this Mac has Apple Intelligence and the model.
public struct ApplePlaygroundImageProvider: ImageGenerationProvider {
    public let id = "apple-image-playground"
    public let displayName = "Apple Image Playground"
    public init() {}

    public func availability() async -> ImageProviderAvailability {
        #if canImport(ImagePlayground)
        if #available(macOS 15.4, *) {
            do { _ = try await ImageCreator(); return .available }
            catch { return .unavailable(error.localizedDescription) }
        }
        #endif
        return .unavailable("Image Playground needs macOS 15.4 or later.")
    }

    public func generate(prompt: String, count: Int) async throws -> [GeneratedImage] {
        #if canImport(ImagePlayground)
        if #available(macOS 15.4, *) {
            do {
                let creator = try await ImageCreator()
                guard let style = creator.availableStyles.first else {
                    throw MediaError.providerFailed("Image Playground offers no styles on this Mac.")
                }
                var images: [GeneratedImage] = []
                for try await created in creator.images(for: [.text(prompt)], style: style, limit: max(1, min(count, 4))) {
                    guard let data = Self.pngData(created.cgImage) else { throw MediaError.providerFailed("The image could not be encoded.") }
                    images.append(GeneratedImage(data: data))
                }
                guard !images.isEmpty else { throw MediaError.providerFailed("Image Playground returned no images.") }
                return images
            } catch let error as MediaError {
                throw error
            } catch {
                throw MediaError.providerFailed(error.localizedDescription)
            }
        }
        #endif
        throw MediaError.noImageProvider("Image Playground needs macOS 15.4 or later.")
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

// MARK: - OpenAI-compatible /images/generations

/// The user's configured custom endpoint, when it serves `POST {base}/images/generations` (OpenAI's shape; many gateways do).
/// Needs a base URL and an image model name; the key comes from the same Keychain item as the custom chat endpoint.
public struct OpenAICompatibleImageProvider: ImageGenerationProvider {
    public let id = "custom-endpoint-images"
    public let displayName = "Custom endpoint (images)"
    private let baseURL: String
    private let model: String
    private let secret: SecretProvider?
    private let session: URLSession

    public init(baseURL: String, model: String, secretProvider: SecretProvider? = nil, session: URLSession = ProviderSessions.shared) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n"))
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secretProvider
        self.session = session
    }

    public func availability() async -> ImageProviderAvailability {
        if baseURL.isEmpty { return .unavailable("Set a custom endpoint in Settings → Providers.") }
        if model.isEmpty { return .unavailable("Name an image model for the custom endpoint (Media → Image → Model).") }
        return .available
    }

    public func generate(prompt: String, count: Int) async throws -> [GeneratedImage] {
        guard let url = URL(string: "\(baseURL)/images/generations") else { throw MediaError.providerFailed("The endpoint URL is not valid.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = secret?(), !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = ["model": model, "prompt": prompt, "n": max(1, min(count, 4)), "response_format": "b64_json"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MediaError.providerFailed("No HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            throw MediaError.providerFailed("The endpoint answered \(http.statusCode): \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
        }
        return try await decode(data)
    }

    func decode(_ data: Data) async throws -> [GeneratedImage] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]], !entries.isEmpty else {
            throw MediaError.providerFailed("The endpoint's answer had no images.")
        }
        var images: [GeneratedImage] = []
        for entry in entries {
            if let b64 = entry["b64_json"] as? String, let bytes = Data(base64Encoded: b64) {
                images.append(GeneratedImage(data: bytes, fileExtension: Self.extensionFor(bytes)))
            } else if let link = entry["url"] as? String, let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) {
                let (bytes, _) = try await session.data(from: url)
                images.append(GeneratedImage(data: bytes, fileExtension: Self.extensionFor(bytes)))
            }
        }
        guard !images.isEmpty else { throw MediaError.providerFailed("The endpoint's answer had no usable images.") }
        return images
    }

    static func extensionFor(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "webp" }
        return "png"
    }
}
