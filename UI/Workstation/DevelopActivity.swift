import SwiftUI

extension Activity { static let develop = Activity("develop") }

/// Develop: editor, terminal, git, search, build/run/debug and MCP servers. Built into the shell; its agent tools are the
/// ordinary file, shell and git tools, which are not module-prefixed.
enum DevelopActivity {
    static let descriptor = ActivityDescriptor(
        id: "develop", title: "Develop", symbol: "chevron.left.forwardslash.chevron.right",
        summary: "Terminal, git, search and MCP servers",
        moduleIdentifier: nil,
        content: .custom { _ in AnyView(DevelopView()) },
        starterPrompts: { hasProject in
            let project = StarterPrompts.project(hasProject)
            return project.isEmpty ? [StarterPrompts.hardware] : [project[2], project[1],
                StarterPrompt(title: "Find TODOs", symbol: "list.bullet",
                              text: "Search this project for TODO and FIXME comments and summarise what is outstanding.")]
        },
        toolPrefixes: ["ide_"],
        agentPromptSentence: "Use the ide_* tools to drive the Develop IDE: open files at a line, outline, go to definition, find references, rename, build, test, run and debug with breakpoints (ide_build returns the issues).",
        capabilities: [
            .tool("read_file", "Read a file", .read),
            .tool("write_file", "Write a file", .write),
            .tool("edit_file", "Edit a file", .write),
            .tool("delete_file", "Delete a file", .write),
            .tool("list_directory", "List a folder", .read),
            .tool("glob_files", "Find files by name pattern", .read),
            .tool("grep_files", "Search file contents", .read),
            .tool("search_workspace", "Search the project", .read),
            .tool("run_command", "Run a shell command", .execute),
            .tool("stream_command", "Run a command and stream output", .execute),
            .tool("background_command", "Start a background command", .execute),
            .tool("read_command_output", "Read a background command's output", .read),
            .tool("git_status", "Git status", .read),
            .tool("git_diff", "Git diff", .read),
            .tool("git_commit", "Git commit", .write),
            .tool("git_branch", "Git branch", .write),
            .tool("git_log", "Git log", .read),
            .tool("ide_project", "Describe the open project, schemes and language server", .read),
            .tool("ide_open", "Open a file in the editor at a line", .read),
            .tool("ide_outline", "Symbols declared in a file", .read),
            .tool("ide_definition", "Go to definition", .read),
            .tool("ide_references", "Find references", .read),
            .tool("ide_hover", "Quick Help for a symbol", .read),
            .tool("ide_rename", "Rename a symbol through the language server", .write),
            .tool("ide_diagnostics", "Language-server and build issues", .read),
            .tool("ide_blame", "Git blame for a file", .read),
            .tool("ide_select_scheme", "Choose scheme and configuration", .write),
            .tool("ide_build", "Build and return the issues", .execute),
            .tool("ide_test", "Run tests and return results", .execute),
            .tool("ide_run", "Build and run", .execute),
            .tool("ide_stop", "Cancel a run and end the debugger", .execute),
            .tool("ide_build_status", "Latest build, test or run result", .read),
            .tool("ide_debug_start", "Build and launch under LLDB", .execute),
            .tool("ide_debug_control", "Continue, pause, step or stop the debugger", .execute),
            .tool("ide_debug_state", "Debugger threads, stack, variables and output", .read),
            .tool("ide_breakpoint", "Set, remove or list breakpoints", .write),
            .tool("ide_debug_eval", "Evaluate an expression while paused", .execute),
            .exempt("develop.jump-bar", "Jump bar, navigators, inspector and panel toggles", .read,
                    because: "Layout of the editor window; the agent reads the same facts through ide_outline, ide_diagnostics and ide_project."),
            .exempt("develop.save-buffer", "Save the editor's unsaved buffers", .write,
                    because: "Buffers hold the user's unsaved typing; the agent writes files directly with write_file and the editor reloads them."),
            .exempt("develop.mcp-connect", "Connect or revoke an MCP server", .admin,
                    because: "Deliberate: connecting a server grants it access, so only the user does it; the agent uses mcp_list_tools and mcp_call_tool on approved servers."),
            .exempt("develop.terminal", "Interactive terminal tabs", .execute,
                    because: "An interactive human terminal; the agent has run_command, stream_command and background_command instead."),
            .exempt("develop.remote-pairing", "Pair phones for Kiln Remote", .admin,
                    because: "Deliberate: pairing grants a device control of this Mac, so an agent must not do it."),
            .exempt("develop.mcp-server", "Start or stop Kiln's own MCP endpoint", .admin,
                    because: "Deliberate: exposing Kiln's tools to outside agents is the user's decision, not an agent's."),
        ],
        registerTools: { context in
            if let develop = context.develop { DevelopAgentTools.register(controller: develop, into: context.registry) }
        })
}
