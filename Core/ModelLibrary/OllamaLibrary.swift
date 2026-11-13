import Foundation

/// One model installed in the local Ollama server, from `GET /api/tags`.
public struct OllamaInstalledModel: Equatable, Sendable, Identifiable {
    public var name: String
    public var sizeBytes: Int64
    public var modified: Date?
    public var parameterSize: String?
    public var quantization: String?
    public var family: String?
    public var id: String { name }
}

/// A model the server has loaded in memory right now (`GET /api/ps`).
public struct OllamaRunningModel: Equatable, Sendable, Identifiable {
    public var name: String
    public var sizeBytes: Int64
    public var id: String { name }
}

/// One progress event from `POST /api/pull`.
public struct OllamaPullProgress: Equatable, Sendable {
    public var status: String
    public var digest: String?
    public var total: Int64?
    public var completed: Int64?
    /// 0...1 for the layer being fetched, nil when the server gave no sizes (for example "verifying sha256 digest").
    public var fraction: Double? {
        guard let total, total > 0, let completed else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

public enum OllamaLibraryError: Error, Equatable, LocalizedError {
    case invalidName(String)
    case notRunning(String)
    case notEnoughSpace(needed: Int64, free: Int64)
    case server(String)
    case notInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let m): "That is not a valid Ollama model name: \(m)"
        case .notRunning(let url): "Ollama is not running at \(url). Start the Ollama app (or run `ollama serve`) and try again. Kiln does not start it for you."
        case .notEnoughSpace(let needed, let free): "Not enough disk space: the download needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) and only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) is free (Kiln keeps a 2 GB margin). Nothing was downloaded."
        case .server(let m): "Ollama answered with an error: \(m)"
        case .notInstalled(let name): "No installed model is named \(name)."
        }
    }
}

/// Installing, listing and removing models in a local Ollama server through its own HTTP API (https://github.com/ollama/ollama/blob/main/docs/api.md).
/// Kiln never starts Ollama. A pull streams newline-delimited JSON; Ollama resumes partial layers itself when a pull is repeated.
public struct OllamaLibrary: Sendable {
    public let baseURL: URL
    let session: URLSession
    /// Free bytes on the volume that holds the models; injectable so tests can simulate a full disk.
    let freeSpace: @Sendable () -> Int64
    /// Room Kiln leaves free on top of a download.
    public static let safetyMargin: Int64 = 2 * 1024 * 1024 * 1024
    public static let userAgent = "Kiln (https://github.com/noktirnal42/Kiln)"

    public init(baseURL: URL = URL(string: "http://localhost:11434")!, session: URLSession = .shared,
                freeSpace: @escaping @Sendable () -> Int64 = OllamaLibrary.defaultFreeSpace) {
        self.baseURL = baseURL; self.session = session; self.freeSpace = freeSpace
    }

    public static func defaultFreeSpace() -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    /// Letters, digits and `. _ - : /` only (so `hf.co/user/repo:Q4_K_M`, `llama3.2:3b` and `library/phi3` pass); no spaces, no leading dash or slash, at most 200 characters.
    public static func validate(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { throw OllamaLibraryError.invalidName("it must be 1 to 200 characters") }
        guard let first = trimmed.first, first.isLetter || first.isNumber else { throw OllamaLibraryError.invalidName("it must start with a letter or digit") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:/")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { throw OllamaLibraryError.invalidName("only letters, digits and . _ - : / are allowed") }
        guard !trimmed.contains("..") else { throw OllamaLibraryError.invalidName("it must not contain ..") }
        return trimmed
    }

    // MARK: Reading

    public func installed() async throws -> [OllamaInstalledModel] {
        let object = try await get("api/tags")
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        return (object["models"] as? [[String: Any]] ?? []).compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let details = item["details"] as? [String: Any]
            let when = (item["modified_at"] as? String).flatMap { formatter.date(from: $0) ?? plain.date(from: $0) }
            return OllamaInstalledModel(name: name, sizeBytes: (item["size"] as? NSNumber)?.int64Value ?? 0, modified: when,
                                        parameterSize: details?["parameter_size"] as? String, quantization: details?["quantization_level"] as? String,
                                        family: details?["family"] as? String)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func running() async throws -> [OllamaRunningModel] {
        let object = try await get("api/ps")
        return (object["models"] as? [[String: Any]] ?? []).compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return OllamaRunningModel(name: name, sizeBytes: (item["size"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: Changing

    /// Pulls a model, yielding progress. Before any layer is fetched the first sized event is checked against free disk space; a pull that would
    /// not fit is cancelled and refused. Cancelling the consuming task cancels the request.
    public func pull(_ model: String) -> AsyncThrowingStream<OllamaPullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let name = try Self.validate(model)
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"), timeoutInterval: 3600)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                    request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do { (bytes, response) = try await session.bytes(for: request) } catch { throw OllamaLibraryError.notRunning(baseURL.absoluteString) }
                    guard let http = response as? HTTPURLResponse else { throw OllamaLibraryError.server("no response") }
                    guard (200..<300).contains(http.statusCode) else { throw OllamaLibraryError.server("HTTP \(http.statusCode)") }
                    var checkedSpace = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let message = object["error"] as? String { throw OllamaLibraryError.server(message) }
                        let progress = OllamaPullProgress(status: object["status"] as? String ?? "", digest: object["digest"] as? String,
                                                          total: (object["total"] as? NSNumber)?.int64Value, completed: (object["completed"] as? NSNumber)?.int64Value)
                        if !checkedSpace, let total = progress.total, total > 0 {
                            checkedSpace = true
                            let free = freeSpace()
                            if total + Self.safetyMargin > free { throw OllamaLibraryError.notEnoughSpace(needed: total, free: free) }
                        }
                        continuation.yield(progress)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Removes an installed model through Ollama (`DELETE /api/delete`). The name must match an installed model exactly.
    public func delete(_ model: String) async throws {
        let name = try Self.validate(model)
        guard try await installed().contains(where: { $0.name == name }) else { throw OllamaLibraryError.notInstalled(name) }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/delete"), timeoutInterval: 60)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name])
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw OllamaLibraryError.notRunning(baseURL.absoluteString) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw OllamaLibraryError.server(message ?? "HTTP \(status)")
        }
    }

    private func get(_ path: String) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 10)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw OllamaLibraryError.notRunning(baseURL.absoluteString) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw OllamaLibraryError.server("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
