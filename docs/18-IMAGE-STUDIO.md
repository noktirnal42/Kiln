# Image studio (2026-11-09)

What it is, what was measured on this Mac, and what is not done. Machine: MacBook Pro, Apple M3 Pro, 18 GB, macOS 27.0.1, Xcode 27.1.
Disk was tight throughout (about 10 GB free on both the internal and the external drive), which limited what could be tried.

## Phase 0: engine research

| Engine | Verdict | Evidence |
|---|---|---|
| **MLX Swift** (`mlx-swift-examples` `StableDiffusion`, main at ef1084d) | **Chosen, in-process.** SD 2.x and SDXL architectures; text-to-image and image-to-image. No inpaint, LoRA, ControlNet or FLUX. | Read the source. Upstream keeps its configuration internals private, presets want fp32 SDXL-Turbo (about 14 GB), and it declares a public `Image` type that would shadow SwiftUI's, so it is **vendored as a module** (`Packages/KilnDiffusion`, MIT, upstream licence kept) that loads a diffusers folder from disk, prefers `.fp16.safetensors`, and gives the SD 2.x path image-to-image and a distilled (Euler-ancestral) sampler. |
| **Core ML Stable Diffusion** (`apple/ml-stable-diffusion`) | **Not included.** SD 1.x/2.x/SDXL, no FLUX, last tag 1.1.1 (May 2024). Its Swift product is also called `StableDiffusion`, which collides with the MLX one. | Not measured: no Core ML models were downloaded (disk). |
| **Draw Things** local API | **Chosen, external.** A1111-style HTTP API (`/sdapi/v1/txt2img`, `img2img`), port 7860 when its API server is on. Gives FLUX, SD 3.5, Qwen-Image, LoRA, inpaint. | Installed here, but its API server was **off** and it has no models, so the engine was **not run against it**. The request shape comes from community clients, not from running it. |
| **ComfyUI** | **Chosen, external** (workflow API on 8188). | Not installed here; workflow graph built and unit-tested for shape only. |
| **AUTOMATIC1111 / Forge** | **Chosen, external**, same engine class as Draw Things, port 7861 by default. | Not installed here; not run. |
| **FLUX.1 schnell** | No in-process route. 24 GB as published and gated on Hugging Face. | Not downloaded. Reachable through Draw Things (quantized builds) or ComfyUI once those run. |

Draw Things publishes its catalogue at `https://models.drawthings.ai/models.json` (270 models), `loras.json`, `controlnets.json`; files download from `https://static.libnnc.org/<file>` (checked with a HEAD request). They are Draw Things `.ckpt` files only Draw Things can use, so they are saved into its Models folder and listed with that caveat.

## Phase 1 to 4: what exists

- `Core/ImageStudio/`: `ImageEngine` protocol and types, `MLXDiffusionEngine`, `A1111CompatibleEngine` (Draw Things, Forge), `ComfyUIEngine`, curated catalogue plus Draw Things, Hugging Face and Civitai sources, `ImageModelDownloader`, `ImageModelStore`, PNG metadata, history, prompt library, Lanczos upscale, outpaint canvas, queue, `ImageStudioService`, `ImageAgentTools`.
- `Modules/ImageStudio/`: activity "Images" (Create, Models, History), registered through `ImageStudioActivity` and `ActivityCatalog`.
- Tokens: Settings → Providers has `huggingface` and `civitai` rows (Keychain via `ProviderKeyStore`). Tokens are sent only as a bearer header to their own host, dropped on a cross-host redirect, never put in a URL, and no terms are ever accepted for the user.

## Measurements (real, this Mac)

Model `stabilityai/sd-turbo`, fp16, MLX engine, 512 x 512, 2 steps, guidance 0.

- Download: 2.58 GB through Kiln's own downloader into the universal store on the external drive; every weight file's SHA-256 matches the published LFS id (re-checked with `shasum`).
- First generation including model load from the external drive: **63.7 s**. Second generation (model loaded): **41.9 s**. These are slow for a 2-step model. Other build jobs from sibling sessions were running on the same Mac, so treat them as an upper bound; no clean-machine run was made.
- Image to image (4 steps, strength 0.6): completed.
- Memory was not profiled (the test only printed physical memory). SDXL-Turbo, SDXL base and the fine-tunes were **not** run: about 7 GB each and no room to download them while staying inside the disk margin.

Pictures from the run are in `docs/qa/image-studio/`: `sd-turbo-fox-seed7.png` (text to image, seed 7) and `sd-turbo-fox-img2img-night.png` (image to image from it). Both were looked at: a coherent red fox in snow, and the same fox recast at night.

## Verified

- Unit tests (`Tests/ImageStudioTests`, loopback server, no internet): PNG metadata round trip and validity, catalogue parsing (curated, Draw Things, Hugging Face, Civitai), downloader (hub layout, resume with Range after a dropped connection, checksum mismatch discards, disk-space refusal, gated 401 message, bearer header only), engine selection and refusal reasons, outpaint canvas, upscale, styles, prompt library, ComfyUI workflow shape, queue order, cancel and failure, tool specs and permission levels, read-only offer set.
- Live test (opt-in `TEST_RUNNER_KILN_LIVE_IMAGE=1`): download (or reuse), text to image, image to image, embedded settings read back.

## Not done or not verified

- The app was not launched for this work (shared bundle id), so **the GUI has not been seen running**. No screenshot.
- Draw Things, ComfyUI and Forge engines have not been run against a real server.
- SDXL, SDXL-Turbo, FLUX, SD 3.5, Playground: not generated. Playground v2.5 needs EDM sampling the MLX engine lacks and is flagged in its catalogue note.
- Inpaint and outpaint, LoRA stack and samplers exist only for external engines; the MLX engine disables them with the reason.
- ControlNet, face fix, AI upscalers and a LoRA path in MLX are not implemented. "Upscale" is Lanczos resampling and says so.
- Catalogue "Download" of Draw Things files uses a HEAD request for size and has no published checksums for most files (verified by size only).
- The catalogue sizes for curated entries were read on 2026-11-09; the downloader re-resolves sizes and checksums from the host each time.
