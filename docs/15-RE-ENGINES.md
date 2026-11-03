# Axiom RE, Ghidra and Kiln's Analyze compared (2026-11-02)

**Short version:** Axiom RE and Kiln's Analyze are the same engine. Kiln embeds `Packages/AxiomCore`, a port of the AxiomRE engine, and uses the same project file
(`analysis.json`, schema version 1). Axiom wraps Ghidra (default) or radare2; Kiln's engine is Ghidra when installed, otherwise native `otool` inspection. Ghidra is the
decompiler in both. Use whichever front end suits the moment; projects move between them.

## Measured on one binary

A 57 KB arm64 Swift executable (a SwiftPM debug build, `dbg`), analysed 2026-11-02 with Ghidra 12.1.4 (Java 21) and radare2 from Homebrew.

| | Functions | Decompiler | Names | Notes |
|---|---|---|---|---|
| Kiln native (`otool -tV`) | **0** (986-line linear listing) | none | none | instant; labelled as "no function boundaries recovered" in Analyze |
| Axiom + Ghidra | **64**, each with callers/callees, assembly, blocks | **yes** | Swift-aware (`compute(Int n)`, `main`, runtime stubs) | `Unresolved local var: Int doubled` and `total` recovered from the source's locals |
| Axiom + radare2 | 64, with basic blocks | none | mangled (`dbg.compute_...S2iF_`) | fast; useful for graphs and when Java is unavailable |
| Kiln + Ghidra | same engine and output as Axiom + Ghidra | yes | same | the service run was verified by the Codex session on `/usr/bin/true` (docs/14) |

For `compute`, Ghidra recovered the overflow checks and traps of Swift's checked arithmetic, i.e. `lVar2 = n * 2; … return lVar2 + 1;` — which is what the debugger showed at runtime (`doubled = 40`).

## Interchangeable projects (verified)

Kiln's project folder is `~/Library/Application Support/ReverseEngineering/Projects/<name>/analysis.json`; Axiom wrote the same keys
(`binaryPath, created, engine, format, functions, hex, id, revision, schemaVersion, sections, sha256, size, strings`; Kiln adds `slice`, `slices`, `warnings`). A project
created by Axiom's `analyze_binary` was copied into that folder and appeared in Kiln's Analyze list with all 64 functions; selecting a function showed its callers/callees,
decompilation and the bookmark / comment / undo / redo controls. Going the other way works because Kiln only adds optional fields.

## What each has

| Capability | Axiom RE (app/CLI/MCP) | Kiln Analyze + `re_*` agent tools |
|---|---|---|
| Native Mach-O inspection, strings | yes (`inspect_binary`, `list_strings`) | yes (`re_import_binary`, `re_search_strings`) |
| Ghidra analysis, decompile, xrefs | yes | yes (`re_analyze_binary`, `re_get_decompilation`, `re_get_xrefs`) |
| radare2 engine | **yes** (`engine=radare2`) | **no** (not selectable) |
| Crypto-constant scan, auto-decrypt, ROP/JOP gadgets, format carving | yes | yes |
| Entropy regions, digests/statistics, wildcard byte search, YARA-subset rules, embedded-module listing | yes | GUI tabs (Rules, Forensics) already; **agent tools added today** (`re_entropy_regions`, `re_digest_file`, `re_wildcard_search`, `re_scan_rules`, `re_list_modules`) |
| Pointer scan, module extraction (dump forensics) | yes | GUI only |
| Analyst rename / comment / bookmark with undo-redo and revision-conflict protection | yes (MCP tools) | GUI only; not exposed as agent tools |
| Approvals, audit chain, behaviour monitor around every call | no | **yes** (all `re_*` calls go through Kiln's gates) |
| Runs headless for other agents (Claude Code, Codex, OpenCode) | **yes** (CLI + MCP server, already configured for all three) | yes, as an MCP server when started in Develop → MCP |
| Project/device bench, in-app chat and swarm context | no | yes |

## Recommendation

1. Keep one engine. Don't add a second decompiler: Ghidra is it, and Axiom already drives it.
2. Share projects: point both at one folder, or copy a project directory across (above).
3. Use Axiom's MCP from other agents for quick static questions; use Kiln when you want the analysis next to the debugger, the editor and the approval/audit trail.
4. Gaps worth closing in Kiln, in order: expose rename/comment/bookmark as write tools (revision-checked), add radare2 as a selectable engine (it is the fast fallback when Java or Ghidra is unavailable), pointer scan and module extraction as tools.
