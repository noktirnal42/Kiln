# Model Store

Kiln keeps one shared **local model store** so language models are downloaded once and reused by Lab, Playground and the MLX provider.

## Layout

The store follows the Hugging Face cache layout (`models--org--repo/snapshots/…`). Point Kiln at it in **Settings → Local model store**, choosing the `hub` folder (or the `huggingface` folder above it). Only language models (architectures ending in `CausalLM`) are listed; speech, audio and vision-only repositories in the same cache are skipped. Lab → Models also lists them, and the Playground reads them from disk instead of downloading.

Where the store lives (internal or external drive) is up to you; models can be large.

## Behavior to know

- Scanning stats every weight file, which takes minutes on a slow external drive. Kiln runs the scan off the main task pool and caches it for 120 seconds; the model picker waits on it and it re-runs when you open it.
- Agents can register a Hub repository (`lab_register_model`, downloads nothing) and remove a library entry (`lab_delete_model`, which never touches the cache). LoRA and distillation tools use only cached base models unless `allow_download` is passed.
- LM Studio's own model folder and Ollama's model directory are not scanned. Ollama uses only what its running server knows.
- Kiln never deletes the shared cache.

## Image models

A catalog and downloader for image models is on the [[Roadmap]] and is not part of the current build.

---

**Verified status.** Scan behavior and the CausalLM filter come from `docs/11-CURRENT-STATE.md`; the scan mitigation and cache time come from `docs/KNOWN-ISSUES.md`. MLX chat from a drive store was verified. **Not checked:** first-run store selection on a new Mac in this pass, and the scan time on slow media after further optimization.
