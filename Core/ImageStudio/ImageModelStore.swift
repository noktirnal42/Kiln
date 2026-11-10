import Foundation

/// A diffusers-layout model on disk in the universal model store (`models--org--repo/snapshots/<commit>/…`).
public struct InstalledImageModel: Codable, Identifiable, Equatable, Sendable {
    public var id: String { repoID }
    public var repoID: String
    public var path: String
    public var family: String        // "sd2", "sdxl", "sd15" or "unknown"
    public var distilled: Bool
    public var bytes: Int64
}

/// Where image models live and what is installed. Hugging Face files go into the universal model store (the same
/// cache `hf`, `mlx_lm` and Kiln's Lab use), so a model fetched once is shared. Single files for other tools go to the folder
/// the user names (a ComfyUI `checkpoints` folder, Draw Things' `Models`).
public struct ImageModelStore: Sendable {
    public var hubRoot: URL

    public init(hubRoot: URL = UniversalModelStore.defaultRoot()) { self.hubRoot = hubRoot }

    public static func repoDirectoryName(_ repo: String) -> String { "models--" + repo.replacingOccurrences(of: "/", with: "--") }
    public func repoDirectory(_ repo: String) -> URL { hubRoot.appendingPathComponent(Self.repoDirectoryName(repo), isDirectory: true) }

    /// The snapshot folder `refs/main` points at (or the newest one when there is no ref).
    public func currentSnapshot(of repo: String) -> URL? {
        let dir = repoDirectory(repo)
        let fm = FileManager.default
        if let ref = try? String(contentsOf: dir.appendingPathComponent("refs/main"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            let url = dir.appendingPathComponent("snapshots/\(ref)", isDirectory: true)
            if fm.fileExists(atPath: url.path) { return url }
        }
        let snapshots = dir.appendingPathComponent("snapshots", isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: snapshots.path)) ?? []
        return names.sorted().last.map { snapshots.appendingPathComponent($0, isDirectory: true) }
    }

    /// Diffusers folders the in-process engine can try: a `model_index.json` and a UNet next to it.
    public func installedDiffusers() -> [InstalledImageModel] {
        let fm = FileManager.default
        let root = hubRoot.resolvingSymlinksInPath()
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var found: [InstalledImageModel] = []
        for entry in entries where entry.hasPrefix("models--") {
            let repo = String(entry.dropFirst(8)).replacingOccurrences(of: "--", with: "/")
            guard let snapshot = currentSnapshot(of: repo),
                  fm.fileExists(atPath: snapshot.appendingPathComponent("model_index.json").path),
                  fm.fileExists(atPath: snapshot.appendingPathComponent("unet/config.json").path) else { continue }
            let hasWeights = ["unet/diffusion_pytorch_model.fp16.safetensors", "unet/diffusion_pytorch_model.safetensors"]
                .contains { fm.fileExists(atPath: snapshot.appendingPathComponent($0).path) }
            guard hasWeights else { continue }
            let (family, distilled) = Self.classify(snapshot: snapshot, repo: repo)
            found.append(InstalledImageModel(repoID: repo, path: snapshot.path, family: family, distilled: distilled,
                                             bytes: Self.size(of: snapshot)))
        }
        return found.sorted { $0.repoID.lowercased() < $1.repoID.lowercased() }
    }

    static func classify(snapshot: URL, repo: String) -> (family: String, distilled: Bool) {
        let name = repo.lowercased()
        let distilled = name.contains("turbo") || name.contains("lightning") || name.contains("lcm")
        let hasSecondEncoder = FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("text_encoder_2/config.json").path)
        if hasSecondEncoder { return ("sdxl", distilled) }
        if let data = try? Data(contentsOf: snapshot.appendingPathComponent("unet/config.json")),
           let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let cross = (config["cross_attention_dim"] as? Int) ?? (config["cross_attention_dim"] as? [Int])?.first
            if cross == 1024 { return ("sd2", distilled) }
            if cross == 768 { return ("sd15", distilled) }
        }
        return ("unknown", distilled)
    }

    static func size(of directory: URL) -> Int64 {
        var total: Int64 = 0
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        for case let url as URL in walker {
            let real = url.resolvingSymlinksInPath().path
            if let size = (try? FileManager.default.attributesOfItem(atPath: real))?[.size] as? NSNumber { total += size.int64Value }
        }
        return total
    }

    /// Whether every file the entry needs is present (for a Hugging Face entry: in the store; for a URL entry: in `folder`).
    public func isInstalled(_ entry: ImageModelEntry, folder: URL? = nil) -> Bool {
        let fm = FileManager.default
        switch entry.source {
        case .huggingFace(let repo, let files, let preferHalf):
            guard let snapshot = currentSnapshot(of: repo) else { return false }
            return files.allSatisfy { path in
                if preferHalf, fm.fileExists(atPath: snapshot.appendingPathComponent(DiffusionFamilyPaths.half(path)).path) { return true }
                return fm.fileExists(atPath: snapshot.appendingPathComponent(path).path)
            }
        case .files(_, let names, _):
            guard let folder else { return false }
            return names.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        case .url(_, let fileName, _):
            if let folder, fm.fileExists(atPath: folder.appendingPathComponent(fileName).path) { return true }
            return fm.fileExists(atPath: repoDirectory("kiln/\(entry.id)").appendingPathComponent("snapshots/main/\(fileName)").path)
        }
    }

    /// Where a single file for another tool is looked for when the user did not pick a folder.
    public func snapshotFile(entryID: String, fileName: String) -> URL {
        repoDirectory("kiln/\(entryID)").appendingPathComponent("snapshots/main/\(fileName)")
    }
}

enum DiffusionFamilyPaths {
    static func half(_ path: String) -> String {
        guard path.hasSuffix(".safetensors") else { return path }
        return String(path.dropLast(".safetensors".count)) + ".fp16.safetensors"
    }
}

/// Folders of other tools that Kiln may save single files into. Remembered in UserDefaults (they are paths, not secrets).
public struct ExternalModelFolders: Sendable {
    public enum Tool: String, CaseIterable, Sendable {
        case drawThings = "image.folder.drawthings", comfyUI = "image.folder.comfyui", automatic1111 = "image.folder.a1111"
        public var title: String {
            switch self { case .drawThings: "Draw Things Models"; case .comfyUI: "ComfyUI models"; case .automatic1111: "AUTOMATIC1111 / Forge models" }
        }
    }

    public static func drawThingsDefault() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Containers/com.liuliu.draw-things/Data/Documents/Models", isDirectory: true)
    }

    public static func folder(for tool: Tool, defaults: UserDefaults = .standard) -> URL? {
        if let path = defaults.string(forKey: tool.rawValue), !path.isEmpty { return URL(fileURLWithPath: path) }
        if tool == .drawThings {
            let url = drawThingsDefault()
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return nil
    }

    public static func set(_ url: URL?, for tool: Tool, defaults: UserDefaults = .standard) {
        if let url { defaults.set(url.path, forKey: tool.rawValue) } else { defaults.removeObject(forKey: tool.rawValue) }
    }
}
