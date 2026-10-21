import Foundation

/// Exposes one RE MCP definition to the agent runtime as an ordinary tool.
/// Every call dispatches through `REMCPTools` onto the live `REModule`, so the
/// agent sees exactly what the module declares and nothing more.
public struct REAgentTool: ToolExecuting {
    let definition: REMCPToolDefinition
    let module: REModule

    public init(definition: REMCPToolDefinition, module: REModule) {
        self.definition = definition
        self.module = module
    }

    /// Tool names are prefixed so RE tools never collide with built-in tools.
    public var spec: ToolSpec {
        ToolSpec(
            name: REAgentTools.prefix + definition.name,
            summary: definition.description,
            detail: "Reverse Engineering Console tool `\(definition.name)`. "
                + (definition.readOnly ? "Read-only." : "May change project state."),
            parameters: Self.parameters(from: definition.inputSchema),
            permission: definition.readOnly ? .read : .write,
            isDestructive: false
        )
    }

    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let data = Data(argumentsJSON.utf8)
        let arguments = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return try await REMCPTools.call(tool: definition.name, arguments: arguments, service: module)
    }

    /// Flattens a JSON Schema `properties` object into the tool parameter shape.
    static func parameters(from schema: [String: Any]) -> [ToolParam] {
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        return properties.keys.sorted().map { key in
            let property = properties[key] as? [String: Any] ?? [:]
            return ToolParam(
                name: key,
                type: property["type"] as? String ?? "string",
                description: property["description"] as? String ?? "",
                required: required.contains(key)
            )
        }
    }
}

public enum REAgentTools {
    public static let prefix = "re_"

    /// Registers every RE MCP tool against the live module. Call once the module is loaded.
    @MainActor
    public static func register(module: REModule, into registry: ToolRegistry = .shared) {
        for definition in REMCPTools.definitions {
            registry.register(REAgentTool(definition: definition, module: module))
        }
    }
}
