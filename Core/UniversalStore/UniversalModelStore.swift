import Foundation

public struct InstalledModel: Codable, Identifiable, Equatable, Sendable {
    public var id: String { repoID + "@" + revision }
    public var repoID: String
    public var revision: String
    public var path: String
    public var totalBytes: UInt64
    /// True for text-generation models (config architectures end in `CausalLM`). Speech, vision-only and
    /// audio models share the cache layout but cannot answer a chat message, so the picker leaves them out.
    public var isLanguageModel: Bool = true
}

/// The universal model repository: the standard Hugging Face cache layout,
/// shared with `hf`, `mlx_lm`, transformers, and every other app honouring
/// HF_HUB_CACHE. Location order: `HF_HUB_CACHE`, `HF_HOME/hub`,
/// `~/.cache/huggingface/hub`.
///
///     models--<org>--<repo>/blobs/<sha256 | git-sha1>
///     models--<org>--<repo>/snapshots/<commit>/<path> -> relative symlink into blobs
///     models--<org>--<repo>/refs/main                 = <commit>
public struct UniversalModelStore: Sendable {
    public var root: URL

    public init(root: URL? = nil) {
        self.root = root ?? UniversalModelStore.defaultRoot()
    }

    public static func defaultRoot(location: ModelStoreLocation = .shared) -> URL {
        // The folder the user chose in Settings wins: in the sandbox it is the only place that is readable.
        if let chosen = location.folder { return ModelStoreLocation.hubDirectory(in: chosen) }
        let env = ProcessInfo.processInfo.environment
        if let value = env["HF_HUB_CACHE"], !value.isEmpty { return URL(fileURLWithPath: value) }
        if let value = env["HF_HOME"], !value.isEmpty { return URL(fileURLWithPath: value).appendingPathComponent("hub") }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface/hub")
    }

    public func ensureAvailable() throws {
        var isDirectory: ObjCBool = false
        let resolved = root.resolvingSymlinksInPath().path
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue { return }
        if resolved.hasPrefix("/Volumes/") || (try? FileManager.default.destinationOfSymbolicLink(atPath: root.path)) != nil {
            throw ProviderError.engineUnavailable("The universal model store at \(root.path) is not available. Connect the drive that holds it (\(resolved)).")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func isLanguageModel(configAt url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.resolvingSymlinksInPath()),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let architectures = config["architectures"] as? [String] ?? []
        return architectures.contains { $0.hasSuffix("CausalLM") }
    }

    static func repoDirectoryName(_ repoID: String) -> String {
        "models--" + repoID.replacingOccurrences(of: "/", with: "--")
    }

    public func repoDirectory(_ repoID: String) -> URL {
        root.appendingPathComponent(Self.repoDirectoryName(repoID))
    }

    /// Models usable by an MLX LM: a snapshot with `config.json` and at least
    /// one resolvable `.safetensors` file.
    public func installed() -> [InstalledModel] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.resolvingSymlinksInPath().path) else {
            return []
        }
        var found: [InstalledModel] = []
        for entry in entries where entry.hasPrefix("models--") {
            let repoID = String(entry.dropFirst(8)).replacingOccurrences(of: "--", with: "/")
            let snapshots = repoDirectory(repoID).appendingPathComponent("snapshots")
            guard let revisions = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { continue }
            for revision in revisions {
                let directory = snapshots.appendingPathComponent(revision)
                guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else { continue }
                var bytes: UInt64 = 0
                var hasWeights = false
                if let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
                    for case let url as URL in walker {
                        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
                              let size = attributes[.size] as? UInt64 else { continue }
                        bytes += size
                        if url.pathExtension == "safetensors" { hasWeights = true }
                    }
                }
                if hasWeights {
                    found.append(InstalledModel(repoID: repoID, revision: revision, path: directory.path, totalBytes: bytes,
                                                isLanguageModel: Self.isLanguageModel(configAt: directory.appendingPathComponent("config.json"))))
                }
            }
        }
        return found.sorted { ($0.repoID, $0.revision) < ($1.repoID, $1.revision) }
    }
}
