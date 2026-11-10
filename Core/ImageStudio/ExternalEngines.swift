import Foundation

// Engines that live in another program: Draw Things' local API server, AUTOMATIC1111 / Forge, ComfyUI.
// Each talks to a loopback URL the user can change. If nothing answers, the engine reports a setup state and never fakes output.

public enum LocalHTTP {
    static func isLoopback(_ url: URL) -> Bool { ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "") }

    public static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        config.connectionProxyDictionary = [:]   // loopback only; never via a proxy
        return URLSession(configuration: config)
    }

    static func json(_ url: URL, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 600, session: URLSession) async throws -> Any {
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = timeout
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ImageStudioError.failed("The engine answered \(status): \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
        }
        if data.isEmpty { return [String: Any]() }
        return try JSONSerialization.jsonObject(with: data)
    }
}

/// The AUTOMATIC1111 web API (`/sdapi/v1/…`), which Forge and Draw Things' API server also speak.
public struct A1111CompatibleEngine: ImageEngine {
    public let id: String
    public let displayName: String
    public let kind = ImageEngineKind.external
    public let baseURL: URL
    private let setupSteps: [String]
    private let session: URLSession

    public init(id: String, displayName: String, baseURL: URL, setupSteps: [String], session: URLSession = LocalHTTP.session()) {
        self.id = id; self.displayName = displayName; self.baseURL = baseURL; self.setupSteps = setupSteps; self.session = session
    }

    public static func drawThings(port: Int = 7860) -> A1111CompatibleEngine {
        A1111CompatibleEngine(id: "drawthings", displayName: "Draw Things", baseURL: URL(string: "http://127.0.0.1:\(port)")!, setupSteps: [
            "Open Draw Things.", "Settings → Advanced → turn on API Server (protocol HTTP, port \(port)).", "Pick a model in Draw Things, then come back here.",
        ])
    }

    public static func automatic1111(port: Int = 7861) -> A1111CompatibleEngine {
        A1111CompatibleEngine(id: "a1111", displayName: "AUTOMATIC1111 / Forge", baseURL: URL(string: "http://127.0.0.1:\(port)")!, setupSteps: [
            "Install AUTOMATIC1111 or Forge, then start it with --api --port \(port).", "Models go in its models/Stable-diffusion folder.",
        ])
    }

    private func url(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

    public func status() async -> ImageEngineStatus {
        guard LocalHTTP.isLoopback(baseURL) else { return .setup(reason: "\(displayName) must be on this Mac (localhost).", steps: []) }
        do {
            _ = try await LocalHTTP.json(url("sdapi/v1/options"), timeout: 3, session: session)
            return .ready("Answering at \(baseURL.absoluteString)")
        } catch {
            return .setup(reason: "\(displayName) is not answering at \(baseURL.absoluteString).", steps: setupSteps)
        }
    }

    public func capabilities(model: String?) async -> ImageEngineCapabilities {
        var samplers: [ImageSampler] = []
        if let list = try? await LocalHTTP.json(url("sdapi/v1/samplers"), timeout: 5, session: session) as? [[String: Any]] {
            samplers = list.compactMap { ($0["name"] as? String).map { ImageSampler(id: $0, name: $0) } }
        }
        var features: Set<ImageFeature> = [.textToImage, .imageToImage, .inpaint, .outpaint, .lora, .negativePrompt]
        if !samplers.isEmpty { features.insert(.samplers) }
        return ImageEngineCapabilities(supported: features,
                                       reasons: [.controlNet: "ControlNet is not wired up for \(displayName) in Kiln yet.", .samplers: "The engine listed no samplers."],
                                       samplers: samplers, maxBatch: 8, maxSide: 2048, minSide: 256, sideMultiple: 8)
    }

    public func models() async -> [EngineModel] {
        let list = (try? await LocalHTTP.json(url("sdapi/v1/sd-models"), timeout: 5, session: session) as? [[String: Any]]) ?? []
        return list.compactMap { item in
            guard let title = item["title"] as? String ?? item["model_name"] as? String else { return nil }
            return EngineModel(id: title, name: (item["model_name"] as? String) ?? title)
        }
    }

    public func generate(_ request: ImageGenerationRequest, progress: @escaping ImageProgressHandler) async throws -> [GeneratedPicture] {
        var prompt = request.prompt
        for lora in request.loras { prompt += " <lora:\(lora.name):\(lora.weight)>" }
        let seed = request.seed ?? Int64.random(in: 0..<Int64(Int32.max))
        var body: [String: Any] = [
            "prompt": prompt, "negative_prompt": request.negativePrompt, "seed": seed, "steps": request.steps,
            "cfg_scale": request.guidance, "width": request.width, "height": request.height, "batch_size": max(1, request.count), "n_iter": 1,
        ]
        if let sampler = request.sampler { body["sampler_name"] = sampler }
        if !request.model.isEmpty { body["override_settings"] = ["sd_model_checkpoint": request.model]; body["model"] = request.model }
        var endpoint = "sdapi/v1/txt2img"
        if request.task != .textToImage {
            endpoint = "sdapi/v1/img2img"
            guard let path = request.initImagePath, let data = FileManager.default.contents(atPath: path) else { throw ImageStudioError.invalid("This task needs a source image.") }
            body["init_images"] = [data.base64EncodedString()]
            body["denoising_strength"] = request.strength
            if request.task == .inpaint || request.task == .outpaint {
                guard let maskPath = request.maskPath, let mask = FileManager.default.contents(atPath: maskPath) else { throw ImageStudioError.invalid("Inpainting needs a mask.") }
                body["mask"] = mask.base64EncodedString(); body["inpainting_fill"] = 1; body["inpaint_full_res"] = false
            }
        }
        progress(ImageProgress(phase: "Waiting for \(displayName)"))
        let answer: Any = try await withTaskCancellationHandler {
            try await LocalHTTP.json(url(endpoint), method: "POST", body: body, session: session)
        } onCancel: {
            Task { _ = try? await LocalHTTP.json(url("sdapi/v1/interrupt"), method: "POST", body: [:], timeout: 5, session: session) }
        }
        guard let object = answer as? [String: Any], let images = object["images"] as? [String], !images.isEmpty else {
            throw ImageStudioError.failed("\(displayName) returned no images.")
        }
        var seeds: [Int64] = []
        if let info = object["info"] as? String, let data = info.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let all = parsed["all_seeds"] as? [NSNumber] { seeds = all.map(\.int64Value) }
        return images.enumerated().compactMap { index, b64 in
            let clean = b64.split(separator: ",").last.map(String.init) ?? b64
            return Data(base64Encoded: clean).map { GeneratedPicture(png: $0, seed: index < seeds.count ? seeds[index] : seed + Int64(index)) }
        }
    }
}

/// ComfyUI's HTTP API: a workflow graph is posted to `/prompt`, then `/history` is polled for the output file.
public struct ComfyUIEngine: ImageEngine {
    public let id = "comfyui"
    public let displayName = "ComfyUI"
    public let kind = ImageEngineKind.external
    public let baseURL: URL
    private let session: URLSession

    public init(port: Int = 8188, session: URLSession = LocalHTTP.session()) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!; self.session = session
    }

    private func url(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

    public func status() async -> ImageEngineStatus {
        do { _ = try await LocalHTTP.json(url("system_stats"), timeout: 3, session: session); return .ready("Answering at \(baseURL.absoluteString)") }
        catch { return .setup(reason: "ComfyUI is not answering at \(baseURL.absoluteString).", steps: ["Install ComfyUI and start it (python main.py --port \(baseURL.port ?? 8188)).", "Put checkpoints in ComfyUI/models/checkpoints."]) }
    }

    public func capabilities(model: String?) async -> ImageEngineCapabilities {
        let samplers = ["euler", "euler_ancestral", "dpmpp_2m", "dpmpp_sde", "dpmpp_2m_sde", "ddim", "uni_pc", "lcm"].map { ImageSampler(id: $0, name: $0) }
        return ImageEngineCapabilities(supported: [.textToImage, .imageToImage, .inpaint, .outpaint, .lora, .negativePrompt, .samplers],
                                       reasons: [.controlNet: "ControlNet workflows are not built by Kiln yet."], samplers: samplers, maxBatch: 8, maxSide: 2048, minSide: 256, sideMultiple: 8)
    }

    private func choices(_ node: String, _ field: String) async -> [String] {
        guard let info = try? await LocalHTTP.json(url("object_info/\(node)"), timeout: 5, session: session) as? [String: Any],
              let n = info[node] as? [String: Any], let input = n["input"] as? [String: Any], let req = input["required"] as? [String: Any],
              let f = req[field] as? [Any], let list = f.first as? [String] else { return [] }
        return list
    }

    public func models() async -> [EngineModel] {
        await choices("CheckpointLoaderSimple", "ckpt_name").map { EngineModel(id: $0, name: $0) }
            + (await choices("LoraLoader", "lora_name")).map { EngineModel(id: $0, name: $0, kind: .lora) }
    }

    private func upload(_ path: String) async throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else { throw ImageStudioError.invalid("Cannot read \(path).") }
        let boundary = "kiln-\(UUID().uuidString)"
        let name = "kiln-\(UUID().uuidString).png"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\nContent-Type: image/png\r\n\r\n"); body.append(data)
        add("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: url("upload/image")); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else { throw ImageStudioError.failed("ComfyUI refused the image upload.") }
        return name
    }

    /// The workflow graph for a request. Public so tests can check its shape without a running ComfyUI.
    public static func workflow(for request: ImageGenerationRequest, seed: Int64, sourceName: String?, maskName: String?) -> [String: Any] {
        var graph: [String: Any] = ["4": ["class_type": "CheckpointLoaderSimple", "inputs": ["ckpt_name": request.model]]]
        var model: [Any] = ["4", 0], clip: [Any] = ["4", 1]
        for (index, lora) in request.loras.enumerated() {
            let key = "lora\(index)"
            graph[key] = ["class_type": "LoraLoader", "inputs": ["model": model, "clip": clip, "lora_name": lora.name, "strength_model": lora.weight, "strength_clip": lora.weight]]
            model = [key, 0]; clip = [key, 1]
        }
        graph["6"] = ["class_type": "CLIPTextEncode", "inputs": ["text": request.prompt, "clip": clip]]
        graph["7"] = ["class_type": "CLIPTextEncode", "inputs": ["text": request.negativePrompt, "clip": clip]]
        var latent: [Any] = ["5", 0]
        var denoise = 1.0
        if let sourceName {
            graph["10"] = ["class_type": "LoadImage", "inputs": ["image": sourceName]]
            if let maskName {
                graph["11"] = ["class_type": "LoadImage", "inputs": ["image": maskName]]
                graph["12"] = ["class_type": "ImageToMask", "inputs": ["image": ["11", 0], "channel": "red"]]
                graph["13"] = ["class_type": "VAEEncode", "inputs": ["pixels": ["10", 0], "vae": ["4", 2]]]
                graph["14"] = ["class_type": "SetLatentNoiseMask", "inputs": ["samples": ["13", 0], "mask": ["12", 0]]]
                latent = ["14", 0]
            } else {
                graph["13"] = ["class_type": "VAEEncode", "inputs": ["pixels": ["10", 0], "vae": ["4", 2]]]
                latent = ["13", 0]
            }
            denoise = request.strength
        } else {
            graph["5"] = ["class_type": "EmptyLatentImage", "inputs": ["width": request.width, "height": request.height, "batch_size": max(1, request.count)]]
        }
        graph["3"] = ["class_type": "KSampler", "inputs": [
            "seed": seed, "steps": request.steps, "cfg": request.guidance, "sampler_name": request.sampler ?? "euler", "scheduler": "normal",
            "denoise": denoise, "model": model, "positive": ["6", 0], "negative": ["7", 0], "latent_image": latent]]
        graph["8"] = ["class_type": "VAEDecode", "inputs": ["samples": ["3", 0], "vae": ["4", 2]]]
        graph["9"] = ["class_type": "SaveImage", "inputs": ["filename_prefix": "kiln", "images": ["8", 0]]]
        return graph
    }

    public func generate(_ request: ImageGenerationRequest, progress: @escaping ImageProgressHandler) async throws -> [GeneratedPicture] {
        let seed = request.seed ?? Int64.random(in: 0..<Int64(Int32.max))
        var source: String?, mask: String?
        if request.task != .textToImage {
            guard let path = request.initImagePath else { throw ImageStudioError.invalid("This task needs a source image.") }
            source = try await upload(path)
            if request.task == .inpaint || request.task == .outpaint {
                guard let maskPath = request.maskPath else { throw ImageStudioError.invalid("Inpainting needs a mask.") }
                mask = try await upload(maskPath)
            }
        }
        let graph = Self.workflow(for: request, seed: seed, sourceName: source, maskName: mask)
        let queued = try await LocalHTTP.json(url("prompt"), method: "POST", body: ["prompt": graph, "client_id": "kiln"], session: session) as? [String: Any]
        guard let promptID = queued?["prompt_id"] as? String else { throw ImageStudioError.failed("ComfyUI did not accept the workflow: \(queued?["error"] ?? "unknown")") }
        progress(ImageProgress(phase: "ComfyUI is generating"))
        for _ in 0..<7200 {
            if Task.isCancelled {
                _ = try? await LocalHTTP.json(url("interrupt"), method: "POST", body: [:], timeout: 5, session: session)
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            guard let history = try? await LocalHTTP.json(url("history/\(promptID)"), timeout: 10, session: session) as? [String: Any],
                  let entry = history[promptID] as? [String: Any], let outputs = entry["outputs"] as? [String: Any] else { continue }
            var pictures: [GeneratedPicture] = []
            for (_, value) in outputs.sorted(by: { $0.key < $1.key }) {
                for image in ((value as? [String: Any])?["images"] as? [[String: Any]]) ?? [] {
                    guard let file = image["filename"] as? String else { continue }
                    var comps = URLComponents(url: url("view"), resolvingAgainstBaseURL: false)!
                    comps.queryItems = [URLQueryItem(name: "filename", value: file), URLQueryItem(name: "subfolder", value: image["subfolder"] as? String ?? ""),
                                        URLQueryItem(name: "type", value: image["type"] as? String ?? "output")]
                    let (data, _) = try await session.data(from: comps.url!)
                    pictures.append(GeneratedPicture(png: data, seed: seed + Int64(pictures.count)))
                }
            }
            if !pictures.isEmpty { return pictures }
            if let status = entry["status"] as? [String: Any], (status["status_str"] as? String) == "error" { throw ImageStudioError.failed("ComfyUI reported an error running the workflow.") }
        }
        throw ImageStudioError.failed("ComfyUI took too long.")
    }
}
