import Foundation

public struct ModelSearchResult: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let downloads: Int?
    public let likes: Int?
    public let pipelineTag: String?
    public let libraryName: String?
    public let tags: [String]
    public let sourceURL: URL

    public init(
        id: String,
        name: String,
        downloads: Int?,
        likes: Int?,
        pipelineTag: String?,
        libraryName: String?,
        tags: [String],
        sourceURL: URL
    ) {
        self.id = id
        self.name = name
        self.downloads = downloads
        self.likes = likes
        self.pipelineTag = pipelineTag
        self.libraryName = libraryName
        self.tags = tags
        self.sourceURL = sourceURL
    }
}

public struct ModelFileInfo: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let sizeBytes: Int64?
    public let downloadURL: URL
}

public struct ModelDetails: Sendable {
    public let id: String
    public let name: String
    public let downloads: Int?
    public let likes: Int?
    public let pipelineTag: String?
    public let libraryName: String?
    public let license: String?
    public let tags: [String]
    public let files: [ModelFileInfo]
    public let sourceURL: URL

    public var isLikelyMLXCompatible: Bool {
        let lowerTags = tags.map { $0.lowercased() }
        let hasConfig = files.contains { $0.path == "config.json" }
        let hasTokenizer = files.contains { $0.path.contains("tokenizer") }
        let hasWeights = files.contains { $0.path.hasSuffix(".safetensors") || $0.path.hasSuffix(".gguf") }
        let isTextGeneration = pipelineTag == nil || pipelineTag == "text-generation"
        let hasMLXSignal = lowerTags.contains { $0.contains("mlx") || $0.contains("safetensors") }
        return isTextGeneration && hasConfig && hasTokenizer && hasWeights && (libraryName == nil || libraryName != "gguf") || hasMLXSignal
    }
}

public protocol ModelProvider: Sendable {
    var name: String { get }
    func capability() -> CapabilityStatus
    func search(query: String) async throws -> [ModelSearchResult]
    func fetchDetails(id: String) async throws -> ModelDetails
}

/// Public Hugging Face model browsing. This intentionally registers model
/// repositories as MLX references; MLX performs the actual snapshot caching
/// when the user runs the model, which avoids half-downloaded model folders.
public struct HuggingFaceModelProvider: ModelProvider {
    public let name = "Hugging Face Models"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func capability() -> CapabilityStatus {
        .available
    }

    public func search(query: String) async throws -> [ModelSearchResult] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "full", value: "false")
        ]
        let (data, response) = try await session.data(from: components.url!)
        try Self.validate(response)
        let raw = try JSONDecoder().decode([HFModelSummary].self, from: data)
        return raw.map {
            ModelSearchResult(
                id: $0.id,
                name: $0.id,
                downloads: $0.downloads,
                likes: $0.likes,
                pipelineTag: $0.pipelineTag,
                libraryName: $0.libraryName,
                tags: $0.tags ?? [],
                sourceURL: URL(string: "https://huggingface.co/\($0.id)")!
            )
        }
    }

    public func fetchDetails(id: String) async throws -> ModelDetails {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = URL(string: "https://huggingface.co/api/models/\(encoded)")!
        let (data, response) = try await session.data(from: url)
        try Self.validate(response)
        let detail = try JSONDecoder().decode(HFModelDetail.self, from: data)
        let files = (detail.siblings ?? []).map { sibling in
            ModelFileInfo(
                path: sibling.rfilename,
                sizeBytes: sibling.size,
                downloadURL: URL(string: "https://huggingface.co/\(id)/resolve/main/\(sibling.rfilename)")!
            )
        }
        return ModelDetails(
            id: detail.id,
            name: detail.id,
            downloads: detail.downloads,
            likes: detail.likes,
            pipelineTag: detail.pipelineTag,
            libraryName: detail.libraryName,
            license: detail.cardData?.license?.joined(separator: ", "),
            tags: detail.tags ?? [],
            files: files,
            sourceURL: URL(string: "https://huggingface.co/\(detail.id)")!
        )
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw DatasetProviderError.httpError(status: http.statusCode)
        }
    }
}

private struct HFModelSummary: Decodable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let pipelineTag: String?
    let libraryName: String?
    let tags: [String]?

    private enum CodingKeys: String, CodingKey {
        case id
        case downloads
        case likes
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
        case tags
    }
}

private struct HFModelDetail: Decodable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let pipelineTag: String?
    let libraryName: String?
    let tags: [String]?
    let siblings: [HFModelSibling]?
    let cardData: HFModelCardData?

    private enum CodingKeys: String, CodingKey {
        case id
        case downloads
        case likes
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
        case tags
        case siblings
        case cardData
    }
}

private struct HFModelSibling: Decodable {
    let rfilename: String
    let size: Int64?
}

private struct HFModelCardData: Decodable {
    let license: [String]?

    private enum CodingKeys: String, CodingKey { case license }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let single = try? container.decode(String.self, forKey: .license) {
            license = [single]
        } else {
            license = try container.decodeIfPresent([String].self, forKey: .license)
        }
    }
}
