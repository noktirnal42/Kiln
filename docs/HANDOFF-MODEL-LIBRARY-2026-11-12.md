# Handoff: model library and a better model picker (owner request, 2026-11-12)

The owner's words: "a better model picker/library: for local MLX and Ollama models we want to be able to add (download) and remove models. Ollama models can be downloaded from Ollama or Hugging Face. MLX from Hugging Face. We want it full featured."

Nothing of this is built. This document is the brief: what exists to build on, what the feature must do, the API facts to verify first, and how to prove it works. Read `docs/HANDOFF-CODEX-2026-11-12.md` first for how to work in this repository.

## Status (2026-11-13): the Ollama half is built; MLX and Hugging Face are not

Built and merged (branch `codex/ollama-library`): `Core/ModelLibrary/OllamaLibrary.swift` (list, loaded models, streaming pull with a free-space check against the first sized event and a 2 GB margin, delete of an exact installed name, name validation), `ModelLibraryState.swift` (shared state, the pull queue, cancel, audit records `models.pull.started/finished/failed/cancelled` and `models.removed`), `ModelLibraryTools.swift` (`models_installed`, `models_progress`, `models_pull`, `models_cancel`, `models_remove`, registered under the Lab activity; `docs/13` and the registry tests are in step) and `Modules/Chat/ModelLibrarySheet.swift`, opened from the model picker with "Add or remove local models…". Tests: `Tests/ModelLibraryTests` (in-process Ollama stub: validation, listing, progress, a full disk refused, an error in the stream, delete of an exact name, tool tiers, the shared state).

Seen on screen: the picker button, and the sheet listing the real installed models with sizes and quantizations from the live local Ollama. **Not seen:** a real download, a real removal, the progress bars, the removal confirmation, the sheet at narrow widths and in light mode. The API shapes (`/api/tags`, `/api/pull`, `/api/delete`, `/api/ps`) follow Ollama's documentation and the stream format is tested only against a stub; check a real pull of a small model with the owner present.

Defaults chosen where the brief asked the owner: the library is a sheet in the picker; agents can pull and remove (with approval); Kiln does not start or install Ollama; LM Studio's folder is not scanned.

**Still to build:** MLX downloads from Hugging Face into the shared cache (generalize `ImageModelDownloader`, do not write a second one), Hugging Face GGUF discovery with a variant chooser (Ollama can already pull `hf.co/<user>/<repo>:<quant>` by name), a remote catalog (Ollama has no documented listing API; the sheet has a short dated list of suggestions), richer picker sections and filters, pause and resume across a quit, a download indicator visible from anywhere in the app, and the `docs/qa/` screenshots.

## What the owner wants, as requirements

1. **Add (download) models** from inside Kiln:
   - **MLX models** from Hugging Face (typically the `mlx-community` organization), into the shared Hugging Face cache layout Kiln already reads.
   - **Ollama models** from the Ollama library, and from Hugging Face (GGUF repositories, which Ollama can pull as `hf.co/<user>/<repo>:<quant>`).
2. **Remove models**, with a confirmation that says exactly what will be deleted and how much disk it frees. Removing an Ollama model goes through Ollama; removing an MLX model deletes its folder in the shared cache.
3. **Browse and search** remote catalogs: filter by what the model can do (tools, vision, reasoning), size, context window, quantization, license and whether it fits this Mac.
4. **A better picker**: what is installed (local MLX and Ollama), what is running, hosted models, Apple models; search and filters; per-model details; an obvious way to add one. Installed versus available must be clear, and an unavailable model must never look selectable.
5. **Full-featured downloads**: a queue, progress (bytes and speed), pause or cancel, resume after a failure or a quit, disk-space checks before starting, integrity checks, clear errors, and a way to see what is downloading from anywhere in the app.
6. **Everything the parity rule requires** (`docs/17-PARITY-AND-BEYOND.md`): a service in `Core/`, a GUI, agent tools and MCP tools, an audit record for every state change, approvals, tests, and a screenshot of it working recorded under `docs/qa/`.

## What exists to build on

| Piece | Where | Use |
|---|---|---|
| Shared model store in the Hugging Face cache layout (`models--org--repo/snapshots/<commit>/…`), installed-model scan, `repoDirectory(_:)`, an off-pool scan with a cache (never scan on the cooperative pool; it starved the app once) | `Core/UniversalStore/UniversalModelStore.swift` | Where MLX downloads must land and what the picker lists as installed |
| Memory-fit verdict for a model on this Mac, and filtering and sorting of installed models | `InstalledModelCatalog` (same file), `Core/ModelLab/HardwareProfile.swift`, `Modules/ModelLab/ModelLabModelsView.swift` (the Lab Models tab already shows a Hugging Face search with fit verdicts) | The "fits this Mac" filter and badges |
| Hugging Face model search | `ModelLabModule.searchHuggingFaceModels`, tool `lab_search_models` (`Core/ModelLab/ModelLabAgentTools.swift`) | Start of the remote search; extend it with filters and file lists |
| A complete resumable downloader as a pattern: an actor with a queue, `*.incomplete` partial files continued with Range requests, SHA-256 and git-SHA-1 verification, a free-space check with a safety margin, a confirmation over 8 GB, gated-model handling with the user's own token, cancel, and an observer for progress | `Core/ImageStudio/ImageModelDownloader.swift` (with `ImageModelStore.swift` and the catalog sources in `ImageCatalogSources.swift`) | Reuse or generalize it for MLX downloads; do not write a second downloader from scratch |
| The Hugging Face token in the Keychain (the owner enters it in Settings; never read, print or log it) | `Core/Providers/ProviderKeys.swift` (`huggingface`) | Gated repositories |
| What the Ollama server says about each model (`/api/show`: capabilities such as tools, thinking and vision, and the trained context), the model list (`/api/tags`), and the runtime context Kiln uses for local models | `Core/Providers/OpenCodeProvider.swift` (`ShowInfo`, `runtimeContextTokens`) | Installed Ollama models and their capabilities |
| A picker with search, recents (now filtered to models that are offered), and model tags | `Modules/Chat/ModelPickerView.swift`, `ModelPickerRecents` | The place to redesign |
| Capability detection and the audit of local models | `docs/32-LOCAL-MODELS.md`, `Scripts/test-ollama-tools.sh` | What is known about which local models call tools reliably (small ones often do not) |
| Reasoning options per model | `Core/Reasoning/ReasoningOptions.swift` | Show what a model offers in its details |

## API facts to verify before building (do not trust this list blindly)

These are from the providers' documentation as understood on 2026-11-12. Confirm each against the live service and current docs, and record what you confirmed in `docs/`.

- **Ollama (local server, default `http://localhost:11434`):** `GET /api/tags` lists installed models; `POST /api/show` describes one; `POST /api/pull` with `{"model": "<name>", "stream": true}` streams newline-delimited JSON with `status`, `digest`, `total` and `completed`; `DELETE /api/delete` with `{"model": "<name>"}` removes a model; `GET /api/ps` lists loaded (running) models. Pulling from Hugging Face uses the model name `hf.co/<user>/<repo>` with an optional `:<quant>` tag. Kiln does not start the Ollama server: when it is not running, say so and explain how, rather than failing obscurely.
- **Ollama library catalog:** verify whether there is a supported listing API. As understood, `ollama.com/library` is a web page and there is no documented JSON search endpoint for it. If you need to read it, check the site's terms and robots rules first, prefer a documented API, and consider a curated, dated list of popular models as the honest fallback. Ollama Cloud models (names ending in `-cloud`) are hosted, not downloaded.
- **Hugging Face:** `GET https://huggingface.co/api/models` supports `search`, `filter` (for example `gguf`, `mlx`), `sort=downloads` and `limit`; `GET /api/models/<repo>` can list files with sizes (and LFS hashes when asked for blob metadata); files download from `https://huggingface.co/<repo>/resolve/<revision>/<path>`. Gated and private repositories need the user's token and, for gated ones, terms accepted on the model page in a browser; Kiln must never accept terms for the user (the image-model downloader already follows this rule). Respect rate limits and send a descriptive User-Agent.
- **MLX layout:** an MLX model is a Hugging Face repository (config, tokenizer, safetensors weights). Kiln reads the cache layout `models--org--repo/snapshots/<commit>/` with weights stored once in `blobs/` and linked from the snapshot. Reproduce that layout so other tools sharing the cache (the Hugging Face CLI, LM Studio) keep working, and record the commit hash you downloaded.
- **Removing an MLX model** deletes the repository's folder in the shared cache. That cache is shared with other tools, so the confirmation must say so, name the folder and the size, and never touch anything outside `models--org--repo`.

## Design guidance

- **Service first.** A `ModelLibraryService` in `Core/` (no UI dependency) that: lists installed models from both stores with source, size, quantization, context, capabilities and last use; searches remote catalogs (Hugging Face, Ollama); plans a download (files, total size, fits-this-Mac verdict, free-space check, license and gated status) before anything starts; runs downloads through one queue (generalize `ImageModelDownloader` rather than duplicating it; Ollama pulls are driven through its own API and report progress the same way); removes models; and publishes progress. The GUI, the agent tools and MCP all call it.
- **Approvals and safety.** A download is a network call and a disk write: tier it `write` with approval, check the host against the egress rules (`huggingface.co`, the CDN hosts it redirects to, and the Ollama registry), require confirmation over a size threshold, and never overwrite. A removal is destructive: tier `admin`, flag `isDestructive`, name what is deleted. Every state change records an audit event. Text from a model card or repository is untrusted data, never instructions.
- **Agent tools** (prefix `models_`, so add the group to `ToolFit.groupOrder` and the registry test prefix list): `models_installed` and `models_search` (read), `models_download` (write, approval), `models_progress` (read), `models_cancel` (write), `models_remove` (admin, approval). Declare capabilities in the activity descriptor. The model library probably belongs inside Lab or the picker rather than a new activity; decide, and keep `docs/13` and the registry test in step.
- **The picker.** Sections for installed local models (MLX and Ollama), running, hosted and Apple; search; filter chips for tools, vision, reasoning and "fits this Mac"; per-model details (size on disk, context, quantization, license, source, capabilities, reasoning options, last used); an "Add a model" flow with a variant chooser (GGUF files with sizes and quantizations) and a download queue that stays visible. Keep the picker usable at a narrow width and never offer a model whose provider is not available.
- **Honesty.** The memory-fit verdict is an estimate (it uses stored size and this Mac's hardware); say so. A successful download is not a working model: after a pull, load or `show` it and report whether it answers.

## Acceptance

- Unit tests with in-process fakes for the Hugging Face API and the Ollama API (`Tests/SlackTests/SlackTests.swift` has a working URLProtocol stub pattern; the image downloader's tests cover resume and verification): search results, a plan with sizes and a fit verdict, a resumed download after an interruption, a hash mismatch that is rejected, a disk-full refusal before anything is written, a gated repository without a token, cancel, remove with the exact path or model name, and the approval gating of every tool.
- A real download and a real removal of a small model of each kind with the owner present (an MLX model under a few hundred MB from `mlx-community`; a small Ollama model; one GGUF from Hugging Face through Ollama), recorded under `docs/qa/` with screenshots, and then a chat with each of them.
- On-screen checks of the picker and the library at the default and a narrow window width, light and dark.
- Docs: the wiki Model Store page, `docs/32-LOCAL-MODELS.md`, README and the site, each saying what was and was not verified. Run `sh Scripts/check-docs.sh`.

## Open questions for the owner

- Where the library lives (the Lab Models tab, the picker, or Settings), and whether removing a model should also be available to agents.
- Whether Kiln should offer to start or install Ollama when it is missing.
- Whether other local sources (LM Studio's folder, which Kiln does not scan today) should be listed.
