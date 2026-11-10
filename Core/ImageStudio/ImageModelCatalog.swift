import Foundation

public enum ImageModelKind: String, Codable, CaseIterable, Sendable {
    case checkpoint, lora, controlNet, vae, upscaler, refiner, embedding, other

    public var title: String {
        switch self {
        case .checkpoint: "Checkpoint"
        case .lora: "LoRA"
        case .controlNet: "ControlNet"
        case .vae: "VAE"
        case .upscaler: "Upscaler"
        case .refiner: "Refiner"
        case .embedding: "Embedding"
        case .other: "Other"
        }
    }
}

public enum ImageModelFamily: String, Codable, CaseIterable, Sendable {
    case sd15, sd2, sdxl, sd3, flux, qwen, playground, other

    public var title: String {
        switch self {
        case .sd15: "SD 1.5"
        case .sd2: "SD 2.x"
        case .sdxl: "SDXL"
        case .sd3: "SD 3.5"
        case .flux: "FLUX"
        case .qwen: "Qwen-Image"
        case .playground: "Playground"
        case .other: "Other"
        }
    }
}

/// Where the files come from. Kiln only ever downloads over HTTPS from these hosts.
public enum ImageModelSource: Codable, Equatable, Sendable {
    /// A Hugging Face repository; `files` are paths inside it (an `.fp16.` twin is preferred automatically when `preferHalf`).
    case huggingFace(repo: String, files: [String], preferHalf: Bool)
    /// One file at a URL (Civitai's download endpoint, a Draw Things `.ckpt`, a release asset).
    case url(URL, fileName: String, sha256: String?)
    /// Several files fetched together (a Draw Things checkpoint with its encoders). `sha256` is aligned with `urls`; "" = unknown.
    case files(urls: [URL], fileNames: [String], sha256: [String])

    public var label: String {
        switch self {
        case .huggingFace(let repo, _, _): "huggingface.co/\(repo)"
        case .url(let url, _, _): url.host ?? url.absoluteString
        case .files(let urls, _, _): urls.first?.host ?? "files"
        }
    }
}

public enum ImageModelGating: String, Codable, Sendable {
    /// Anyone can download.
    case open
    /// Hugging Face asks the user to accept terms on the model page and to sign in with a token. Kiln never accepts for them.
    case termsAndToken
    /// A Civitai file that needs the user's API key.
    case civitaiKey
}

public struct ImageModelEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: ImageModelKind
    public var family: ImageModelFamily
    public var summary: String
    public var source: ImageModelSource
    /// Download size for the files Kiln fetches (checked against the host on 2026-11-09 for curated entries).
    public var sizeBytes: Int64
    public var license: String
    public var licenseURL: URL?
    /// False for non-commercial licences such as FLUX.1 dev and SDXL-Turbo's community licence. Nil when unclear.
    public var commercialUse: Bool?
    public var gating: ImageModelGating
    /// Engine ids that can use the files as downloaded. Empty means "download only: no engine in Kiln runs this yet".
    public var engines: [String]
    public var distilled: Bool
    public var defaultSteps: Int
    public var defaultGuidance: Double
    public var nativeSide: Int
    public var notes: String?
    /// Where the entry was listed (curated, Draw Things, Hugging Face, Civitai).
    public var origin: String

    public init(id: String, name: String, kind: ImageModelKind = .checkpoint, family: ImageModelFamily, summary: String,
                source: ImageModelSource, sizeBytes: Int64, license: String, licenseURL: URL? = nil, commercialUse: Bool? = nil,
                gating: ImageModelGating = .open, engines: [String] = [], distilled: Bool = false, defaultSteps: Int = 25,
                defaultGuidance: Double = 7, nativeSide: Int = 1024, notes: String? = nil, origin: String = "curated") {
        self.id = id; self.name = name; self.kind = kind; self.family = family; self.summary = summary; self.source = source
        self.sizeBytes = sizeBytes; self.license = license; self.licenseURL = licenseURL; self.commercialUse = commercialUse
        self.gating = gating; self.engines = engines; self.distilled = distilled; self.defaultSteps = defaultSteps
        self.defaultGuidance = defaultGuidance; self.nativeSide = nativeSide; self.notes = notes; self.origin = origin
    }

    /// The text shown before a download: licence, gating and what "accepting" means. Kiln never accepts on the user's behalf.
    public var termsNotice: String {
        var lines = ["License: \(license)."]
        if commercialUse == false { lines.append("Non-commercial use only unless you hold a separate licence from the publisher.") }
        switch gating {
        case .open: break
        case .termsAndToken:
            lines.append("Hugging Face gates this model: open its page, read and accept the publisher's terms yourself, and add your Hugging Face token in Settings → Providers. Kiln cannot accept terms for you.")
        case .civitaiKey:
            lines.append("Civitai needs your API key for this file; add it in Settings → Providers.")
        }
        if let notes, !notes.isEmpty { lines.append(notes) }
        return lines.joined(separator: " ")
    }

    public var isLargeDownload: Bool { sizeBytes > ImageModelEntry.confirmThreshold }
    /// Above this the app asks for an explicit confirmation before it queues a download.
    public static let confirmThreshold: Int64 = 8 * 1_000_000_000
}

/// The built-in list. Sizes and licences were read from the hosts on 2026-11-09; the downloader still resolves the exact
/// file list, sizes and checksums from the host at download time.
public enum CuratedImageCatalog {
    static func hf(_ repo: String, _ files: [String], half: Bool = true) -> ImageModelSource {
        .huggingFace(repo: repo, files: files, preferHalf: half)
    }

    static let sd2Files = ["model_index.json"] + DiffusionLayout.sd2Files
    static let sdxlFiles = ["model_index.json"] + DiffusionLayout.sdxlFiles
    static let gb: Int64 = 1_000_000_000
    static let mb: Int64 = 1_000_000

    static let stabilityCommunity = URL(string: "https://stability.ai/license")
    static let openrail = URL(string: "https://huggingface.co/spaces/CompVis/stable-diffusion-license")

    public static let entries: [ImageModelEntry] = [
        // Checkpoints the in-process engine runs
        ImageModelEntry(id: "sd-turbo", name: "SD-Turbo", family: .sd2,
                        summary: "SD 2.1 distilled to 1–4 steps at 512 px. The smallest model Kiln runs in-process; a good first download.",
                        source: hf("stabilityai/sd-turbo", sd2Files), sizeBytes: 2_580 * mb, license: "Stability AI community licence (research and non-commercial; commercial use needs Stability's licence)",
                        licenseURL: stabilityCommunity, commercialUse: nil, engines: ["mlx"], distilled: true, defaultSteps: 2, defaultGuidance: 0, nativeSide: 512),
        ImageModelEntry(id: "sdxl-turbo", name: "SDXL-Turbo", family: .sdxl,
                        summary: "SDXL distilled to 1–4 steps at 512 px (its native size). Needs about 7 GB of disk and several GB of memory while generating.",
                        source: hf("stabilityai/sdxl-turbo", sdxlFiles), sizeBytes: 6_940 * mb, license: "Stability AI Non-Commercial Community licence",
                        licenseURL: URL(string: "https://huggingface.co/stabilityai/sdxl-turbo/blob/main/LICENSE.md"), commercialUse: false,
                        engines: ["mlx"], distilled: true, defaultSteps: 2, defaultGuidance: 0, nativeSide: 512),
        ImageModelEntry(id: "sdxl-base-1.0", name: "SDXL base 1.0", family: .sdxl,
                        summary: "The reference SDXL model, 1024 px, 20–40 steps with guidance around 6–7.",
                        source: hf("stabilityai/stable-diffusion-xl-base-1.0", sdxlFiles), sizeBytes: 6_940 * mb, license: "CreativeML OpenRAIL++-M",
                        licenseURL: URL(string: "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/blob/main/LICENSE.md"), commercialUse: true,
                        engines: ["mlx"], defaultSteps: 30, defaultGuidance: 6.5, nativeSide: 1024),
        ImageModelEntry(id: "juggernaut-xl-v9", name: "Juggernaut XL v9", family: .sdxl,
                        summary: "Popular photorealistic SDXL fine-tune.", source: hf("RunDiffusion/Juggernaut-XL-v9", sdxlFiles), sizeBytes: 6_940 * mb,
                        license: "CreativeML OpenRAIL-M", licenseURL: openrail, commercialUse: true, engines: ["mlx"], defaultSteps: 30, defaultGuidance: 6, nativeSide: 1024),
        ImageModelEntry(id: "realvisxl-v5", name: "RealVisXL V5.0", family: .sdxl,
                        summary: "Photorealistic SDXL fine-tune.", source: hf("SG161222/RealVisXL_V5.0", sdxlFiles), sizeBytes: 6_940 * mb,
                        license: "CreativeML OpenRAIL++-M", licenseURL: URL(string: "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/blob/main/LICENSE.md"), commercialUse: true,
                        engines: ["mlx"], defaultSteps: 30, defaultGuidance: 5, nativeSide: 1024),
        ImageModelEntry(id: "dreamshaper-xl-v2-turbo", name: "DreamShaper XL v2 Turbo", family: .sdxl,
                        summary: "Versatile SDXL fine-tune distilled to about 6 steps.", source: hf("Lykon/dreamshaper-xl-v2-turbo", sdxlFiles), sizeBytes: 6_940 * mb,
                        license: "CreativeML OpenRAIL++-M", licenseURL: URL(string: "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/blob/main/LICENSE.md"), commercialUse: true,
                        engines: ["mlx"], distilled: true, defaultSteps: 6, defaultGuidance: 2, nativeSide: 1024),
        ImageModelEntry(id: "playground-v2.5", name: "Playground v2.5", family: .playground,
                        summary: "1024 px aesthetic-tuned SDXL-architecture model.", source: hf("playgroundai/playground-v2.5-1024px-aesthetic", sdxlFiles), sizeBytes: 6_940 * mb,
                        license: "Playground v2.5 community licence", licenseURL: URL(string: "https://huggingface.co/playgroundai/playground-v2.5-1024px-aesthetic/blob/main/LICENSE.md"),
                        commercialUse: nil, engines: ["mlx"], defaultSteps: 30, defaultGuidance: 3, nativeSide: 1024,
                        notes: "Uses EDM sampling, which Kiln's in-process engine does not implement, so results with it may look off; Draw Things runs it natively."),

        // Single-file checkpoints for the external engines (ComfyUI, AUTOMATIC1111 and Forge read these)
        ImageModelEntry(id: "sd-1.5", name: "Stable Diffusion 1.5", family: .sd15,
                        summary: "The classic 512 px model and the base of most LoRAs and ControlNets.",
                        source: hf("stable-diffusion-v1-5/stable-diffusion-v1-5", ["v1-5-pruned-emaonly.safetensors"], half: false), sizeBytes: 4_265 * mb,
                        license: "CreativeML OpenRAIL-M", licenseURL: openrail, commercialUse: true, engines: ["comfyui", "a1111"], defaultSteps: 25, defaultGuidance: 7.5, nativeSide: 512,
                        notes: "Kiln's in-process engine does not run SD 1.5. Save it into your ComfyUI or Forge checkpoints folder."),
        ImageModelEntry(id: "sdxl-refiner-1.0", name: "SDXL refiner 1.0", kind: .refiner, family: .sdxl,
                        summary: "Second-stage SDXL model for finishing detail.", source: hf("stabilityai/stable-diffusion-xl-refiner-1.0", ["sd_xl_refiner_1.0.safetensors"], half: false),
                        sizeBytes: 6_076 * mb, license: "CreativeML OpenRAIL++-M", commercialUse: true, engines: ["comfyui", "a1111"], defaultSteps: 20, defaultGuidance: 6, nativeSide: 1024),
        ImageModelEntry(id: "sd-3.5-medium", name: "Stable Diffusion 3.5 Medium", family: .sd3,
                        summary: "2.5B-parameter MMDiT model, 1 MP.", source: hf("stabilityai/stable-diffusion-3.5-medium", ["sd3.5_medium.safetensors"], half: false),
                        sizeBytes: 5_107 * mb, license: "Stability AI Community licence (free below US$1M annual revenue)", licenseURL: stabilityCommunity, commercialUse: nil,
                        gating: .termsAndToken, engines: ["comfyui"], defaultSteps: 28, defaultGuidance: 4.5, nativeSide: 1024,
                        notes: "Runs in ComfyUI or Draw Things; the in-process engine does not run SD 3.5."),
        ImageModelEntry(id: "sd-3.5-large", name: "Stable Diffusion 3.5 Large", family: .sd3,
                        summary: "8B-parameter MMDiT model, 1 MP.", source: hf("stabilityai/stable-diffusion-3.5-large", ["sd3.5_large.safetensors"], half: false),
                        sizeBytes: 16_460 * mb, license: "Stability AI Community licence (free below US$1M annual revenue)", licenseURL: stabilityCommunity, commercialUse: nil,
                        gating: .termsAndToken, engines: ["comfyui"], defaultSteps: 28, defaultGuidance: 4.5, nativeSide: 1024,
                        notes: "16 GB; needs ComfyUI and a lot of memory."),
        ImageModelEntry(id: "flux1-schnell", name: "FLUX.1 [schnell]", family: .flux,
                        summary: "12B rectified-flow model that makes good images in 1–4 steps. Apache-2.0.",
                        source: hf("black-forest-labs/FLUX.1-schnell", ["flux1-schnell.safetensors", "ae.safetensors"], half: false), sizeBytes: 24_118 * mb,
                        license: "Apache-2.0", licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0"), commercialUse: true, gating: .termsAndToken,
                        engines: ["comfyui"], distilled: true, defaultSteps: 4, defaultGuidance: 0, nativeSide: 1024,
                        notes: "24 GB as published: too large for the in-process engine, and it also needs the T5 and CLIP text encoders. Draw Things offers quantized FLUX.1 schnell builds; run it there or in ComfyUI."),
        ImageModelEntry(id: "flux1-dev", name: "FLUX.1 [dev]", family: .flux,
                        summary: "12B guidance-distilled model, higher quality than schnell. Non-commercial licence.",
                        source: hf("black-forest-labs/FLUX.1-dev", ["flux1-dev.safetensors", "ae.safetensors"], half: false), sizeBytes: 24_138 * mb,
                        license: "FLUX.1 [dev] Non-Commercial License", licenseURL: URL(string: "https://huggingface.co/black-forest-labs/FLUX.1-dev/blob/main/LICENSE.md"), commercialUse: false,
                        gating: .termsAndToken, engines: ["comfyui"], defaultSteps: 28, defaultGuidance: 3.5, nativeSide: 1024,
                        notes: "Non-commercial. 24 GB as published; Draw Things offers quantized builds that are much smaller."),
        // Qwen-Image and the newer FLUX/Z-Image/HiDream families are listed from Draw Things' own catalog (quantized builds).

        // LoRAs
        ImageModelEntry(id: "lcm-lora-sdxl", name: "LCM LoRA (SDXL)", kind: .lora, family: .sdxl,
                        summary: "Turns any SDXL model into a 4-step model (use guidance 1, LCM sampler).", source: hf("latent-consistency/lcm-lora-sdxl", ["pytorch_lora_weights.safetensors"], half: false),
                        sizeBytes: 394 * mb, license: "CreativeML OpenRAIL++-M", commercialUse: true, engines: ["comfyui", "a1111", "drawthings"], defaultSteps: 4, defaultGuidance: 1),
        ImageModelEntry(id: "lcm-lora-sd15", name: "LCM LoRA (SD 1.5)", kind: .lora, family: .sd15,
                        summary: "Turns any SD 1.5 model into a 4-step model.", source: hf("latent-consistency/lcm-lora-sdv1-5", ["pytorch_lora_weights.safetensors"], half: false),
                        sizeBytes: 135 * mb, license: "CreativeML OpenRAIL++-M", commercialUse: true, engines: ["comfyui", "a1111", "drawthings"], defaultSteps: 4, defaultGuidance: 1),
        ImageModelEntry(id: "sdxl-lightning-4step-lora", name: "SDXL-Lightning 4-step LoRA", kind: .lora, family: .sdxl,
                        summary: "ByteDance's 4-step distillation as a LoRA for SDXL models.", source: hf("ByteDance/SDXL-Lightning", ["sdxl_lightning_4step_lora.safetensors"], half: false),
                        sizeBytes: 394 * mb, license: "CreativeML OpenRAIL++-M", commercialUse: true, engines: ["comfyui", "a1111", "drawthings"], defaultSteps: 4, defaultGuidance: 0),
        ImageModelEntry(id: "sdxl-lightning-8step-lora", name: "SDXL-Lightning 8-step LoRA", kind: .lora, family: .sdxl,
                        summary: "ByteDance's 8-step distillation as a LoRA for SDXL models.", source: hf("ByteDance/SDXL-Lightning", ["sdxl_lightning_8step_lora.safetensors"], half: false),
                        sizeBytes: 394 * mb, license: "CreativeML OpenRAIL++-M", commercialUse: true, engines: ["comfyui", "a1111", "drawthings"], defaultSteps: 8, defaultGuidance: 0),

        // ControlNets
        ImageModelEntry(id: "controlnet-canny-sdxl", name: "ControlNet Canny (SDXL)", kind: .controlNet, family: .sdxl,
                        summary: "Edge-guided generation for SDXL.", source: hf("diffusers/controlnet-canny-sdxl-1.0", ["diffusion_pytorch_model.fp16.safetensors", "config.json"], half: false),
                        sizeBytes: 2_502 * mb, license: "CreativeML OpenRAIL++-M", commercialUse: true, engines: ["comfyui", "a1111"]),
        ImageModelEntry(id: "controlnet-canny-sd15", name: "ControlNet Canny (SD 1.5)", kind: .controlNet, family: .sd15,
                        summary: "Edge-guided generation for SD 1.5.", source: hf("lllyasviel/control_v11p_sd15_canny", ["diffusion_pytorch_model.fp16.safetensors", "config.json"], half: false),
                        sizeBytes: 723 * mb, license: "CreativeML OpenRAIL", commercialUse: true, engines: ["comfyui", "a1111"]),

        // VAEs
        ImageModelEntry(id: "sdxl-vae-fp16-fix", name: "SDXL VAE (fp16 fix)", kind: .vae, family: .sdxl,
                        summary: "Fixes the black or NaN images SDXL's VAE can give in half precision.", source: hf("madebyollin/sdxl-vae-fp16-fix", ["sdxl_vae.safetensors"], half: false),
                        sizeBytes: 335 * mb, license: "MIT", commercialUse: true, engines: ["comfyui", "a1111"]),
        ImageModelEntry(id: "sd-vae-ft-mse", name: "SD VAE ft-MSE", kind: .vae, family: .sd15,
                        summary: "The VAE most SD 1.5 workflows use.", source: hf("stabilityai/sd-vae-ft-mse", ["diffusion_pytorch_model.safetensors"], half: false),
                        sizeBytes: 335 * mb, license: "MIT", commercialUse: true, engines: ["comfyui", "a1111"]),

        // Upscalers
        ImageModelEntry(id: "realesrgan-x4", name: "Real-ESRGAN ×4", kind: .upscaler, family: .other,
                        summary: "AI upscaler, 4× (PyTorch weights for ComfyUI, AUTOMATIC1111 and Forge upscaler folders).", source: hf("ai-forever/Real-ESRGAN", ["RealESRGAN_x4.pth"], half: false),
                        sizeBytes: 67 * mb, license: "BSD-3-Clause", commercialUse: true, engines: ["comfyui", "a1111"]),
        ImageModelEntry(id: "realesrgan-x2", name: "Real-ESRGAN ×2", kind: .upscaler, family: .other,
                        summary: "AI upscaler, 2×.", source: hf("ai-forever/Real-ESRGAN", ["RealESRGAN_x2.pth"], half: false),
                        sizeBytes: 67 * mb, license: "BSD-3-Clause", commercialUse: true, engines: ["comfyui", "a1111"]),
    ]
}

/// Which files a diffusers-layout folder needs for the in-process engine, so the downloader and the engine agree.
public enum DiffusionLayout {
    public static let sd2Files = [
        "unet/config.json", "unet/diffusion_pytorch_model.safetensors", "text_encoder/config.json", "text_encoder/model.safetensors",
        "vae/config.json", "vae/diffusion_pytorch_model.safetensors", "scheduler/scheduler_config.json",
        "tokenizer/vocab.json", "tokenizer/merges.txt",
    ]
    public static let sdxlFiles = sd2Files + [
        "text_encoder_2/config.json", "text_encoder_2/model.safetensors", "tokenizer_2/vocab.json", "tokenizer_2/merges.txt",
    ]
}
