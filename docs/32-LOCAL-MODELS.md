# Local models: audit and recommendations (2026-11-11)

Why: the models installed through Ollama were mostly pulled 7 to 14 months ago. Newer generations (Qwen 3.5 / 3.6 / 3.8, Gemma 4, GLM 4.7, Granite 4.1) exist, and the owner wants
good abliterated or uncensored models for security and reverse-engineering work. Facts about sizes and tags below were read from `ollama.com` on 2026-11-11 (the tag lists change); statements about
quality come from community blog posts and model cards that this session could not verify, and are marked as such.

## The machine

Apple M3 Pro, **18 GB** unified memory, macOS 27. Practical limit: a model plus its context should stay under about 12 to 13 GB (Kiln's own working limit is 70% of memory). Ollama's model folder is
`/Volumes/Artificial_Intelligence_Machine_Learning/Ollama/models` on the external drive (90 GB used, **1.6 GB free after this session's pull**); the internal drive has about 20 GB free. First load of a model from that drive takes 45 s to 2 min.

## What was done

- Pulled `huihui_ai/qwen3.5-abliterated:9b` (6.6 GB): Ollama reports capabilities `completion, vision, tools, thinking` and a 256K trained context. **A real structured tool call worked** (`list_directory` with `path: "."`), which is the property Kiln's agent needs.
- Tried `huihui_ai/foundation-sec-abliterated:8b` (4.9 GB): **failed, the external drive is full**. The failed partial files were removed. Nothing else was deleted.
- Kiln now asks Ollama what each local model can do (`/api/show`) instead of guessing from its name (`Core/Providers/OpenCodeProvider.swift`: `parseShow`, `ShowInfo`), so new families need no code change; the name lists still cover Gemma 4, Devstral, GLM 4.7 and Qwen 3.x as a fallback.
  The window shown for a local model is now `min(trained context, 8192)`, because Kiln runs local models with `num_ctx` 8192 and the old 32768 for Qwen models made the meter wrong. Tests added.
- `Scripts/test-ollama-tools.sh <model>` shows a model's capabilities and whether it makes a structured tool call.

## Installed models and what to do with them

| Installed | Size | Verdict | Replace with |
|---|---|---|---|
| `gemma4:e4b` | 9.6 GB | Current generation. Keep. | |
| `huihui_ai/qwen3.5-abliterated:9b` | 6.6 GB | New this session. Uncensored general agent model with tools, vision, thinking. | |
| `qooba/qwen3-coder-30b-a3b-instruct:q3_k_m` | 14 GB | Still a good coder, heavy for 18 GB. Keep for coding only. | `huihui_ai/qwen3-coder-abliterated:30b-a3b-instruct-q3_K_M` (15 GB) if an uncensored coder is wanted; very tight |
| `qwen3-coder:30b` | 18 GB | Does not fit 18 GB RAM without swapping. | Remove; the q3 build above covers it |
| `richardyoung/mistral-7b-instruct-v0.3-abliterated` | 4.4 GB | Old (Mistral 7B v0.3, 2024). | `huihui_ai/qwen3.5-abliterated:9b` (installed), `huihui_ai/gemma-4-abliterated:12b` (7.6 GB) |
| `jayeshpandit2480/granite4-UNCENSORED` | 2.1 GB | Superseded. | `huihui_ai/granite4.1-abliterated:8b` (5.3 GB) |
| `SiliconBasedWorld/Qwen2.5-7B-Instruct-1M` | 4.7 GB | Old generation; long-context niche. | Qwen 3.5 |
| `qwen2.5-coder:7b`, `qwen2.5-coder:3b` | 4.7 / 1.9 GB | Writes tool calls as text; superseded. Keep 3b only as a fast fallback. | Qwen 3.5 9B, Qwen3-Coder |
| `mistral:latest`, `deepseek-coder:1.3b`, `gemma3:4b`, `granite3.3:8b`, `deepseek-r1:8b` | 4.4 / 0.8 / 3.3 / 4.9 / 5.2 GB | Older generations. | Qwen 3.5, Gemma 4, Granite 4.1 |
| `wissembijaui/qween-coder` | 2.0 GB | Unknown community upload. | Remove |
| `qwen3-vl:8b` | 6.1 GB | Vision is built into Qwen 3.5 and Gemma 4. | Can go once those are trusted |
| `nemotron-3-nano:4b` | 2.8 GB | Fine small model. Keep. | |
| `leckminartor/qwen3.5-uncensored:397b-cloud`, `qwen3-coder:480b-cloud`, `nemotron-3-super:cloud` | 0 (cloud) | Run on Ollama Cloud, which answered "payment required" on 2026-11-10. | Add credits or remove |

Removing the "replace" and "remove" rows would free roughly 40 GB. **None of it was removed: deleting the owner's models is the owner's call.** Commands (run one at a time, check `ollama list` after):

```sh
ollama rm mistral:latest deepseek-coder:1.3b gemma3:4b granite3.3:8b deepseek-r1:8b wissembijaui/qween-coder:latest
ollama rm richardyoung/mistral-7b-instruct-v0.3-abliterated:Q4_K_M jayeshpandit2480/granite4-UNCENSORED:latest SiliconBasedWorld/Qwen2.5-7B-Instruct-1M:latest
ollama rm qwen3-coder:30b
```

## Good picks for security and reverse-engineering work on this Mac

All are under the `huihui_ai/` namespace on Ollama (abliterated: refusal behaviour removed; this lowers general capability a little, and community uploads vary, so test each).

| Model | Size | Why | Status |
|---|---|---|---|
| `huihui_ai/qwen3.5-abliterated:9b` | 6.6 GB | Best all-round fit: tools, vision (screenshots of disassembly), thinking, 256K trained context | **Installed, tool call verified** |
| `huihui_ai/foundation-sec-abliterated:8b` | 4.9 GB | Abliterated build of a security-specialised 8B model (Cisco's Foundation-sec family, Llama 3.1 base: that lineage is what the tag name says, not verified here) | Not installed (disk). Check tool support with the script |
| `huihui_ai/baronllm-abliterated:8b` | 4.9 GB | Offensive-security fine-tune, abliterated | Not installed (disk). Check tool support |
| `huihui_ai/gemma-4-abliterated:12b` | 7.6 GB | Gemma 4 family (agentic and coder variants exist), fits comfortably | Not installed |
| `huihui_ai/granite4.1-abliterated:8b` | 5.3 GB | Small, fast, tool-friendly family | Not installed |
| `huihui_ai/gpt-oss-abliterated:20b-v2-q3_K_M` | 13 GB | Strong reasoner, but leaves little RAM for context on 18 GB | Not installed |
| `huihui_ai/Qwen3.8-abliterated:27b-q3_K` | 14 GB | Newest Qwen generation at 27B; a blog calls it the best uncensored pick for 16 to 24 GB (unverified); borderline here and slow | Not installed |
| `huihui_ai/Qwen3.6-abliterated`, `qwen3-coder-next-abliterated`, `glm-4.7-flash-abliterated`, `devstral-2-abliterated` | 17 to 75 GB | Too big for 18 GB | Skip until the hardware changes |

Apple-silicon speed: MLX 4-bit builds exist for some (for example a community `Qwen3.6-27B-abliterated-4bit-mlx`); Kiln's MLX provider reads them from the Hugging Face cache. Not tested.

## Todo for Codex or the owner

1. **Free space on the external drive** (owner decides which models go; commands above), then `ollama pull huihui_ai/foundation-sec-abliterated:8b` and `huihui_ai/baronllm-abliterated:8b`, and run `Scripts/test-ollama-tools.sh <model>` on each.
   A model that only writes tool calls as text is still useful for chat and analysis, but not as the agent model (Kiln accepts several text calls in a row now, only for tools that were offered, all or nothing).
2. **See it in the app** (this session's screen was locked overnight, so the GUI check did not happen): select `ollama-huihui_ai/qwen3.5-abliterated:9b`, run a task with several tool calls, and confirm the live status line, the task-list card and the diff card. Check the model picker lists the new model with the tools and vision badges.
3. Per-model `num_ctx` (a setting, and a default taken from available memory) instead of the fixed 8192; the meter already follows whatever value is used.
4. Add the abliterated families to the Lab Models catalogue and a "Security and RE" profile that prefers them; document the trade-off (refusals gone, capability slightly lower) in the model picker's detail.
5. Re-run this audit every few months: `ollama list`, `ollama.com/huihui_ai`, `ollama.com/library`.

Sources used for the shortlist (blogs and listings, not benchmarks): the `ollama.com/huihui_ai` listing and each model's tags page (sizes, ages), `registry.ollama.ai/library` pages for Qwen 3.5 / 3.6 and Gemma 4, and community guides on abliterated models (Atlas Cloud, DEV Community, bestllmfor.com, insiderllm.com).
