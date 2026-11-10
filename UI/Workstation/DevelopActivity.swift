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
            .exempt("develop.open-at-line", "Open a file in the editor at a line", .read,
                    because: "Gap: no tool yet to focus the editor on a file and line (docs/13, Workspace files)."),
            .exempt("develop.save-buffer", "Save the editor's unsaved buffers", .write,
                    because: "Buffers hold the user's unsaved typing; the agent writes files directly with write_file and the editor reloads them."),
            .exempt("develop.build", "Build the selected scheme", .execute,
                    because: "Gap: no service-backed build/test/run adapter or scheme picker tool yet; run_command can call xcodebuild meanwhile (docs/13, Development)."),
            .exempt("develop.test", "Run tests", .execute,
                    because: "Gap: same as develop.build; run_command can call the test runner meanwhile."),
            .exempt("develop.debug", "Debug under LLDB (breakpoints, step, inspect)", .execute,
                    because: "Gap: no debugger adapter for agents yet (docs/13, Development)."),
            .exempt("develop.diagnostics", "Language-server diagnostics and Problems", .read,
                    because: "Gap: the Problems list is not exposed as a tool yet."),
            .exempt("develop.mcp-connect", "Connect or revoke an MCP server", .admin,
                    because: "Deliberate: connecting a server grants it access, so only the user does it; the agent uses mcp_list_tools and mcp_call_tool on approved servers."),
            .exempt("develop.terminal", "Interactive terminal tabs", .execute,
                    because: "An interactive human terminal; the agent has run_command, stream_command and background_command instead."),
            .exempt("develop.remote-pairing", "Pair phones for Kiln Remote", .admin,
                    because: "Deliberate: pairing grants a device control of this Mac, so an agent must not do it."),
            .exempt("develop.mcp-server", "Start or stop Kiln's own MCP endpoint", .admin,
                    because: "Deliberate: exposing Kiln's tools to outside agents is the user's decision, not an agent's."),
        ])
}
