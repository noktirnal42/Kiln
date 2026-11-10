import SwiftUI

extension Activity { static let analyze = Activity("analyze") }

/// Analyze: reverse engineering and decryption. Tools are `re_*` (see `REMCPTools`).
enum AnalyzeActivity {
    static let descriptor = ActivityDescriptor(
        id: "analyze", title: "Analyze", symbol: "magnifyingglass.circle", summary: "Reverse engineering and decryption",
        moduleIdentifier: REModule.identifier,
        starterPrompts: { _ in
            [StarterPrompts.binary,
             StarterPrompt(title: "Find crypto and secrets", symbol: "key",
                           text: "In the binary I have open, scan for crypto constants and embedded keys or tokens and report what you find."),
             StarterPrompt(title: "Explain the main logic", symbol: "function",
                           text: "Explain what the open binary does at a high level, using its strings and functions as evidence.")]
        },
        toolPrefixes: [REAgentTools.prefix],
        agentPromptSentence: "Use the re_* tools to analyze binaries.",
        capabilities: [
            .tool("re_import_binary", "Import a binary", .write),
            .tool("re_analyze_binary", "Analyze with Ghidra", .execute),
            .tool("re_analyze_function", "Analyze a function", .read),
            .tool("re_get_disassembly", "Disassembly of a function", .read),
            .tool("re_get_decompilation", "Decompile a function", .read),
            .tool("re_search_strings", "Search strings", .read),
            .tool("re_get_xrefs", "Cross-references", .read),
            .tool("re_scan_crypto", "Scan for crypto constants", .read),
            .tool("re_entropy_regions", "Entropy regions", .read),
            .tool("re_digest_file", "Hash a file", .read),
            .tool("re_wildcard_search", "Wildcard byte search", .read),
            .tool("re_scan_rules", "Scan with rule packs", .read),
            .tool("re_list_modules", "List modules", .read),
            .tool("re_rename_function", "Rename a function", .write),
            .tool("re_set_comment", "Comment a function", .write),
            .tool("re_toggle_bookmark", "Toggle a bookmark", .write),
            .tool("re_undo_edit", "Undo an annotation", .write),
            .tool("re_redo_edit", "Redo an annotation", .write),
            .tool("re_scan_pointers", "Scan pointers", .read),
            .tool("re_auto_decrypt", "Auto-decrypt", .read),
            .tool("re_find_gadgets", "Find ROP/JOP gadgets", .read),
            .tool("re_carve_formats", "Carve embedded formats", .read),
            .tool("re_search_packages", "Search app packages", .read),
            .tool("re_download_package", "Download an app package", .write),
            .exempt("analyze.select-project", "Choose the open project", .read,
                    because: "Gap: tools take a project id, but there is no tool to list projects or to set the one on screen (docs/13, Reverse engineering)."),
            .exempt("analyze.delete-project", "Delete a project", .write,
                    because: "Gap: no delete tool yet; destructive, so it needs an approval-gated adapter before it is offered."),
            .exempt("analyze.engines", "Choose Ghidra or radare2, set the Ghidra folder", .admin,
                    because: "Deliberate: which external engine runs, and from where, is a trust decision the user makes."),
            .exempt("analyze.device-bench", "Device bench: connect, read registers and memory", .execute,
                    because: "Gap: device-bench operations need a dedicated adapter with its own limits (docs/13, Reverse engineering)."),
        ],
        registerTools: { context in
            guard let re = await context.module(REModule.identifier, as: REModule.self) else { return }
            REAgentTools.register(module: re, into: context.registry)
            #if DEBUG
            // Visual-QA hook, compiled out of release builds:
            //   open Kiln.app --args -KilnImportFixture /usr/bin/true
            // imports the binary at launch so analysis views can be checked without the file picker.
            // Skips a fixture already imported on an earlier launch, so relaunches don't pile up copies.
            if let fixture = UserDefaults.standard.string(forKey: "KilnImportFixture") {
                let name = URL(fileURLWithPath: fixture).lastPathComponent
                let alreadyImported = re.projects.contains { $0.binaryURL.lastPathComponent == name }
                if !alreadyImported {
                    _ = try? await re.importBinary(at: URL(fileURLWithPath: fixture))
                }
            }
            #endif
        })
}
