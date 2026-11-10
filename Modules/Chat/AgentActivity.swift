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
        agentToolPatterns: ["mcp_*", "computer_use"],
        agentPromptSentence: "Use list_skills / read_skill for installed skills. Use mcp_list_tools and mcp_call_tool for connected MCP servers. Use computer_use to inspect or control running Mac apps after the user enables it; inspect before interacting.",
        capabilities: [
            .tool("web_fetch", "Fetch a web page", .execute),
            .tool("web_search", "Search the web", .execute),
            .tool("list_skills", "List installed skills", .read),
            .tool("read_skill", "Read a skill", .read),
            .tool("mcp_list_tools", "List tools of connected MCP servers", .read),
            .tool("mcp_call_tool", "Call a connected MCP server's tool", .admin),
            .tool("computer_use", "Inspect or control a running Mac app", .admin),
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
