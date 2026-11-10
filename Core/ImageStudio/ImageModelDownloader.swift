import CryptoKit
import Foundation

public struct DownloadFile: Equatable, Sendable {
    public var path: String          // relative path inside the repo / snapshot
    public var url: URL
    public var size: Int64
    /// Hex SHA-256 (Hugging Face LFS oid or a published checksum), when known.
    public var sha256: String?
    /// Git blob SHA-1 for small non-LFS files, when known.
    public var gitSHA1: String?
    public init(path: String, url: URL, size: Int64, sha256: String? = nil, gitSHA1: String? = nil) {
        self.path = path; self.url = url; self.size = size; self.sha256 = sha256; self.gitSHA1 = gitSHA1
    }
}

public enum DownloadDestination: Equatable, Sendable {
    /// The universal model store, Hugging Face cache layout.
    case universalStore
    /// A plain folder (a ComfyUI checkpoints folder, Draw Things' Models).
    case folder(URL)
}

public struct DownloadPlan: Equatable, Sendable {
    public var entryID: String
    public var repo: String          // cache repo name; "kiln/<id>" for non-Hugging-Face files
    public var commit: String
    public var files: [DownloadFile]
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum DownloadState: Equatable, Sendable {
    case queued, resolving, downloading, verifying, finished
    case failed(String)
    case cancelled
}

public struct DownloadJob: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var entryID: String
    public var title: String
    public var state: DownloadState = .queued
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0
    public var currentFile: String?
    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
}

/// Resumable, checksum-verified downloads into the universal model store, one job at a time.
/// Partial files (`*.incomplete`) are kept on cancel or failure and continued with a Range request next time.
public actor ImageModelDownloader {
    public typealias Observer = @Sendable (DownloadJob) -> Void

    private let store: ImageModelStore
    private let session: URLSession
    private let endpoint: URL
    private let huggingFaceToken: SecretProvider
    private let civitaiToken: SecretProvider
    private let freeSpace: @Sendable (URL) -> Int64
    private let margin: Int64
    private var jobs: [UUID: DownloadJob] = [:]
    private var order: [UUID] = []
    private var entries: [UUID: (ImageModelEntry, DownloadDestination)] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var running = false
    private var observer: Observer?

    public init(store: ImageModelStore = ImageModelStore(), session: URLSession = .shared,
                endpoint: URL = URL(string: "https://huggingface.co")!,
                huggingFaceToken: @escaping SecretProvider = { nil }, civitaiToken: @escaping SecretProvider = { nil },
                freeSpace: @escaping @Sendable (URL) -> Int64 = ImageModelDownloader.availableBytes,
                safetyMargin: Int64 = 1_000_000_000) {
        self.store = store; self.session = session; self.endpoint = endpoint
        self.huggingFaceToken = huggingFaceToken; self.civitaiToken = civitaiToken
        self.freeSpace = freeSpace; self.margin = safetyMargin
    }

    public func setObserver(_ observer: Observer?) { self.observer = observer }
    public func snapshot() -> [DownloadJob] { order.compactMap { jobs[$0] } }

    public static func availableBytes(at url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage { return important }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    // MARK: Queue

    @discardableResult
    public func enqueue(_ entry: ImageModelEntry, to destination: DownloadDestination = .universalStore) -> UUID {
        if let existing = order.first(where: { entries[$0]?.0.id == entry.id && [.queued, .resolving, .downloading, .verifying].contains(jobs[$0]?.state ?? .finished) }) {
            return existing
        }
        let id = UUID()
        jobs[id] = DownloadJob(id: id, entryID: entry.id, title: entry.name, bytesTotal: entry.sizeBytes)
        entries[id] = (entry, destination)
        order.append(id)
        publish(id)
        pump()
        return id
    }

    /// Stops a job. Partial files stay so a later enqueue resumes.
    public func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        if jobs[id]?.state == .queued { update(id) { $0.state = .cancelled } }
    }

    public func waitUntilIdle() async {
        while running || order.contains(where: { jobs[$0]?.state == .queued }) { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func pump() {
        guard !running, let next = order.first(where: { jobs[$0]?.state == .queued }) else { return }
        running = true
        let task = Task { [self] in
            await run(next)
            finish(next)
        }
        tasks[next] = task
    }

    private func finish(_ id: UUID) { tasks[id] = nil; running = false; pump() }

    private func update(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        guard var job = jobs[id] else { return }
        change(&job); jobs[id] = job; observer?(job)
    }

    private func publish(_ id: UUID) { if let job = jobs[id] { observer?(job) } }

    // MARK: One job

    private func run(_ id: UUID) async {
        guard let (entry, destination) = entries[id] else { return }
        do {
            update(id) { $0.state = .resolving }
            let plan = try await resolve(entry)
            let root = targetRoot(for: plan, destination: destination)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let have = plan.files.reduce(Int64(0)) { $0 + partialSize(of: $1, in: plan, destination: destination) }
            let needed = plan.totalBytes - have
            let free = freeSpace(root)
            if free < needed + margin { throw ImageStudioError.insufficientSpace(needed: needed + margin, available: free, volume: root.path) }
            update(id) { $0.state = .downloading; $0.bytesTotal = plan.totalBytes }
            var done: Int64 = 0
            for file in plan.files {
                try Task.checkCancellation()
                update(id) { $0.currentFile = file.path }
                let base = done
                try await fetch(file, plan: plan, destination: destination) { received in
                    Task { await self.update(id) { $0.bytesDone = base + received } }
                }
                done += file.size
                update(id) { $0.bytesDone = done }
            }
            if case .universalStore = destination { try publishSnapshot(plan) }
            update(id) { $0.state = .finished; $0.currentFile = nil }
        } catch is CancellationError {
            update(id) { $0.state = .cancelled }
        } catch let error as URLError where error.code == .cancelled {
            update(id) { $0.state = .cancelled }
        } catch {
            update(id) { $0.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        }
    }

    // MARK: Resolving what to fetch

    func authorized(_ url: URL, host: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if host == "hf", let token = huggingFaceToken(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if host == "civitai", let token = civitaiToken(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func resolve(_ entry: ImageModelEntry) async throws -> DownloadPlan {
        switch entry.source {
        case .url(let url, let fileName, let sha):
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw ImageStudioError.invalid("Only http(s) downloads are allowed.") }
            let host = (url.host ?? "").contains("civitai") ? "civitai" : "other"
            var head = authorized(url, host: host); head.httpMethod = "HEAD"
            var size = entry.sizeBytes
            if let (_, response) = try? await session.data(for: head), let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               http.expectedContentLength > 0 { size = http.expectedContentLength }
            return DownloadPlan(entryID: entry.id, repo: "kiln/\(entry.id)", commit: "main",
                                files: [DownloadFile(path: Self.safeName(fileName), url: url, size: size, sha256: sha?.lowercased())])
        case .files(let urls, let names, let shas):
            var files: [DownloadFile] = []
            for (index, url) in urls.enumerated() {
                guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw ImageStudioError.invalid("Only http(s) downloads are allowed.") }
                var head = URLRequest(url: url); head.httpMethod = "HEAD"
                var size: Int64 = 0
                if let (_, response) = try? await session.data(for: head), let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.expectedContentLength > 0 { size = http.expectedContentLength }
                let sha = index < shas.count && !shas[index].isEmpty ? shas[index].lowercased() : nil
                files.append(DownloadFile(path: Self.safeName(names[index]), url: url, size: size, sha256: sha))
            }
            return DownloadPlan(entryID: entry.id, repo: "kiln/\(entry.id)", commit: "main", files: files)
        case .huggingFace(let repo, var wanted, let preferHalf):
            let info: [String: Any] = try await getJSON(endpoint.appendingPathComponent("api/models/\(repo)"), host: "hf", repo: repo)
            guard let commit = info["sha"] as? String else { throw ImageStudioError.downloadFailed("Hugging Face gave no revision for \(repo).") }
            let tree: [[String: Any]] = try await getJSON(
                URL(string: endpoint.absoluteString + "/api/models/\(repo)/tree/\(commit)?recursive=true")!, host: "hf", repo: repo)
            var byPath: [String: [String: Any]] = [:]
            for item in tree where (item["type"] as? String) == "file" { if let p = item["path"] as? String { byPath[p] = item } }
            if wanted.isEmpty {
                // A search result: take the diffusers layout the in-process engine reads, or refuse rather than guess.
                if byPath["text_encoder_2/config.json"] != nil { wanted = ["model_index.json"] + DiffusionLayout.sdxlFiles }
                else if byPath["unet/config.json"] != nil { wanted = ["model_index.json"] + DiffusionLayout.sd2Files }
                else { throw ImageStudioError.unsupported("\(repo) is not in diffusers layout. Look for a single-file checkpoint (Civitai) or a diffusers build.") }
            }
            var files: [DownloadFile] = []
            for path in wanted {
                let chosen = preferHalf && byPath[DiffusionFamilyPaths.half(path)] != nil ? DiffusionFamilyPaths.half(path) : path
                guard let item = byPath[chosen] else {
                    if path == "model_index.json" { continue }
                    throw ImageStudioError.downloadFailed("\(repo) has no file \(chosen).")
                }
                let size = (item["size"] as? NSNumber)?.int64Value ?? 0
                let lfs = item["lfs"] as? [String: Any]
                let sha256 = (lfs?["oid"] as? String)?.replacingOccurrences(of: "sha256:", with: "")
                let blob = lfs == nil ? item["oid"] as? String : nil
                let encoded = chosen.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
                let url = URL(string: endpoint.absoluteString + "/\(repo)/resolve/\(commit)/\(encoded)")!
                files.append(DownloadFile(path: chosen, url: url, size: size, sha256: sha256, gitSHA1: blob))
            }
            return DownloadPlan(entryID: entry.id, repo: repo, commit: commit, files: files)
        }
    }

    private func getJSON<T>(_ url: URL, host: String, repo: String) async throws -> T {
        let (data, response) = try await session.data(for: authorized(url, host: host))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw ImageStudioError.needsToken("Hugging Face needs a token for \(repo). Add yours in Settings → Providers (and accept the model's terms on its page).") }
        if status == 403 { throw ImageStudioError.needsAcceptance("Access to \(repo) is not granted. Open the model page on Hugging Face, read and accept the terms yourself, then try again.") }
        guard (200..<300).contains(status) else { throw ImageStudioError.downloadFailed("Hugging Face answered \(status) for \(repo).") }
        guard let value = (try? JSONSerialization.jsonObject(with: data)) as? T else { throw ImageStudioError.downloadFailed("Unexpected answer from Hugging Face for \(repo).") }
        return value
    }

    static func safeName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        return last.isEmpty || last == ".." || last == "." ? "model.bin" : last
    }

    // MARK: Paths

    private func targetRoot(for plan: DownloadPlan, destination: DownloadDestination) -> URL {
        switch destination {
        case .universalStore: store.repoDirectory(plan.repo).appendingPathComponent("blobs", isDirectory: true)
        case .folder(let url): url
        }
    }

    private func finalURL(_ file: DownloadFile, plan: DownloadPlan, destination: DownloadDestination) -> URL {
        switch destination {
        case .universalStore: targetRoot(for: plan, destination: destination).appendingPathComponent(blobName(file))
        case .folder(let url): url.appendingPathComponent(Self.safeName(file.path))
        }
    }

    private func blobName(_ file: DownloadFile) -> String {
        file.sha256 ?? file.gitSHA1 ?? SHA256.hash(data: Data(file.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func partialSize(of file: DownloadFile, in plan: DownloadPlan, destination: DownloadDestination) -> Int64 {
        let final = finalURL(file, plan: plan, destination: destination)
        let fm = FileManager.default
        if fm.fileExists(atPath: final.path) { return file.size }
        let part = final.appendingPathExtension("incomplete")
        return ((try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Links `snapshots/<commit>/<path>` to the blobs and points `refs/main` at the commit.
    private func publishSnapshot(_ plan: DownloadPlan) throws {
        let fm = FileManager.default
        let repoDir = store.repoDirectory(plan.repo)
        let snapshot = repoDir.appendingPathComponent("snapshots/\(plan.commit)", isDirectory: true)
        for file in plan.files {
            let link = snapshot.appendingPathComponent(file.path)
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: link)
            let depth = file.path.split(separator: "/").count - 1
            let relative = String(repeating: "../", count: depth + 2) + "blobs/" + blobName(file)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: relative)
        }
        let refs = repoDir.appendingPathComponent("refs", isDirectory: true)
        try fm.createDirectory(at: refs, withIntermediateDirectories: true)
        try plan.commit.write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)
        if plan.commit != "main" {
            // A URL entry keeps a plain "main" snapshot too, so the store can find it without a ref lookup.
        }
    }

    // MARK: One file

    private func fetch(_ file: DownloadFile, plan: DownloadPlan, destination: DownloadDestination,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        let final = finalURL(file, plan: plan, destination: destination)
        if fm.fileExists(atPath: final.path) { progress(file.size); return }
        let part = final.appendingPathExtension("incomplete")
        try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        let host = file.url.host?.contains("huggingface") == true || file.url.host == endpoint.host ? "hf" : (file.url.host?.contains("civitai") == true ? "civitai" : "other")
        var request = authorized(file.url, host: host)
        request.timeoutInterval = 120
        let existing = ((try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let stream = ChunkedDownload(request: request, partURL: part, resumeFrom: existing, progress: progress)
        try await stream.run(session: session)
        // Verify before the file gets its real name.
        let (matches, label) = try Self.verify(part, file: file)
        if !matches {
            try? fm.removeItem(at: part)
            throw ImageStudioError.checksumMismatch(file: "\(file.path) (\(label))")
        }
        try? fm.removeItem(at: final)
        try fm.moveItem(at: part, to: final)
    }

    static func verify(_ url: URL, file: DownloadFile) throws -> (Bool, String) {
        if let expected = file.sha256 {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (hex == expected.lowercased(), "sha256")
        }
        if let expected = file.gitSHA1 {
            let data = try Data(contentsOf: url)
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(data.count)\0".utf8)); hasher.update(data: data)
            return (hasher.finalize().map { String(format: "%02x", $0) }.joined() == expected.lowercased(), "git sha1")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
        return (file.size <= 0 || size == file.size, "size")
    }
}

/// Streams one HTTP response into a file, appending when the server honours a Range request and starting over when it does not.
final class ChunkedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let partURL: URL
    private let resumeFrom: Int64
    private let progress: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var alreadyComplete = false
    private var task: URLSessionDataTask?
    private let lock = NSLock()

    init(request: URLRequest, partURL: URL, resumeFrom: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.request = request; self.partURL = partURL; self.resumeFrom = resumeFrom; self.progress = progress
    }

    func run(session base: URLSession) async throws {
        let session = URLSession(configuration: base.configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock(); continuation = c; lock.unlock()
                let t = session.dataTask(with: request)
                lock.lock(); task = t; lock.unlock()
                t.resume()
            }
        } onCancel: {
            self.lock.lock(); let t = self.task; self.lock.unlock(); t?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { fail(ImageStudioError.downloadFailed("No HTTP response.")); completionHandler(.cancel); return }
        switch http.statusCode {
        case 206:
            written = resumeFrom
            handle = try? openForAppend(truncate: false)
        case 200..<300:
            written = 0
            handle = try? openForAppend(truncate: true)
        case 401: fail(ImageStudioError.needsToken("The host asked for a token (401). Add yours in Settings → Providers, and accept the model's terms on its page.")); completionHandler(.cancel); return
        case 403: fail(ImageStudioError.needsAcceptance("The host refused access (403). If the model is gated, accept its terms on the model page yourself, then try again.")); completionHandler(.cancel); return
        case 416:
            // The partial file already covers the whole thing; treat as complete and let verification decide.
            lock.lock(); alreadyComplete = true; lock.unlock(); completionHandler(.cancel); return
        default: fail(ImageStudioError.downloadFailed("The server answered \(http.statusCode).")); completionHandler(.cancel); return
        }
        if handle == nil { fail(ImageStudioError.downloadFailed("Cannot write \(partURL.lastPathComponent).")); completionHandler(.cancel); return }
        completionHandler(.allow)
    }

    private func openForAppend(truncate: Bool) throws -> FileHandle {
        let fm = FileManager.default
        if truncate || !fm.fileExists(atPath: partURL.path) { fm.createFile(atPath: partURL.path, contents: nil) }
        let h = try FileHandle(forWritingTo: partURL)
        if truncate { try h.truncate(atOffset: 0) } else { try h.seekToEnd() }
        return h
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data); written += Int64(data.count); progress(written) }
        catch { fail(error); dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if next.url?.host != task.originalRequest?.url?.host { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close(); handle = nil
        lock.lock()
        let stored = failure
        let complete = alreadyComplete
        let c = continuation; continuation = nil
        lock.unlock()
        if let stored { c?.resume(throwing: stored) }
        else if complete { c?.resume() }
        else if let error {
            c?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else { c?.resume() }
    }

    private func fail(_ error: Error) { lock.lock(); if failure == nil { failure = error }; lock.unlock() }
}
