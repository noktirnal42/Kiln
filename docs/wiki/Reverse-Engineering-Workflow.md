# Reverse Engineering Workflow

The **Analyze** activity (⌘5) is a Ghidra-style browser: project list, function list with filter, decompiler and listing panes, callers and callees as links, annotations in a popover, engines in one Analyze menu. Kiln **never runs the target binary**.

## 1. Get a binary

- **Import** a file (native Mach-O inspection and a labelled linear disassembly fallback are built in), or
- **Download…** a package: Aptoide search returns direct APK links and the download verifies the store's MD5. Apple, Google Play, APKPure and Amazon only open a store listing; Kiln does not sign in to any store. Only http(s) is accepted and files land in `~/Library/Application Support/Kiln/ReverseEngineering/Downloads`.
- From the Browser, a download offers **Analyze in Kiln**; it is never auto-imported.

## 2. Inspect

Native inspection lists sections and strings. A native listing of a stripped binary has no function boundaries and no decompiler; it says so.

## 3. Recover functions and pseudocode

Install Ghidra separately (stable releases in `~/Applications` or `/Applications`, or a valid `GHIDRA_HOME`; restart Kiln after changing it). Kiln bundles its export script but not Ghidra or Java. Choose **Analyze with Ghidra**; the header shows the discovered installation or why it is unavailable. One run at a time, bounded at 240 seconds. Ghidra 11 with a newer JDK fails to compile its scripts, so Kiln pins JDK 21 for Ghidra 11 when one is installed. radare2 can be selected as an alternative engine and is useful for graphs or when Java is unavailable.

## 4. Annotate and search

Rename, comment and bookmark with undo and redo; a stale revision is rejected, and reanalysis preserves annotations. Scan for crypto constants, auto-decrypt, find ROP/JOP gadgets, carve embedded formats, check entropy regions, run YARA-subset rules, wildcard byte search and pointer scans.

## 5. Ask the agent

The Workstation Agent and the MCP server use the same service: `re_import_binary` returns a `project_id` that the other `re_*` tools take. `re_analyze_binary` is an execution action and needs approval; `re_download_package` is a write and needs approval. Example verified run: a hosted model found a function, disassembled it and explained that it computes a FNV-1a-style hash with a rotation; one tool call in the run failed and the record shows it.

## Interchangeable projects

Kiln and the Axiom RE tool use the same `analysis.json` project format, so a project created by one appears in the other.

## Limits

Ghidra is optional and separate. The bundled cipher classifier is a **placeholder**, not a trained model. The agent cannot yet list or select projects, delete projects, or operate the device bench.

---

**Verified status.** Ghidra 11.3.2, 12.1.4 and 12.2 DEV were exercised on a bundled fixture; harder inputs (stripped, C++, Swift) passed with 12.1.4 on 2026-11-04; MD5 verification and import and string search were checked. **Not checked:** a Ghidra install and a file-picker import in this pass, other architectures, and cancellation UI.
