import Foundation

/// The agent can inspect connected servers without silently connecting or trusting new ones.
public struct MCPListTools: ToolExecuting {
    public init() {}
    public var spec: ToolSpec { ToolSpec(name: "mcp_list_tools", summary: "List tools from connected MCP servers", detail: "Only servers explicitly approved and connected in Develop → MCP are available.", permission: .read) }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        guard let mcp = context.services.mcp else { return "MCP service is unavailable." }
        let tools = await mcp.allTools()
        guard !tools.isEmpty else { return "No MCP tools are connected. Connect an approved server in Develop → MCP." }
        let data = try JSONEncoder().encode(tools)
        return ToolOutputCap.fit(String(decoding: data, as: UTF8.self), from: "mcp_list_tools")
    }
}

/// All MCP calls are treated as privileged because an MCP server may act beyond the workspace.
public struct MCPCallTool: ToolExecuting {
    public init() {}
    public var spec: ToolSpec { ToolSpec(name: "mcp_call_tool", summary: "Call a tool on a connected MCP server", detail: "Use the exact server:tool name and JSON arguments shown by mcp_list_tools. Each call requires explicit approval.", parameters: [ToolParam(name: "name", description: "Qualified server:tool name"), ToolParam(name: "arguments_json", description: "JSON object containing the tool arguments")], permission: .admin) }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        struct Args: Decodable { let name: String; let arguments_json: String }
        let input = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let args = try JSONDecoder().decode([String: ProviderJSON].self, from: Data(input.arguments_json.utf8))
        guard let mcp = context.services.mcp else { return "MCP service is unavailable." }
        let result = try await mcp.callTool(qualifiedName: input.name, arguments: args)
        return ToolOutputCap.fit((result.isError ? "MCP tool error: " : "") + result.text, from: "mcp_call_tool")
    }
}
