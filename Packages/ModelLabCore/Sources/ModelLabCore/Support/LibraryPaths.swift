import Foundation

/// The app's local, sandboxed library root. Everything Model Lab writes
/// (datasets, model artifacts, logs, and the SwiftData store) lives under
/// here so the app stays local-first and easy to inspect or wipe.
public enum LibraryPaths {
    public static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("ModelLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    public static var datasets: URL { makeSubdirectory("Datasets") }
    public static var models: URL { makeSubdirectory("Models") }
    public static var experiments: URL { makeSubdirectory("Experiments") }
    public static var logs: URL { makeSubdirectory("Logs") }
    public static var storeFile: URL { root.appendingPathComponent("ModelLab.store.sqlite") }

    private static func makeSubdirectory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
