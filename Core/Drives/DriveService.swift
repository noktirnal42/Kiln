import Foundation
import Darwin

/// A cloud-synced folder on this Mac. Kiln never signs in to a cloud service: it reads the folders the provider's own app already syncs, so
/// there is no token to protect, and what Kiln can do is limited by what that app has put on disk.
public struct DriveLocation: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case icloud, googleDrive, dropbox, oneDrive, box, other }
    public var id: String
    public var name: String
    public var kind: Kind
    public var root: URL
}

public struct DriveEntry: Identifiable, Equatable, Sendable {
    public enum Availability: String, Sendable { case local, cloudOnly }
    public var id: String { path }
    public var name: String
    public var path: String          // relative to the location root, "" for the root itself
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?
    public var availability: Availability
}

public enum DriveError: Error, Equatable, LocalizedError {
    case noSuchLocation(String), outsideLocation, notFound(String), notAFile, notADirectory, cloudOnly(String), tooLarge(Int64, Int64), binary, exists(String), accessDenied(String)
    public var errorDescription: String? {
        switch self {
        case .noSuchLocation(let n): "No cloud folder named \"\(n)\". Use drive_locations to see what is available."
        case .outsideLocation: "That path is outside the cloud folder."
        case .notFound(let p): "\(p) was not found."
        case .notAFile: "That is a folder, not a file."
        case .notADirectory: "That is a file, not a folder."
        case .cloudOnly(let p): "\(p) is online-only and has not been downloaded to this Mac. Download it in Finder first (reading it here would start a download of unknown size)."
        case .tooLarge(let size, let limit): "That file is \(size / 1024) KB; the limit here is \(limit / 1024) KB."
        case .binary: "That file is not plain text."
        case .exists(let p): "\(p) already exists. Kiln never overwrites files; choose another name."
        case .accessDenied(let p): "macOS did not let Kiln read \(p). Allow Kiln under System Settings, Privacy & Security, Files and Folders (or Full Disk Access)."
        }
    }
}

/// Finds the synced folders and browses, searches, reads and copies files inside them.
public struct DriveService: Sendable {
    let home: URL
    /// Whether a file's contents are not on this Mac yet. Overridable so tests do not need real cloud files.
    let isCloudOnly: @Sendable (URL) -> Bool
    public static let textLimit: Int64 = 512 * 1024
    public static let copyLimit: Int64 = 200 * 1024 * 1024

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, isCloudOnly: @escaping @Sendable (URL) -> Bool = DriveService.systemIsCloudOnly) {
        self.home = home; self.isCloudOnly = isCloudOnly
    }

    /// Dataless files (File Provider placeholders) carry SF_DATALESS; older iCloud placeholders are small ".name.icloud" files.
    public static func systemIsCloudOnly(_ url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix("."), url.pathExtension == "icloud" { return true }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_flags & 0x4000_0000) != 0   // SF_DATALESS
    }

    // MARK: Locations

    public func locations() -> [DriveLocation] {
        var out: [DriveLocation] = []
        let fm = FileManager.default
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: icloud.path) { out.append(DriveLocation(id: "icloud", name: "iCloud Drive", kind: .icloud, root: icloud)) }
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        for item in ((try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let raw = item.lastPathComponent
            let (kind, label) = Self.classify(raw)
            out.append(DriveLocation(id: raw.lowercased(), name: label, kind: kind, root: item))
        }
        for legacy in ["Dropbox", "Google Drive"] {
            let url = home.appendingPathComponent(legacy, isDirectory: true)
            if fm.fileExists(atPath: url.path), !out.contains(where: { $0.root.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) {
                let (kind, label) = Self.classify(legacy)
                out.append(DriveLocation(id: legacy.lowercased().replacingOccurrences(of: " ", with: ""), name: label, kind: kind, root: url))
            }
        }
        return out
    }

    /// "GoogleDrive-ada@example.com" -> (.googleDrive, "Google Drive (ada@example.com)").
    static func classify(_ folder: String) -> (DriveLocation.Kind, String) {
        let table: [(String, DriveLocation.Kind, String)] = [("googledrive", .googleDrive, "Google Drive"), ("google drive", .googleDrive, "Google Drive"), ("dropbox", .dropbox, "Dropbox"),
                                                              ("onedrive", .oneDrive, "OneDrive"), ("box", .box, "Box")]
        let lower = folder.lowercased()
        for (prefix, kind, label) in table where lower.hasPrefix(prefix) {
            let account = folder.dropFirst(prefix.count).drop(while: { $0 == "-" || $0 == " " })
            return (kind, account.isEmpty ? label : "\(label) (\(account))")
        }
        return (.other, folder)
    }

    public func location(named name: String) throws -> DriveLocation {
        let all = locations()
        let key = name.lowercased()
        if let exact = all.first(where: { $0.id == key || $0.name.lowercased() == key }) { return exact }
        let partial = all.filter { $0.name.lowercased().contains(key) }
        if partial.count == 1 { return partial[0] }
        throw DriveError.noSuchLocation(name)
    }

    // MARK: Paths

    /// A path inside the location. Symlinks are resolved first, so a link that points outside the drive is refused.
    func resolve(_ relative: String, in location: DriveLocation) throws -> URL {
        let root = location.root.resolvingSymlinksInPath().standardizedFileURL
        let trimmed = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate = (trimmed.isEmpty ? root : root.appendingPathComponent(trimmed)).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path == root.path || resolved.path.hasPrefix(prefix), !trimmed.split(separator: "/").contains("..") else { throw DriveError.outsideLocation }
        return resolved
    }

    func entry(for url: URL, root: URL, resolvedRoot: URL) -> DriveEntry? {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
        var name = url.lastPathComponent
        var cloud = isCloudOnly(url)
        if name.hasPrefix("."), url.pathExtension == "icloud" { name = String(name.dropFirst().dropLast(".icloud".count)); cloud = true }   // ".report.pdf.icloud" is the placeholder for report.pdf
        let rel = url.resolvingSymlinksInPath().path.replacingOccurrences(of: resolvedRoot.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return DriveEntry(name: name, path: rel, isDirectory: v.isDirectory ?? false, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate, availability: cloud ? .cloudOnly : .local)
    }

    // MARK: Browse and search

    public func list(_ location: DriveLocation, path: String = "") throws -> [DriveEntry] {
        let dir = try resolve(path, in: location)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else { throw DriveError.notFound(path.isEmpty ? location.name : path) }
        guard isDir.boolValue else { throw DriveError.notADirectory }
        let resolvedRoot = location.root.resolvingSymlinksInPath().standardizedFileURL
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: []) }
        catch { throw DriveError.accessDenied(path.isEmpty ? location.name : path) }
        return urls.compactMap { u in u.lastPathComponent == ".DS_Store" || (u.lastPathComponent.hasPrefix(".") && u.pathExtension != "icloud") ? nil : entry(for: u, root: location.root, resolvedRoot: resolvedRoot) }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    /// File and folder names containing every word of `query`, walking at most `maxVisited` items so a huge drive cannot stall the app.
    public func search(_ location: DriveLocation, query: String, limit: Int = 30, maxVisited: Int = 20_000) throws -> (matches: [DriveEntry], truncated: Bool) {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return ([], false) }
        let root = try resolve("", in: location)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw DriveError.accessDenied(location.name) }
        var matches: [DriveEntry] = [], visited = 0
        while let next = walker.nextObject() as? URL {
            visited += 1
            if visited > maxVisited { return (matches, true) }
            let name = next.lastPathComponent.lowercased()
            if words.allSatisfy({ name.contains($0) }), let e = entry(for: next, root: location.root, resolvedRoot: root) {
                matches.append(e)
                if matches.count >= limit { return (matches, true) }
            }
        }
        return (matches, false)
    }

    // MARK: Read and copy

    /// The right error for a path that does not exist: an online-only placeholder means "not downloaded", not "missing".
    func missingError(_ url: URL, _ path: String) -> DriveError {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: placeholder.path) ? .cloudOnly(path) : .notFound(path)
    }

    /// Plain text of a local file, at most `textLimit` bytes. Online-only files are never read (that would start a download).
    public func readText(_ location: DriveLocation, path: String) throws -> String {
        let url = try resolve(path, in: location)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw missingError(url, path) }
        guard !isDir.boolValue else { throw DriveError.notAFile }
        if isCloudOnly(url) { throw DriveError.cloudOnly(path) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        guard size <= Self.textLimit else { throw DriveError.tooLarge(size, Self.textLimit) }
        guard let data = try? Data(contentsOf: url) else { throw DriveError.accessDenied(path) }
        guard !data.prefix(8192).contains(0), let text = String(data: data, encoding: .utf8) else { throw DriveError.binary }
        return text
    }

    /// Copies a file from the drive into a folder on this Mac (for example the project). Never overwrites; refuses online-only and very large files.
    @discardableResult
    public func copyOut(_ location: DriveLocation, path: String, to destination: URL) throws -> URL {
        let source = try resolve(path, in: location)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else { throw missingError(source, path) }
        guard !isDir.boolValue else { throw DriveError.notAFile }
        if isCloudOnly(source) { throw DriveError.cloudOnly(path) }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        guard size <= Self.copyLimit else { throw DriveError.tooLarge(size, Self.copyLimit) }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw DriveError.exists(destination.lastPathComponent) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Copies a file from this Mac into the drive (the provider's app then uploads it). Never overwrites.
    @discardableResult
    public func copyIn(_ source: URL, to location: DriveLocation, path: String) throws -> DriveEntry {
        let destination = try resolve(path, in: location)
        guard FileManager.default.fileExists(atPath: source.path) else { throw DriveError.notFound(source.lastPathComponent) }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        guard size <= Self.copyLimit else { throw DriveError.tooLarge(size, Self.copyLimit) }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw DriveError.exists(destination.lastPathComponent) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        let root = location.root.resolvingSymlinksInPath().standardizedFileURL
        guard let e = entry(for: destination, root: location.root, resolvedRoot: root) else { throw DriveError.notFound(path) }
        return e
    }
}
