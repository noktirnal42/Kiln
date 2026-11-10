import Foundation

// Live catalogues beyond the curated list: Draw Things' own model list, Hugging Face search and Civitai search.
// Parsing is separate from fetching so it can be tested against saved responses.

public enum DrawThingsCatalog {
    public static let base = URL(string: "https://models.drawthings.ai")!
    public static let fileHost = URL(string: "https://static.libnnc.org")!

    static func family(version: String) -> ImageModelFamily {
        if version == "v1" { return .sd15 }
        if version == "v2" { return .sd2 }
        if version.hasPrefix("sdxl") || version == "ssd_1b" { return .sdxl }
        if version.hasPrefix("sd3") { return .sd3 }
        if version.hasPrefix("flux") { return .flux }
        if version.hasPrefix("qwen") { return .qwen }
        return .other
    }

    /// Models, LoRAs and ControlNets from the three JSON lists Draw Things publishes. Files are Draw Things `.ckpt`s, usable by Draw Things only.
    public static func parse(models: Data?, loras: Data?, controlNets: Data?) -> [ImageModelEntry] {
        func list(_ data: Data?) -> [[String: Any]] { (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ?? [] }
        var out: [ImageModelEntry] = []
        for item in list(models) {
            guard let file = item["file"] as? String, let name = item["name"] as? String else { continue }
            let version = item["version"] as? String ?? ""
            let companions = ["autoencoder", "clip_encoder", "text_encoder", "image_encoder"].compactMap { item[$0] as? String }
            let names = [file] + companions.filter { $0 != file }
            let isVideo = ["wan_", "hunyuan_video", "svd", "ltx", "minimax_h3", "cosmos"].contains { version.hasPrefix($0) } || item["frames_per_second"] != nil
            let note = (item["note"] as? String).map { stripMarkdown($0) }
            out.append(ImageModelEntry(
                id: "dt:\(file)", name: name, kind: .checkpoint, family: family(version: version),
                summary: note.map { String($0.prefix(220)) } ?? "Draw Things model (\(version)).",
                source: .files(urls: names.map { fileHost.appendingPathComponent($0) }, fileNames: names, sha256: names.map { _ in "" }),
                sizeBytes: 0, license: "See the model's note in Draw Things", engines: ["drawthings"], distilled: false,
                defaultSteps: 20, defaultGuidance: (item["default_scale"] as? Double) ?? 7, nativeSide: 1024,
                notes: isVideo ? "Video model: Draw Things only; Kiln's Image studio generates stills." : "Draw Things format (.ckpt): only Draw Things can use it. Saved into its Models folder.",
                origin: "Draw Things"))
        }
        for item in list(loras) {
            guard let file = item["file"] as? String, let name = item["name"] as? String else { continue }
            out.append(ImageModelEntry(id: "dt:\(file)", name: name, kind: .lora, family: family(version: item["version"] as? String ?? ""),
                                       summary: "Draw Things LoRA.", source: .url(fileHost.appendingPathComponent(file), fileName: file, sha256: nil),
                                       sizeBytes: 0, license: "See the LoRA's page", engines: ["drawthings"], origin: "Draw Things"))
        }
        for item in list(controlNets) {
            guard let file = item["file"] as? String, let name = item["name"] as? String else { continue }
            out.append(ImageModelEntry(id: "dt:\(file)", name: name, kind: .controlNet, family: family(version: item["version"] as? String ?? ""),
                                       summary: "Draw Things control model (\(item["type"] as? String ?? "control")).",
                                       source: .url(fileHost.appendingPathComponent(file), fileName: file, sha256: nil),
                                       sizeBytes: 0, license: "See the model's page", engines: ["drawthings"], origin: "Draw Things"))
        }
        return out
    }

    static func stripMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
    }

    public static func fetch(session: URLSession = .shared) async throws -> [ImageModelEntry] {
        async let m = try? session.data(from: base.appendingPathComponent("models.json")).0
        async let l = try? session.data(from: base.appendingPathComponent("loras.json")).0
        async let c = try? session.data(from: base.appendingPathComponent("controlnets.json")).0
        let (models, loras, controls) = await (m, l, c)
        let entries = parse(models: models, loras: loras, controlNets: controls)
        guard !entries.isEmpty else { throw ImageStudioError.downloadFailed("Could not read Draw Things' model list.") }
        return entries
    }
}

public enum HuggingFaceImageSearch {
    public static func parse(_ data: Data) -> [ImageModelEntry] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let repo = (item["id"] as? String) ?? (item["modelId"] as? String) else { return nil }
            let tags = item["tags"] as? [String] ?? []
            let license = tags.first { $0.hasPrefix("license:") }.map { String($0.dropFirst(8)) } ?? "unspecified"
            let gated = (item["gated"] as? Bool) == true || (item["gated"] as? String) != nil
            let downloads = (item["downloads"] as? Int).map { "\($0) downloads" } ?? ""
            let diffusers = tags.contains("diffusers")
            let xl = tags.contains { $0.lowercased().contains("xl") } || repo.lowercased().contains("xl")
            return ImageModelEntry(
                id: "hf:\(repo)", name: repo, family: xl ? .sdxl : .other, summary: ["Hugging Face", downloads].filter { !$0.isEmpty }.joined(separator: " · "),
                source: .huggingFace(repo: repo, files: [], preferHalf: true), sizeBytes: 0, license: license,
                commercialUse: license.contains("-nc") || license == "other" ? nil : true, gating: gated ? .termsAndToken : .open,
                engines: diffusers ? ["mlx"] : [], notes: diffusers ? "Size is known when the download starts. Runs in the MLX engine if it is an SD 2.x or SDXL diffusers repo." : "Not a diffusers repo: Kiln cannot run or auto-select files for it.",
                origin: "Hugging Face")
        }
    }

    public static func search(_ query: String, endpoint: URL = URL(string: "https://huggingface.co")!, session: URLSession = .shared,
                              token: SecretProvider = { nil }) async throws -> [ImageModelEntry] {
        var comps = URLComponents(url: endpoint.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "pipeline_tag", value: "text-to-image"),
                            URLQueryItem(name: "sort", value: "downloads"), URLQueryItem(name: "direction", value: "-1"), URLQueryItem(name: "limit", value: "25")]
        var request = URLRequest(url: comps.url!)
        if let t = token(), !t.isEmpty { request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { throw ImageStudioError.downloadFailed("Hugging Face search failed.") }
        return parse(data)
    }
}

public enum CivitaiSearch {
    static func family(_ base: String) -> ImageModelFamily {
        let b = base.lowercased()
        if b.contains("sdxl") || b.contains("pony") || b.contains("illustrious") { return .sdxl }
        if b.contains("flux") { return .flux }
        if b.contains("sd 3") { return .sd3 }
        if b.contains("sd 1") { return .sd15 }
        if b.contains("sd 2") { return .sd2 }
        return .other
    }

    public static func parse(_ data: Data) -> [ImageModelEntry] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String,
                  let version = (item["modelVersions"] as? [[String: Any]])?.first,
                  let files = version["files"] as? [[String: Any]] else { return nil }
            let candidates = files.filter { ($0["name"] as? String)?.lowercased().hasSuffix(".safetensors") == true }
            guard let file = candidates.first(where: { ($0["primary"] as? Bool) == true }) ?? candidates.first,
                  let fileName = file["name"] as? String, let link = (file["downloadUrl"] as? String) ?? (version["downloadUrl"] as? String),
                  let url = URL(string: link), url.scheme == "https" else { return nil }
            let kind: ImageModelKind = switch item["type"] as? String { case "LORA", "LoCon", "DoRA": .lora; case "Controlnet": .controlNet; case "VAE": .vae; case "TextualInversion": .embedding; case "Upscaler": .upscaler; default: .checkpoint }
            let sizeKB = (file["sizeKB"] as? NSNumber)?.doubleValue ?? 0
            let sha = ((file["hashes"] as? [String: Any])?["SHA256"] as? String)?.lowercased()
            let base = version["baseModel"] as? String ?? ""
            let commercial = (item["allowCommercialUse"] as? [String]) ?? []
            return ImageModelEntry(
                id: "civitai:\(id):\(version["id"] as? Int ?? 0)", name: name, kind: kind, family: family(base),
                summary: "Civitai · \(base)\((item["creator"] as? [String: Any])?["username"].map { " · by \($0)" } ?? "")",
                source: .url(url, fileName: fileName, sha256: sha), sizeBytes: Int64(sizeKB * 1024), license: "Set by the creator on Civitai",
                licenseURL: URL(string: "https://civitai.com/models/\(id)"), commercialUse: commercial.isEmpty ? nil : commercial.contains("Image") || commercial.contains("Sell"),
                gating: .open, engines: kind == .upscaler ? ["comfyui", "a1111"] : ["comfyui", "a1111", "drawthings"],
                notes: "Single-file checkpoint for ComfyUI, AUTOMATIC1111/Forge or Draw Things import. Some files need a Civitai API key; add it in Settings → Providers.", origin: "Civitai")
        }
    }

    public static func search(_ query: String, type: String? = nil, endpoint: URL = URL(string: "https://civitai.com")!, session: URLSession = .shared,
                              token: SecretProvider = { nil }) async throws -> [ImageModelEntry] {
        var comps = URLComponents(url: endpoint.appendingPathComponent("api/v1/models"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "sort", value: "Most Downloaded"),
                            URLQueryItem(name: "nsfw", value: "false")] + (type.map { [URLQueryItem(name: "types", value: $0)] } ?? [])
        var request = URLRequest(url: comps.url!)
        if let t = token(), !t.isEmpty { request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { throw ImageStudioError.downloadFailed("Civitai search failed.") }
        return parse(data)
    }
}
