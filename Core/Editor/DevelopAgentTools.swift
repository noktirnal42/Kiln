import Foundation

/// The Develop activity as agent tools (`ide_*`), registered like `device_*` and so also served by Kiln's MCP endpoint.
/// Every tool calls `DevelopController`, the same service the editor, the command palette and the debugger panel use.
/// Reading and navigating are read-level; edits (rename, scheme choice, breakpoints) are write; building, testing,
/// running and debugging start processes and are execute-level, so they go through approval.
public enum DevelopAgentTools {
    public static let prefix = "ide_"

    @MainActor
    public static func register(controller: DevelopController, into registry: ToolRegistry = .shared) {
        for kind in Kind.allCases { registry.register(DevelopAgentTool(kind: kind, controller: controller)) }
    }

    public enum Kind: String, CaseIterable, Sendable {
        case project, open, outline, definition, references, hover, rename, diagnostics, blame
        case build, test, run, stop, buildStatus = "build_status", selectScheme = "select_scheme"
        case debugStart = "debug_start", debugControl = "debug_control", debugState = "debug_state"
        case breakpoint, debugEval = "debug_eval"

        static let path = ToolParam(name: "path", description: "File path relative to the project folder (or absolute inside it)")
        static let line = ToolParam(name: "line", type: "integer", description: "Line, starting at 1")
        static let column = ToolParam(name: "column", type: "integer", description: "Column, starting at 1 (default 1; use the column of the identifier)", required: false)

        public var spec: ToolSpec {
            switch self {
            case .project:
                ToolSpec(name: "ide_project", summary: "Describe the project open in Develop: folder, kind, schemes, configurations, the selected scheme, the build command Kiln will use, language server state and open files.", permission: .read)
            case .open:
                ToolSpec(name: "ide_open", summary: "Open a file in the Develop editor, optionally at a line, so the user sees it. Returns the file's line count.",
                         parameters: [Self.path, ToolParam(name: "line", type: "integer", description: "Line to scroll to, starting at 1", required: false), Self.column], permission: .read)
            case .outline:
                ToolSpec(name: "ide_outline", summary: "List the symbols (types, functions, properties) declared in a file with their line numbers, from the language server or a built-in outline.",
                         parameters: [Self.path], permission: .read)
            case .definition:
                ToolSpec(name: "ide_definition", summary: "Go to definition: where the symbol at a position is declared (language server; Swift and C-family files).",
                         parameters: [Self.path, Self.line, Self.column], permission: .read)
            case .references:
                ToolSpec(name: "ide_references", summary: "Find references: every use of the symbol at a position across the project (language server; falls back to whole-word text matches).",
                         parameters: [Self.path, Self.line, Self.column], permission: .read)
            case .hover:
                ToolSpec(name: "ide_hover", summary: "Quick Help: the type and documentation of the symbol at a position.",
                         parameters: [Self.path, Self.line, Self.column], permission: .read)
            case .rename:
                ToolSpec(name: "ide_rename", summary: "Rename the symbol at a position everywhere it is used, through the language server (Swift and C-family files). Edits and saves every affected file inside the project; use dry_run to preview.",
                         parameters: [Self.path, Self.line, Self.column, ToolParam(name: "new_name", description: "The new identifier"),
                                      ToolParam(name: "dry_run", type: "boolean", description: "Only report which files would change", required: false)],
                         permission: .write)
            case .diagnostics:
                ToolSpec(name: "ide_diagnostics", summary: "Live issues: language-server diagnostics for open files plus errors and warnings from the last build, optionally for one file.",
                         parameters: [ToolParam(name: "path", description: "Limit to this file", required: false)], permission: .read)
            case .blame:
                ToolSpec(name: "ide_blame", summary: "Git blame for a file (author and commit per line), optionally one line range.",
                         parameters: [Self.path, ToolParam(name: "from_line", type: "integer", description: "First line (default 1)", required: false),
                                      ToolParam(name: "to_line", type: "integer", description: "Last line (default from_line + 39)", required: false)], permission: .read)
            case .build:
                ToolSpec(name: "ide_build", summary: "Save open files and build the project with the selected scheme (xcodebuild, swift build, cargo, go, npm, make). Waits for the result and returns the errors and warnings with file:line:column.",
                         parameters: [ToolParam(name: "timeout_seconds", type: "integer", description: "How long to wait (default 600)", required: false)], permission: .execute)
            case .test:
                ToolSpec(name: "ide_test", summary: "Run the project's tests and return per-test results and failing assertions with locations.",
                         parameters: [ToolParam(name: "filter", description: "Only tests whose name matches (swift test --filter / xcodebuild -only-testing)", required: false),
                                      ToolParam(name: "timeout_seconds", type: "integer", description: "How long to wait (default 900)", required: false)], permission: .execute)
            case .run:
                ToolSpec(name: "ide_run", summary: "Build and run the project's executable (not under the debugger). Returns when it exits or after timeout_seconds, leaving it running.",
                         parameters: [ToolParam(name: "timeout_seconds", type: "integer", description: "How long to wait (default 60)", required: false)], permission: .execute)
            case .stop:
                ToolSpec(name: "ide_stop", summary: "Cancel the running build, test or run, and end the debugger.", permission: .execute)
            case .buildStatus:
                ToolSpec(name: "ide_build_status", summary: "State and result of the latest build, test or run: running or finished, exit status, issues, test results and output tail.", permission: .read)
            case .selectScheme:
                ToolSpec(name: "ide_select_scheme", summary: "Choose the scheme and/or configuration used by build, test, run and debug (see ide_project for the choices).",
                         parameters: [ToolParam(name: "scheme", description: "Scheme name", required: false), ToolParam(name: "configuration", description: "Configuration, e.g. Debug", required: false)],
                         permission: .write)
            case .debugStart:
                ToolSpec(name: "ide_debug_start", summary: "Build the project, then launch it under LLDB with the breakpoints set so far; returns when it stops at a breakpoint, exits or fails, with the stack and locals.",
                         parameters: [ToolParam(name: "timeout_seconds", type: "integer", description: "How long to wait for a stop (default 60)", required: false)], permission: .execute)
            case .debugControl:
                ToolSpec(name: "ide_debug_control", summary: "Control the debugger: continue, pause, step_over, step_into, step_out or stop. Returns the new state, stack and locals.",
                         parameters: [ToolParam(name: "action", description: "continue, pause, step_over, step_into, step_out or stop")], permission: .execute)
            case .debugState:
                ToolSpec(name: "ide_debug_state", summary: "Debugger state: paused or running, threads, call stack, local variables, breakpoints and the program's output.", permission: .read)
            case .breakpoint:
                ToolSpec(name: "ide_breakpoint", summary: "Set or remove a line breakpoint (optionally conditional), or list them. Breakpoints persist per project and apply to the running debugger at its next stop.",
                         parameters: [ToolParam(name: "action", description: "set, remove or list"),
                                      ToolParam(name: "path", description: "File (set and remove)", required: false),
                                      ToolParam(name: "line", type: "integer", description: "Line starting at 1 (set and remove)", required: false),
                                      ToolParam(name: "condition", description: "Stop only when this expression is true (set)", required: false)],
                         permission: .write)
            case .debugEval:
                ToolSpec(name: "ide_debug_eval", summary: "Evaluate an expression in the selected stack frame while the program is paused (LLDB expression); returns the console output.",
                         parameters: [ToolParam(name: "expression", description: "Expression in the program's language")], permission: .execute)
            }
        }
    }
}

struct DevelopAgentTool: ToolExecuting {
    let kind: DevelopAgentTools.Kind
    let controller: DevelopController

    var spec: ToolSpec { kind.spec }

    func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = ToolArgs.object(from: argumentsJSON) ?? [:]
        func string(_ key: String) -> String? {
            let value = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        func int(_ key: String) -> Int? { (args[key] as? Int) ?? (args[key] as? Double).map(Int.init) ?? (args[key] as? String).flatMap(Int.init) }
        func bool(_ key: String) -> Bool { (args[key] as? Bool) ?? ((args[key] as? String)?.lowercased() == "true") }
        func required(_ key: String) throws -> String {
            guard let value = string(key) else { throw DevelopController.IDEError.failed("Missing required argument “\(key)”.") }
            return value
        }
        func position() throws -> (path: String, line: Int, column: Int) {
            guard let line = int("line"), line >= 1 else { throw DevelopController.IDEError.failed("Missing required integer argument “line” (starting at 1).") }
            return (try required("path"), line, max(int("column") ?? 1, 1))
        }

        let root = try WorkspacePathResolver.requireRoot(context)
        let controller = self.controller
        await controller.attach(root: root)

        switch kind {
        case .project:
            return await MainActor.run { Self.describeProject(controller) }
        case .open:
            let path = try required("path")
            return try await MainActor.run {
                let document = try controller.open(path: path, line: int("line"), column: max(int("column") ?? 1, 1))
                let lines = document.text.components(separatedBy: "\n").count
                return "Opened \(controller.editor.displayPath(document.url)) (\(lines) lines)" + (int("line").map { " at line \($0)" } ?? "") + "."
            }
        case .outline:
            let path = try required("path")
            let document = try await MainActor.run { try controller.open(path: path) }
            let symbols = await controller.outline(for: document)
            if symbols.isEmpty { return "No symbols found in \(path)." }
            return symbols.flatMap { $0.flattened() }.map { "\(String(repeating: "  ", count: $0.depth))\($0.symbol.kind.label) \($0.symbol.name) — line \($0.symbol.line + 1)" }.joined(separator: "\n")
        case .definition:
            let p = try position()
            guard let place = try await controller.definition(path: p.path, line: p.line, column: p.column) else { return "No definition found at \(p.path):\(p.line):\(p.column)." }
            return await MainActor.run { "\(controller.editor.displayPath(URL(fileURLWithPath: place.path))):\(place.line):\(place.column)  \(place.text)" }
        case .references:
            let p = try position()
            let places = try await controller.references(path: p.path, line: p.line, column: p.column)
            if places.isEmpty { return "No references found." }
            return await MainActor.run {
                (["\(places.count) reference(s):"] + places.prefix(200).map { "\(controller.editor.displayPath(URL(fileURLWithPath: $0.path))):\($0.line):\($0.column)  \($0.text)" }).joined(separator: "\n")
            }
        case .hover:
            let p = try position()
            return try await controller.hover(path: p.path, line: p.line, column: p.column) ?? "No information at that position."
        case .rename:
            let p = try position()
            let result = try await controller.rename(path: p.path, line: p.line, column: p.column, to: try required("new_name"), apply: !bool("dry_run"))
            return (result.applied ? "Renamed in" : "Would rename in") + " \(result.files.count) file(s), \(result.edits) edit(s):\n" + result.files.joined(separator: "\n")
        case .diagnostics:
            let path = string("path")
            return try await MainActor.run { try controller.diagnosticsSummary(path: path) }
        case .blame:
            let lines = try await controller.blame(path: try required("path"))
            let from = max(int("from_line") ?? 1, 1), to = int("to_line") ?? (from + 39)
            return lines.filter { $0.lineNumber >= from && $0.lineNumber <= to }
                .map { "\($0.lineNumber)  \($0.hash.prefix(8))  \($0.author)  \($0.text)" }.joined(separator: "\n")
        case .build:
            let report = try await controller.buildAndWait(timeout: TimeInterval(int("timeout_seconds") ?? 600))
            return report.rendered(root: root)
        case .test:
            let report = try await controller.testAndWait(filter: string("filter"), timeout: TimeInterval(int("timeout_seconds") ?? 900))
            return report.rendered(root: root)
        case .run:
            let report = try await controller.runAndWait(timeout: TimeInterval(int("timeout_seconds") ?? 60))
            return report.rendered(root: root)
        case .stop:
            await controller.stop()
            return "Stopped."
        case .buildStatus:
            return await MainActor.run { controller.report().rendered(root: root) }
        case .selectScheme:
            let scheme = string("scheme"), configuration = string("configuration")
            return try await MainActor.run {
                guard scheme != nil || configuration != nil else { throw DevelopController.IDEError.failed("Give a scheme and/or a configuration.") }
                let info = controller.builder.info
                if let scheme, !info.schemes.contains(scheme) { throw DevelopController.IDEError.notFound("No scheme “\(scheme)”. Choices: \(info.schemes.joined(separator: ", ")).") }
                if let configuration, !info.configurations.contains(configuration) { throw DevelopController.IDEError.notFound("No configuration “\(configuration)”. Choices: \(info.configurations.joined(separator: ", ")).") }
                let current = controller.builder.selection
                controller.builder.select(scheme: scheme ?? current.scheme, configuration: configuration ?? current.configuration, root: root)
                return "Selected scheme \(controller.builder.selection.scheme ?? "(default)"), configuration \(controller.builder.selection.configuration ?? "(default)")."
            }
        case .debugStart:
            try await controller.startDebugging()
            await controller.waitForDebugStop(timeout: TimeInterval(int("timeout_seconds") ?? 60))
            return await MainActor.run { controller.debugSummary() }
        case .debugControl:
            let name = try required("action").lowercased()
            guard let action = DevelopController.DebugAction(rawValue: name) else {
                throw DevelopController.IDEError.failed("action must be one of: \(DevelopController.DebugAction.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            try await controller.debug(action)
            return await MainActor.run { controller.debugSummary() }
        case .debugState:
            return await MainActor.run { controller.debugSummary() }
        case .breakpoint:
            let action = try required("action").lowercased()
            switch action {
            case "list":
                return await MainActor.run { controller.debugSummary().components(separatedBy: "Breakpoints:\n").dropFirst().first?.components(separatedBy: "\nConsole").first ?? "No breakpoints." }
            case "set", "remove":
                let path = try required("path")
                guard let line = int("line") else { throw DevelopController.IDEError.failed("Missing required integer argument “line”.") }
                let condition = string("condition")
                try await MainActor.run { try controller.setBreakpoint(path: path, line: line, condition: condition, enabled: action == "set") }
                return action == "set" ? "Breakpoint set at \(path):\(line)" + (condition.map { " if \($0)" } ?? "") + "." : "Breakpoint removed at \(path):\(line)."
            default:
                throw DevelopController.IDEError.failed("action must be set, remove or list.")
            }
        case .debugEval:
            let expression = try required("expression")
            return try await MainActor.run {
                guard controller.editor.debug.isPaused else { throw DevelopController.IDEError.busy("The program is not paused at a breakpoint.") }
                controller.editor.debug.evaluate(expression)
                return "Evaluating. Read the result with ide_debug_state (Console)."
            }
        }
    }

    @MainActor
    static func describeProject(_ controller: DevelopController) -> String {
        let editor = controller.editor, builder = controller.builder
        var lines = ["Folder: \(editor.root?.path ?? "none")", "Kind: \(builder.info.kind.rawValue)"]
        lines.append("Schemes: " + (builder.info.schemes.isEmpty ? "none" : builder.info.schemes.joined(separator: ", ")))
        lines.append("Configurations: " + (builder.info.configurations.isEmpty ? "none" : builder.info.configurations.joined(separator: ", ")))
        lines.append("Selected: scheme \(builder.selection.scheme ?? "(default)"), configuration \(builder.selection.configuration ?? "(default)")")
        lines.append("Build command: \(controller.buildPlan?.command ?? "none detected")")
        switch editor.languageServer.state {
        case .running: lines.append("Language server: running")
        case .starting: lines.append("Language server: starting")
        case .stopped: lines.append("Language server: not started (starts when a Swift or C file is opened)")
        case .failed(let reason): lines.append("Language server: \(reason)")
        }
        lines.append("Open files: " + (editor.documents.isEmpty ? "none" : editor.documents.map { editor.displayPath($0.url) + ($0.isDirty ? "*" : "") }.joined(separator: ", ")))
        return lines.joined(separator: "\n")
    }
}
