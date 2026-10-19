import Foundation
import Observation

/// A resumable file downloader backed by `URLSessionDownloadTask`. Used for
/// dataset file downloads (Hugging Face `resolve/main` URLs and arbitrary
/// URL imports). Progress and status are published for the UI; resume data
/// is kept so a cancelled or dropped download can continue instead of
/// restarting from zero.
@Observable
@MainActor
public final class DownloadManager: NSObject {
    public struct Download: Identifiable, Sendable {
        public let id: UUID
        public var sourceURL: URL
        public var destinationURL: URL
        public var bytesWritten: Int64 = 0
        public var totalBytes: Int64 = 0
        public var status: DownloadStatus = .notStarted
        public var errorMessage: String?

        public var fractionComplete: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(bytesWritten) / Double(totalBytes)
        }
    }

    /// A cancelled/interrupted download's resume data, persisted to disk so
    /// it survives the app quitting — a plain `.default` `URLSession` gives
    /// up any in-flight resume data the moment the process exits, so without
    /// this, quitting mid-download meant starting over from zero next time.
    private struct PendingDownloadRecord: Codable {
        let id: UUID
        let sourceURL: URL
        let destinationURL: URL
    }

    public static let shared = DownloadManager()

    public private(set) var downloads: [UUID: Download] = [:]

    @ObservationIgnored private var activeTasks: [UUID: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var resumeData: [UUID: Data] = [:]
    @ObservationIgnored private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    private static var pendingDownloadsDirectory: URL {
        let url = LibraryPaths.root.appendingPathComponent("PendingDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    override private init() {
        super.init()
        restorePendingDownloads()
    }

    @discardableResult
    public func start(url: URL, destination: URL) -> UUID {
        let id = UUID()
        downloads[id] = Download(id: id, sourceURL: url, destinationURL: destination, status: .downloading)
        let task = session.downloadTask(with: url)
        task.taskDescription = id.uuidString
        activeTasks[id] = task
        task.resume()
        return id
    }

    public func cancel(id: UUID) {
        guard let task = activeTasks[id] else { return }
        task.cancel { [weak self] data in
            Task { @MainActor in
                self?.resumeData[id] = data
                self?.downloads[id]?.status = .cancelled
                self?.activeTasks[id] = nil
                if let data { self?.persistPending(id: id, resumeData: data) }
            }
        }
    }

    public func resumeDownload(id: UUID) {
        guard let data = resumeData[id] else { return }
        let task = session.downloadTask(withResumeData: data)
        task.taskDescription = id.uuidString
        activeTasks[id] = task
        downloads[id]?.status = .downloading
        resumeData[id] = nil
        clearPersisted(id: id)
        task.resume()
    }

    /// Cancels every in-flight download and persists its resume data,
    /// waiting for each cancellation to actually hand back resume data
    /// before returning. Intended to be awaited from an app-termination
    /// hook (`applicationShouldTerminate` returning `.terminateLater`)
    /// since a plain `applicationWillTerminate` notification doesn't wait
    /// for async work.
    public func persistActiveDownloadsForTermination() async {
        let ids = Array(activeTasks.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.cancelAndPersist(id: id) }
            }
        }
    }

    private func cancelAndPersist(id: UUID) async {
        guard let task = activeTasks[id] else { return }
        let data: Data? = await withCheckedContinuation { continuation in
            task.cancel { data in continuation.resume(returning: data) }
        }
        if let data {
            resumeData[id] = data
            persistPending(id: id, resumeData: data)
        }
        downloads[id]?.status = .cancelled
        activeTasks[id] = nil
    }

    private func persistPending(id: UUID, resumeData: Data) {
        guard let download = downloads[id] else { return }
        let dir = Self.pendingDownloadsDirectory
        let record = PendingDownloadRecord(id: id, sourceURL: download.sourceURL, destinationURL: download.destinationURL)
        try? JSONEncoder().encode(record).write(to: dir.appendingPathComponent("\(id.uuidString).json"))
        try? resumeData.write(to: dir.appendingPathComponent("\(id.uuidString).resumedata"))
    }

    private func clearPersisted(id: UUID) {
        let dir = Self.pendingDownloadsDirectory
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).resumedata"))
    }

    private func restorePendingDownloads() {
        let dir = Self.pendingDownloadsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for metadataURL in files where metadataURL.pathExtension == "json" {
            guard let metadata = try? Data(contentsOf: metadataURL),
                  let record = try? JSONDecoder().decode(PendingDownloadRecord.self, from: metadata) else { continue }
            let resumeURL = dir.appendingPathComponent("\(record.id.uuidString).resumedata")
            guard let data = try? Data(contentsOf: resumeURL) else { continue }
            downloads[record.id] = Download(
                id: record.id, sourceURL: record.sourceURL, destinationURL: record.destinationURL, status: .cancelled
            )
            resumeData[record.id] = data
        }
    }

    fileprivate nonisolated func idFor(_ task: URLSessionTask) -> UUID? {
        task.taskDescription.flatMap(UUID.init(uuidString:))
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            guard let id = idFor(downloadTask) else { return }
            downloads[id]?.bytesWritten = totalBytesWritten
            downloads[id]?.totalBytes = totalBytesExpectedToWrite
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = idFor(downloadTask) else { return }
        // Move synchronously off the delegate queue's temp file before it is deleted.
        let tempCopy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: tempCopy)
        Task { @MainActor in
            guard let dest = downloads[id]?.destinationURL else { return }
            do {
                try? FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tempCopy, to: dest)
                downloads[id]?.status = .completed
                clearPersisted(id: id)
            } catch {
                downloads[id]?.status = .failed
                downloads[id]?.errorMessage = error.localizedDescription
            }
            activeTasks[id] = nil
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error, let id = idFor(task) else { return }
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            Task { @MainActor in
                self.resumeData[id] = data
                self.persistPending(id: id, resumeData: data)
            }
        }
        if (error as NSError).code != NSURLErrorCancelled {
            Task { @MainActor in
                downloads[id]?.status = .failed
                downloads[id]?.errorMessage = error.localizedDescription
                activeTasks[id] = nil
            }
        }
    }
}
