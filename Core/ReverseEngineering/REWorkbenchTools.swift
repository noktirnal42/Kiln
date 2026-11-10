import Foundation
import AxiomCore

/// Agent and MCP tools for the Analyze workbench. Reading is `read`; anything that changes a project or writes a file is `write`;
/// running a script or the debugger is `execute` and goes through approval. Nothing here runs the target except `run_debugger`.
public enum REWorkbenchTools {
    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]], required: [String] = ["project_id"],
                             readOnly: Bool, executes: Bool = false) -> REMCPToolDefinition {
        var props: [String: Any] = ["project_id": ["type": "string", "description": "Project ID."]]
        for (k, v) in properties { props[k] = v }
        return REMCPToolDefinition(name: name, description: description,
                                   inputSchema: ["type": "object", "properties": props, "required": required, "additionalProperties": false],
                                   readOnly: readOnly, executes: executes)
    }
    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    private static var revision: [String: Any] { int("The project's current revision; a stale value is rejected.") }

    public static let definitions: [REMCPToolDefinition] = [
        tool("get_cfg", "Control-flow graph of one function: basic blocks with listings, edges (taken, fallthrough, jump, back), cyclomatic complexity. Pass format=dot for Graphviz.",
             ["function": str("Function address or name."), "format": str("json (default) or dot.")], required: ["project_id", "function"], readOnly: true),
        tool("get_call_graph", "Call graph around a function: callers above, callees below, to a depth of 1 to 6. format=dot for Graphviz.",
             ["function": str("Function address or name."), "direction": str("callers, callees or both (default)."), "depth": int("Levels, default 2."), "format": str("json or dot.")],
             required: ["project_id", "function"], readOnly: true),
        tool("get_references", "Everything that refers to a function name, address or string text: calls, jumps, data and string references, each with its function and instruction.",
             ["target": str("Address, function name or string text.")], required: ["project_id", "target"], readOnly: true),
        tool("read_bytes", "Hex dump of the binary at a virtual address or file offset (max 4096 bytes), with the virtual address of each row.",
             ["address": str("Virtual address."), "offset": int("File offset (alternative to address)."), "length": int("Bytes, default 256.")], required: ["project_id"], readOnly: true),
        tool("search_bytes", "Find a byte pattern in the file: hex with ?? wildcards (`de ad ?? ef`) or quoted ASCII (KILN in double quotes). Returns file offsets and virtual addresses.",
             ["pattern": str("Pattern."), "limit": int("Max results, default 200.")], required: ["project_id", "pattern"], readOnly: true),
        tool("annotate_address", "Set an analyst comment and/or label on any address (instruction or data). Empty string clears. Undoable.",
             ["address": str("Address."), "comment": str("Comment, one line."), "label": str("Label, no whitespace."), "expected_revision": revision],
             required: ["project_id", "address", "expected_revision"], readOnly: false),
        tool("change_variable", "Rename and/or retype a decompiler variable in a function. `id` is the engine variable id. Undoable.",
             ["function": str("Function address."), "id": str("Variable id."), "name": str("New name."), "type": str("New type, e.g. `struct Foo *`."), "expected_revision": revision],
             required: ["project_id", "function", "id", "expected_revision"], readOnly: false),
        tool("list_structures", "Data types defined in the project, with size, alignment and field offsets.", [:], readOnly: true),
        tool("define_structure", "Define structs or unions from C-style source (`struct Foo { int a; char name[16]; void *p; };`). Layout uses natural alignment. Undoable in the types editor.",
             ["source": str("C declarations.")], required: ["project_id", "source"], readOnly: false),
        tool("delete_structure", "Delete a defined structure.", ["name": str("Structure name.")], required: ["project_id", "name"], readOnly: false),
        tool("apply_structure", "Retype a variable of a function to a defined structure (pointer by default).",
             ["function": str("Function address."), "id": str("Variable id."), "structure": str("Structure name."), "as_pointer": ["type": "boolean", "description": "Default true."], "expected_revision": revision],
             required: ["project_id", "function", "id", "structure", "expected_revision"], readOnly: false),
        tool("bookmark_address", "Toggle a bookmark with a note on any address.", ["address": str("Address."), "note": str("Note.")], required: ["project_id", "address"], readOnly: false),
        tool("create_patch", "Record a patch at an address from hex bytes, assembly (arm64/x86_64, assembled with clang, never run) or a NOP length. Nothing is written to the binary; use export_patched to write a copy.",
             ["address": str("Virtual address."), "hex": str("Replacement bytes."), "assembly": str("Assembly source."), "nop_length": int("Bytes to NOP."), "note": str("Why.")],
             required: ["project_id", "address"], readOnly: false),
        tool("remove_patch", "Remove a recorded patch.", ["patch_id": str("Patch id.")], required: ["project_id", "patch_id"], readOnly: false),
        tool("list_patches", "Patches recorded for the project.", [:], readOnly: true),
        tool("export_patched", "Apply all recorded patches to a COPY of the binary and return its path and SHA-256. The original is never modified; the copy is not re-signed and is not run.",
             ["destination": str("Optional output path (must differ from the original).")], readOnly: false),
        tool("diff_projects", "Compare two projects: matched, changed, added and removed functions with similarity. Pass a function pair for a listing diff.",
             ["other_project_id": str("The second project."), "function": str("Optional function name to show a listing diff for.")], required: ["project_id", "other_project_id"], readOnly: true),
        tool("inspect_package", "Inspect an IPA or APK without running it: manifest or Info.plist, entitlements, permissions, components, classes, resources, libraries.",
             ["path": str("Path to the .ipa or .apk.")], required: ["path"], readOnly: true),
        tool("import_package_entry", "Extract one file from an IPA or APK (for example the main executable or a library) and import it as a project.",
             ["path": str("Path to the package."), "entry": str("Entry name inside it, from inspect_package.")], required: ["path", "entry"], readOnly: false),
        tool("list_findings", "Findings recorded for the project.", [:], readOnly: true),
        tool("add_finding", "Record a finding with evidence for the report.",
             ["title": str("Title."), "summary": str("What and why."), "severity": str("info, low, medium, high or critical."), "address": str("Address."), "function": str("Function name."),
              "evidence": ["type": "array", "items": ["type": "string"], "description": "Evidence snippets."]], required: ["project_id", "title", "summary"], readOnly: false),
        tool("export_report", "Write a Markdown and HTML report with findings, evidence listings, annotations, types and patches into the project's reports folder (or `destination`).",
             ["destination": str("Optional folder."), "title": str("Optional title.")], readOnly: false),
        tool("plan_debugger", "Show the lldb commands for launching under the debugger with breakpoints at addresses, without running anything.",
             ["addresses": ["type": "array", "items": ["type": "string"], "description": "Breakpoint addresses."], "mode": str("launch (default), attach or inspect."), "pid": int("Process id for attach.")], readOnly: true),
        tool("run_debugger", "Run a debugger plan in lldb. mode=launch RUNS THE TARGET (stopped at entry, killed at the end); mode=inspect only loads it and resolves breakpoints. Requires approval.",
             ["addresses": ["type": "array", "items": ["type": "string"], "description": "Breakpoint addresses."], "mode": str("launch, attach or inspect (default)."), "pid": int("Process id for attach."),
              "arguments": ["type": "array", "items": ["type": "string"], "description": "Program arguments."]], readOnly: false, executes: true),
        tool("run_script", "Run JavaScript with the `re` API (functions, fn, references, strings, bytes, search, cfg, callGraph, rename, comment, label) and `axiom`. Renames and comments are applied as one undoable change. Requires approval.",
             ["source": str("Script. The last expression is the result.")], required: ["project_id", "source"], readOnly: false, executes: true),
    ]

    @MainActor
    public static func call(tool name: String, arguments a: [String: Any], service: REModule) async throws -> String? {
        func project() throws -> String { guard let v = a["project_id"] as? String, !v.isEmpty else { throw REMToolError.missingArgument("project_id") }; return v }
        func required(_ key: String) throws -> String { guard let v = a[key] as? String, !v.isEmpty else { throw REMToolError.missingArgument(key) }; return v }
        func revisionArg() throws -> Int { guard let v = a["expected_revision"] as? Int else { throw REMToolError.missingArgument("expected_revision") }; return v }
        func json(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) }
        let known = Set(definitions.map(\.name))
        guard known.contains(name) else { return nil }
        switch name {
        case "get_cfg":
            let graph = try await service.controlFlowGraph(projectID: try project(), function: try required("function"))
            return (a["format"] as? String) == "dot" ? graph.dot() : try json(graph.json())
        case "get_call_graph":
            let direction = CallGraph.Direction(rawValue: (a["direction"] as? String) ?? "both") ?? .both
            let graph = try await service.callGraph(projectID: try project(), function: try required("function"), direction: direction, depth: (a["depth"] as? Int) ?? 2)
            return (a["format"] as? String) == "dot" ? graph.dot() : try json(graph.json())
        case "get_references":
            let rows = try await service.references(projectID: try project(), target: try required("target"))
            return try json(["count": rows.count, "references": rows.prefix(500).map(\.json)])
        case "read_bytes":
            let length = min((a["length"] as? Int) ?? 256, 4096)
            let rows = try await service.readHex(projectID: try project(), address: a["address"] as? String, offset: (a["offset"] as? Int).map(UInt64.init), length: length)
            return try json(["rows": rows.map { ["offset": $0.offset, "address": $0.address.map { REListing.hex($0) } ?? "", "hex": $0.hex, "ascii": $0.ascii] }])
        case "search_bytes":
            let id = try project()
            let hits = try await service.searchBytes(projectID: id, pattern: try required("pattern"), limit: (a["limit"] as? Int) ?? 200)
            let map = try await service.addressMap(projectID: id)
            return try json(["count": hits.count, "hits": hits.map { ["offset": $0, "address": map.address(forFileOffset: $0).map { REListing.hex($0) } ?? ""] }])
        case "annotate_address":
            let updated = try await service.editProject(projectID: try project(), expectedRevision: try revisionArg(),
                operations: [.addressNote(address: try required("address"), comment: a["comment"] as? String, label: a["label"] as? String)])
            return try json(["revision": updated.revision])
        case "change_variable":
            let updated = try await service.editProject(projectID: try project(), expectedRevision: try revisionArg(),
                operations: [.variable(address: try required("function"), id: try required("id"), name: a["name"] as? String, type: a["type"] as? String)])
            return try json(["revision": updated.revision])
        case "list_structures":
            let list = try service.workspace(projectID: try project()).structures
            return try json(["structures": list.map { ["name": $0.name, "size": $0.size, "alignment": $0.alignment, "union": $0.isUnion, "declaration": $0.declaration] as [String: Any] }])
        case "define_structure":
            let list = try service.defineStructures(projectID: try project(), source: try required("source"))
            return try json(["structures": list.map(\.name)])
        case "delete_structure":
            try service.deleteStructure(projectID: try project(), name: try required("name")); return try json(["deleted": true])
        case "apply_structure":
            let updated = try await service.applyStructure(projectID: try project(), function: try required("function"), variableID: try required("id"),
                structure: try required("structure"), asPointer: (a["as_pointer"] as? Bool) ?? true, expectedRevision: try revisionArg())
            return try json(["revision": updated.revision])
        case "bookmark_address":
            let added = try service.toggleAddressBookmark(projectID: try project(), address: try required("address"), note: (a["note"] as? String) ?? "")
            return try json(["bookmarked": added])
        case "create_patch":
            let patch = try await service.createPatch(projectID: try project(), address: try required("address"), hex: a["hex"] as? String,
                                                      assembly: a["assembly"] as? String, nopLength: a["nop_length"] as? Int, note: (a["note"] as? String) ?? "")
            return try json(["patch_id": patch.id, "address": patch.address, "file_offset": patch.fileOffset, "original": patch.original, "bytes": patch.bytes])
        case "remove_patch":
            try service.removePatch(projectID: try project(), id: try required("patch_id")); return try json(["removed": true])
        case "list_patches":
            let list = try service.workspace(projectID: try project()).patches
            return try json(["patches": list.map { ["id": $0.id, "address": $0.address, "original": $0.original, "bytes": $0.bytes, "note": $0.note, "applied": $0.applied] as [String: Any] }])
        case "export_patched":
            let result = try await service.exportPatched(projectID: try project(), destination: (a["destination"] as? String).map { URL(fileURLWithPath: $0) })
            return try json(["path": result.url.path, "sha256": result.sha256, "note": "A copy; not re-signed and not executed."])
        case "diff_projects":
            let id = try project(), other = try required("other_project_id")
            let result = try await service.diff(projectA: id, projectB: other)
            var out = result.json()
            if let name = a["function"] as? String {
                let x = try await service.analysis(projectID: id), y = try await service.analysis(projectID: other)
                if let f = x.functions.first(where: { $0.name == name }), let g = y.functions.first(where: { $0.name == name }) { out["listing_diff"] = REDiff.listingDiff(f, g) }
            }
            return try json(out)
        case "inspect_package":
            return try json(try await service.inspectPackage(at: URL(fileURLWithPath: try required("path"))).json())
        case "import_package_entry":
            let analysis = try await service.importPackageEntry(archive: URL(fileURLWithPath: try required("path")), entry: try required("entry"))
            let id = service.projects.first { $0.analysis?.id == analysis.id }?.id
            return try json(["project_id": id ?? analysis.id, "functions": analysis.functions.count])
        case "list_findings":
            let list = try service.workspace(projectID: try project()).findings
            return try json(["findings": list.map { ["id": $0.id, "title": $0.title, "severity": $0.severity.rawValue, "summary": $0.summary, "address": $0.address ?? "", "function": $0.function ?? ""] }])
        case "add_finding":
            var finding = REFinding(title: try required("title"), severity: REFinding.Severity(rawValue: (a["severity"] as? String) ?? "info") ?? .info, summary: try required("summary"))
            finding.address = a["address"] as? String; finding.function = a["function"] as? String
            finding.evidence = (a["evidence"] as? [String]) ?? []; finding.source = "agent"
            return try json(["finding_id": try service.addFinding(projectID: try project(), finding: finding).id])
        case "export_report":
            let result = try await service.exportReport(projectID: try project(), destination: (a["destination"] as? String).map { URL(fileURLWithPath: $0) }, title: a["title"] as? String)
            return try json(["folder": result.folder.path, "markdown": result.markdown.path, "html": result.html.path])
        case "plan_debugger", "run_debugger":
            let mode = REDebugPlan.Mode(rawValue: (a["mode"] as? String) ?? (name == "run_debugger" ? "inspect" : "launch")) ?? .inspect
            let plan = try await service.debugPlan(projectID: try project(), mode: mode, addresses: (a["addresses"] as? [String]) ?? [],
                                                   arguments: (a["arguments"] as? [String]) ?? [], pid: (a["pid"] as? Int).map(Int32.init))
            if name == "plan_debugger" { return try json(["summary": plan.summary, "commands": plan.commands]) }
            return try json(["summary": plan.summary, "commands": plan.commands, "output": try await service.runDebugPlan(plan)])
        case "run_script":
            let run = try await service.runWorkbenchScript(projectID: try project(), source: try required("source"))
            return try json(["result": run.value, "log": run.output, "edits_applied": run.queuedEdits])
        default: return nil
        }
    }
}
