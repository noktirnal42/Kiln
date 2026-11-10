import SwiftUI

extension Activity { static let agent = Activity("agent") }

/// Agent: the conversation. It owns the cross-cutting tools that are not tied to one module (web, skills, MCP client,
/// computer use), so the Workstation Agent's prompt sentence about them lives here.
enum AgentActivity {
    static let descriptor = ActivityDescriptor(
        id: "agent", title: "Agent", symbol: "sparkles", summary: "Converse with a model, with tools",
        moduleIdentifier: ChatModule.identifier,
        showsInSidebar: false,
        showsAgentDock: false,   // the dock would be a second copy of this conversation
        starterPrompts: { hasProject in StarterPrompts.project(hasProject) + [StarterPrompts.binary, StarterPrompts.hardware] },
        toolPrefixes: ["mcp_", "computer_"],
        agentToolPatterns: ["mcp_*", "computer_use", "kiln_*"],
        agentPromptSentence: "Use list_skills / read_skill for installed skills. Use mcp_list_tools and mcp_call_tool for connected MCP servers. Use computer_use to inspect or control running Mac apps after the user enables it; inspect before interacting.",
        capabilities: [
            .tool("web_fetch", "Fetch a web page", .execute),
            .tool("web_search", "Search the web", .execute),
            .tool("list_skills", "List installed skills", .read),
            .tool("read_skill", "Read a skill", .read),
            .tool("mcp_list_tools", "List tools of connected MCP servers", .read),
            .tool("mcp_call_tool", "Call a connected MCP server's tool", .admin),
            .tool("computer_use", "Inspect or control a running Mac app", .admin),
            .tool("kiln_memory_read", "Show the memory files in use", .read),
            .tool("kiln_memory_write", "Write a memory file (KILN.md, AGENTS.md, CLAUDE.md)", .write),
            .tool("kiln_command_list", "List slash commands", .read),
            .tool("kiln_command_expand", "Expand a custom slash command", .read),
            .tool("kiln_command_write", "Create or replace a custom slash command", .write),
            .tool("kiln_hooks_list", "List configured hooks", .read),
            .tool("kiln_checkpoint_list", "List file checkpoints", .read),
            .exempt("agent.rewind", "Rewind files and conversation to an earlier message", .write,
                    because: "Deliberate: rewinding discards work, so the person does it from the conversation; the agent can list checkpoints."),
            .exempt("agent.sessions", "List sessions with status; resume and fork them", .read,
                    because: "Gap: the conversation store is not yet reachable from tools (docs/13, Chat and artifacts); the Sessions pane (/sessions) covers it for the person."),
            .tool("kiln_usage_report", "Tokens and estimated cost by provider, model and day", .read),
            .exempt("agent.usage-budget", "Set prices and the daily budget", .write,
                    because: "Deliberate: the budget limits the agent, so an agent must not be able to raise it."),
            .exempt("agent.plan", "Approve or reject a proposed plan", .write,
                    because: "Deliberate: a plan is approved by the person; an agent approving its own plan would defeat plan mode."),
            .exempt("agent.new-conversation", "Start a new conversation", .write,
                    because: "Gap: conversation management has no tool yet (docs/13, Chat and artifacts); an agent starting its own fresh context is better served by compaction."),
            .exempt("agent.choose-model", "Choose the model and agent profile", .admin,
                    because: "Deliberate: the model and profile decide what the agent may do, so the user picks them."),
            .exempt("agent.approvals", "Approve or deny tool calls and standing grants", .admin,
                    because: "Deliberate: an agent must never approve itself or alter the approval policy."),
            .exempt("agent.artifacts", "Create and export artifacts", .write,
                    because: "Gap: artifact creation, rendering and export have no tool yet (docs/13, Chat and artifacts)."),
        ])
}
