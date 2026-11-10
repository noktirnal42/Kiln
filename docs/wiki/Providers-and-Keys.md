# Providers and Keys

Catalog model ids are `<provider>-<model>`; the registry hands each provider the bare model name.

| Provider | Chat | Tool use | Notes |
|---|---|---|---|
| Apple Foundation Models | yes | no | On-device |
| Ollama (local) | yes | yes | Only models the running server knows. Also accepts OpenAI-compatible local servers (LM Studio, vLLM, Jan) |
| Ollama Cloud | yes | yes | Some models need paid credits and say so |
| NVIDIA NIM | yes | yes | Some models are slow to first token (see below) |
| OpenRouter | yes | yes | Free models come and go |
| Custom endpoint | yes | yes | Any OpenAI-compatible URL, set in Settings |
| MLX (local) | yes | no | Models from the shared Hugging Face cache; first load can take ~45 s from a drive |

Reasoning is turned off for models the catalog says cannot reason. A reply that is exactly one JSON call to an offered tool is accepted as that call, because small local models write calls as text.

## Keys

Open **Settings (⌘,)**. Each provider has a field with a "Get an API key" link. Keys are stored in the **macOS Keychain**; only the last four characters are shown. They go only to the provider they belong to.

- Never put a key in source, a fixture, a screenshot, a log or an issue.
- A catalog listing does not mean your account can call a model; a listed model may return a payment or 404 error.
- Changing signing identity can make macOS ask for your login password once per stored key; choose Always Allow.

## Reliability

Plain chat and reliable tool use are different. The local `qwen2.5-coder:3b` model has failed real tool and swarm tests; a hosted tool-capable model completed them. Hosted models can be slow to first token (a 90 s first-chunk watchdog fails with a clear message instead of waiting for the transport timeout).

## Apple Private Cloud Compute

An `ApplePrivateCloudProvider` is **in development and untested**. It is a separate, explicitly selected provider that requires macOS 27 and system availability. It has not been tried with an entitlement-bearing signed build or a real request, and Apple's eligibility conditions (including a managed entitlement and App Store or TestFlight distribution) mean the current Developer ID distribution may not qualify. Do not assume it works.

---

**Verified status.** Chat was verified with real calls against each listed provider on 2026-11-01; timing behavior of NVIDIA NIM was probed on 2026-11-04. **Not checked:** any provider in this documentation pass (no keys were read or used), the custom endpoint beyond Ollama's `/v1`, and Private Cloud Compute (not tested).
