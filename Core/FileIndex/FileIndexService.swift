import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct IndexedFile: Identifiable, Equatable, Sendable, Codable {
    public var id: String { path }
    public var path: String
    public var absolutePath: String
    public var name: String
    public var fileExtension: String
    public var size: Int
    public var modifiedAt: Date
    public var source: SearchSource

    public init(path: String, absolutePath: String, name: String, fileExtension: String, size: Int, modifiedAt: Date, source: SearchSource) {
        self.path = path
        self.absolutePath = absolutePath
        self.name = name
        self.fileExtension = fileExtension
        self.size = size
        self.modifiedAt = modifiedAt
        self.source = source
    }
}

public enum SearchSource: String, Codable, Equatable, Sendable {
    case fts5 = "fts5"
    case spotlight = "spotlight"
}

public struct SearchHit: Identifiable, Equatable, Sendable {
    public var id: String { file.path }
    public var file: IndexedFile
    public var score: Double
    public var sources: [SearchSource]

    public init(file: IndexedFile, score: Double, sources: [SearchSource]) {
        self.file = file
        self.score = score
        self.sources = sources
    }
}

/// Workspace file index: SQLite FTS5 over a bounded directory walk, optional
/// Spotlight (NSMetadataQuery) merge, and an FSEvents watcher that debounces
/// reindexes. Both sources are merged and ranked by one unified search API.
public actor FileIndexService {
    public static let maxFiles = 20_000
    public static let ignoredDirectories: Set<String> = [
        ".git", ".svn", ".hg", "DerivedData", "build", "Build", "node_modules", ".build", "Pods", "dist", ".next",
    ]

    private var root: String?
    private var files: [IndexedFile] = []
    private var spotlightSupported: [String: Bool] = [:]
    private var db: OpaquePointer?
    private var fsEventStream: FSEventStreamRef?
    private var reindexWork: DispatchWorkItem?
    private let indexQueue = DispatchQueue(label: "com.supermeta.fileindex")
    private(set) var indexedRoot: String?

    public init() {}

    deinit {
        // Actor-held C resources are released on the actor's executor via
        // shutdown hooks in index/close paths; C pointers are not Sendable so
        // direct deinit access is refused under Swift 6 strict concurrency.
    }

    // MARK: Indexing

    public func index(root: String) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MCPError.launchFailed("index root is not a directory: \(root)")
        }
        self.root = root
        indexedRoot = root
        files = Self.scan(root: root)
        rebuildFTS()
        startWatching(root: root)
    }

    nonisolated static func scan(root: String) -> [IndexedFile] {
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var results: [IndexedFile] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            if url.pathComponents.contains(where: { ignoredDirectories.contains($0) }) {
                if url.hasDirectoryPath { enumerator.skipDescendants() }
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            let relative = url.path.hasPrefix(rootURL.path + "/") ? String(url.path.dropFirst(rootURL.path.count + 1)) : url.lastPathComponent
            results.append(IndexedFile(
                path: relative,
                absolutePath: url.path,
                name: url.lastPathComponent,
                fileExtension: url.pathExtension,
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? Date(),
                source: .fts5
            ))
            if results.count >= maxFiles { break }
        }
        return results.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    public func indexedFiles() -> [IndexedFile] {
        files
    }

    public func indexedRootPath() -> String? {
        indexedRoot
    }

    // MARK: FTS5

    private func rebuildFTS() {
        sqlite3_close(db)
        db = nil
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermeta-fileindex-\(UUID().uuidString).sqlite3")
        guard sqlite3_open(temporary.path, &db) == SQLITE_OK else { return }
        _ = exec("CREATE TABLE files(path TEXT PRIMARY KEY, name TEXT, ext TEXT, size INTEGER, mtime REAL)")
        _ = exec("CREATE VIRTUAL TABLE files_fts USING fts5(name, path, content='files', content_rowid='rowid')")
        _ = exec("CREATE TRIGGER files_ai AFTER INSERT ON files BEGIN INSERT INTO files_fts(rowid, name, path) VALUES (new.rowid, new.name, new.path); END")
        _ = exec("BEGIN TRANSACTION")
        for file in files {
            let sql = "INSERT OR REPLACE INTO files(path, name, ext, size, mtime) VALUES (?, ?, ?, ?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(statement, 1, file.path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, file.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, file.fileExtension, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 4, Int64(file.size))
            sqlite3_bind_double(statement, 5, file.modifiedAt.timeIntervalSince1970)
            _ = sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        _ = exec("COMMIT")
    }

    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func searchFTS(_ query: String, limit: Int) -> [SearchHit] {
        guard let db else { return [] }
        let sanitized = query
            .split(separator: " ")
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }
            .joined(separator: " ")
        guard !sanitized.isEmpty else { return [] }
        let sql = """
            SELECT f.path, f.name, f.ext, f.size, f.mtime, bm25(files_fts) AS rank
            FROM files_fts JOIN files f ON f.rowid = files_fts.rowid
            WHERE files_fts MATCH ?
            ORDER BY rank LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sanitized, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var hits: [SearchHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(statement, 0))
            let name = String(cString: sqlite3_column_text(statement, 1))
            let ext = String(cString: sqlite3_column_text(statement, 2))
            let size = Int(sqlite3_column_int64(statement, 3))
            let mtime = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let rank = sqlite3_column_double(statement, 5)
            guard let root, let rootURL = URL(string: root) ?? URL(filePath: root) as URL? else { continue }
            let absolute = rootURL.appendingPathComponent(path).path
            hits.append(SearchHit(
                file: IndexedFile(path: path, absolutePath: absolute, name: name, fileExtension: ext, size: size, modifiedAt: mtime, source: .fts5),
                score: abs(rank),
                sources: [.fts5]
            ))
        }
        return hits
    }

    // MARK: Spotlight

    /// Spotlight merge runs outside tests (NSMetadataQuery needs a live run
    /// loop and sandbox scope); absence degrades to FTS5-only with no error.
    public func searchSpotlight(_ query: String, limit: Int) async -> [SearchHit] {
        guard let root else { return [] }
        let scope = URL(fileURLWithPath: root)
        return await withCheckedContinuation { continuation in
            let metadataQuery = NSMetadataQuery()
            metadataQuery.searchScopes = [scope]
            metadataQuery.predicate = NSPredicate(format: "(kMDItemFSName CONTAINS[cd] %@) && (kMDItemContentTypeTree = 'public.item')", query)
            var finished = false
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: metadataQuery, queue: nil
            ) { notification in
                guard !finished else { return }
                finished = true
                let query = notification.object as? NSMetadataQuery
                query?.stop()
                var hits: [SearchHit] = []
                for index in 0..<(query?.resultCount ?? 0) {
                    guard let item = query?.result(at: index) as? NSMetadataItem else { continue }
                    let path = item.value(forAttribute: NSMetadataItemPathKey) as? String ?? ""
                    let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? ""
                    let size = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.intValue ?? 0
                    let modified = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date ?? Date()
                    let relative = path.hasPrefix(scope.path + "/") ? String(path.dropFirst(scope.path.count + 1)) : name
                    hits.append(SearchHit(
                        file: IndexedFile(
                            path: relative, absolutePath: path, name: name,
                            fileExtension: (name as NSString).pathExtension,
                            size: size, modifiedAt: modified, source: .spotlight
                        ),
                        score: 1.0,
                        sources: [.spotlight]
                    ))
                    if hits.count >= limit { break }
                }
                if let observer { NotificationCenter.default.removeObserver(observer) }
                continuation.resume(returning: hits)
            }
            metadataQuery.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                guard !finished else { return }
                finished = true
                metadataQuery.stop()
                if let observer { NotificationCenter.default.removeObserver(observer) }
                continuation.resume(returning: [])
            }
        }
    }

    /// Unified search: FTS5 + Spotlight merged, same path collated, ranked by
    /// (source count, score, path).
    public func search(_ query: String, limit: Int = 50, includeSpotlight: Bool = true) async -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var merged: [String: SearchHit] = [:]
        for hit in searchFTS(trimmed, limit: limit) {
            merged[hit.file.absolutePath] = hit
        }
        if includeSpotlight {
            for hit in await searchSpotlight(trimmed, limit: limit) {
                if var existing = merged[hit.file.absolutePath] {
                    existing.score += hit.score
                    existing.sources.append(.spotlight)
                    merged[hit.file.absolutePath] = existing
                } else {
                    merged[hit.file.absolutePath] = hit
                }
            }
        }
        let lowerQuery = trimmed.lowercased()
        return merged.values
            .map { hit -> SearchHit in
                var adjusted = hit
                let name = hit.file.name.lowercased()
                if name.hasPrefix(lowerQuery) {
                    adjusted.score += 100
                } else if name.contains(lowerQuery) {
                    adjusted.score += 50
                }
                return adjusted
            }
            .sorted {
                if $0.sources.count != $1.sources.count { return $0.sources.count > $1.sources.count }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.file.path < $1.file.path
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: FSEvents watching

    private func startWatching(root: String) {
        if let fsEventStream {
            FSEventStreamStop(fsEventStream)
            FSEventStreamInvalidate(fsEventStream)
            FSEventStreamRelease(fsEventStream)
            self.fsEventStream = nil
        }
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            NotificationCenter.default.post(name: .fileIndexWorkspaceChanged, object: nil)
        }
        var context = FSEventStreamContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil
        )
        let paths = [root] as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, indexQueue)
        FSEventStreamStart(stream)
        fsEventStream = stream
    }

    public func requestReindex() async {
        guard let root else { return }
        reindexWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { try? await self.index(root: root) }
        }
        reindexWork = work
        indexQueue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}

public extension Notification.Name {
    static let fileIndexWorkspaceChanged = Notification.Name("com.supermeta.fileindex.workspaceChanged")
}
