import Foundation

public struct DatasetSearchResult: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let summary: String?
    public let downloads: Int?
    public let likes: Int?
    public let tags: [String]
    public let sourceURL: URL

    public init(id: String, name: String, summary: String?, downloads: Int?, likes: Int?, tags: [String], sourceURL: URL) {
        self.id = id
        self.name = name
        self.summary = summary
        self.downloads = downloads
        self.likes = likes
        self.tags = tags
        self.sourceURL = sourceURL
    }
}

public struct DatasetFileInfo: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let sizeBytes: Int64?
    public let downloadURL: URL
}

public struct DatasetDetails: Sendable {
    public let id: String
    public let name: String
    public let summary: String?
    public let license: String?
    public let tags: [String]
    public let files: [DatasetFileInfo]
    public let sourceURL: URL
}

public protocol DatasetProvider: Sendable {
    var name: String { get }
    func capability() -> CapabilityStatus
    func search(query: String) async throws -> [DatasetSearchResult]
    func fetchDetails(id: String) async throws -> DatasetDetails
}

/// Talks to the public Hugging Face Datasets API. No authentication is used
/// or required for browsing/searching public datasets; downloading an
/// individual file goes through `resolve/main/<path>` URLs that
/// `DownloadManager` fetches directly.
public struct HuggingFaceDatasetProvider: DatasetProvider {
    public let name = "Hugging Face Datasets"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func capability() -> CapabilityStatus {
        .available
    }

    public func search(query: String) async throws -> [DatasetSearchResult] {
        var components = URLComponents(string: "https://huggingface.co/api/datasets")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "full", value: "false")
        ]
        let (data, response) = try await session.data(from: components.url!)
        try Self.validate(response)
        let raw = try JSONDecoder().decode([HFDatasetSummary].self, from: data)
        return raw.map {
            DatasetSearchResult(
                id: $0.id,
                name: $0.id,
                summary: $0.description,
                downloads: $0.downloads,
                likes: $0.likes,
                tags: $0.tags ?? [],
                sourceURL: URL(string: "https://huggingface.co/datasets/\($0.id)")!
            )
        }
    }

    public func fetchDetails(id: String) async throws -> DatasetDetails {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = URL(string: "https://huggingface.co/api/datasets/\(encoded)")!
        let (data, response) = try await session.data(from: url)
        try Self.validate(response)
        let detail = try JSONDecoder().decode(HFDatasetDetail.self, from: data)
        let files = (detail.siblings ?? []).map { sibling in
            DatasetFileInfo(
                path: sibling.rfilename,
                sizeBytes: nil,
                downloadURL: URL(string: "https://huggingface.co/datasets/\(id)/resolve/main/\(sibling.rfilename)")!
            )
        }
        return DatasetDetails(
            id: detail.id,
            name: detail.id,
            summary: detail.description,
            license: detail.cardData?.license?.joined(separator: ", "),
            tags: detail.tags ?? [],
            files: files,
            sourceURL: URL(string: "https://huggingface.co/datasets/\(id)")!
        )
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw DatasetProviderError.httpError(status: http.statusCode)
        }
    }
}

public enum DatasetProviderError: LocalizedError {
    case httpError(status: Int)
    case unsupportedFileType(String)
    case emptyFile

    public var errorDescription: String? {
        switch self {
        case .httpError(let status): "Hugging Face API returned HTTP \(status)."
        case .unsupportedFileType(let ext): "Unsupported dataset file type: .\(ext)"
        case .emptyFile: "The file has no rows to preview."
        }
    }
}

private struct HFDatasetSummary: Decodable {
    let id: String
    let description: String?
    let downloads: Int?
    let likes: Int?
    let tags: [String]?
}

private struct HFDatasetDetail: Decodable {
    let id: String
    let description: String?
    let tags: [String]?
    let siblings: [HFSibling]?
    let cardData: HFCardData?
}

private struct HFSibling: Decodable {
    let rfilename: String
}

private struct HFCardData: Decodable {
    let license: [String]?

    private enum CodingKeys: String, CodingKey { case license }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Hugging Face's `license` card field is a single string on some
        // datasets and an array of strings on others; accept both.
        if let single = try? container.decode(String.self, forKey: .license) {
            license = [single]
        } else {
            license = try container.decodeIfPresent([String].self, forKey: .license)
        }
    }
}
