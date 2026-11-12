# Model Store

This page describes the development source; packaged releases can lag behind it.

Kiln can use a shared Hugging Face cache for MLX models across Lab, Playground and the MLX provider. Ollama maintains its own runtime-specific store; choosing the Hugging Face cache in Kiln does not configure or move Ollama models.

## Layout

The store follows the Hugging Face cache layout (`models--org--repo/snapshots/…`). Point Kiln at it in **Settings → Local model store**, choosing the `hub` folder (or the `huggingface` folder above it). Only language models (architectures ending in `CausalLM`) are listed; speech, audio and vision-only repositories in the same cache are skipped. Lab → Models also lists them, and the Playground reads them from disk instead of downloading.

Where the store lives (internal or external drive) is up to you; models can be large.

## Behavior to know

- Scanning stats every weight file, which takes minutes on a slow external drive. Kiln runs the scan off the main task pool and caches it for 120 seconds; the model picker waits on it and it re-runs when you open it.
- Agents can register a Hub repository (`lab_register_model`, downloads nothing) and remove a library entry (`lab_delete_model`, which never touches the cache). LoRA and distillation tools use only cached base models unless `allow_download` is passed.
- LM Studio's own model folder and Ollama's model directory are not scanned. Ollama uses only what its running server knows.
- Kiln never deletes the shared cache.
- Lab's installed-model list can be filtered by name and estimated memory fit, and sorted by name or size. The estimate uses the model's stored size and the current Mac's hardware; it does not establish that an architecture or a particular context length will run.

## Image models

Image Studio includes an image-model catalog and downloader. A unified catalog for downloading and deleting both Ollama and MLX language models is planned; the existing Hugging Face language-model search registers references and does not itself download them.

---

**Verified status.** An unsandboxed live test on 2026-11-10 exercised MLX text, conversation history and tool-result continuation using a model on the drive. Native MLX tool-call generation and vision remain unverified and are not advertised by this provider. First-run store selection and scan performance on other Macs have not been checked in this pass.
