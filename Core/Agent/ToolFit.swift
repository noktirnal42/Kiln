import Foundation

/// Fits the tool list to the model's context window.
///
/// Every tool's definition is sent on every request. Kiln has more than 200 tools (about 21,000 tokens of definitions),
/// which is fine for a model with a 128K window and fatal for one with 8K: the definitions alone overflow it, no amount
/// of compaction can make room, and the message never goes through. So a model whose window cannot carry the whole
/// toolbox is offered the core tools first, then whole groups of module tools in a fixed order of usefulness, until the
/// definitions use `share` of the window. A big enough window changes nothing.
public enum ToolFit {
    public struct Result: Sendable {
        public var tools: [ToolSpec]
        public var totalCount: Int
        public var omittedGroups: [String]
        public var trimmed: Bool { tools.count < totalCount }
    }

    /// Tools every run needs: files, search, shell, git, web, MCP and Kiln's own task list, in the order they are kept.
    static let coreOrder = ["read", "list", "glob", "grep", "search", "edit", "write", "run", "git", "web", "stream", "background", "delete", "mcp", "kiln"]
    /// Module tool groups (the text before the first underscore), most generally useful first. Groups not listed come last.
    static let groupOrder = ["ide", "browser", "computer", "mail", "messages", "slack", "notify", "notifications", "calendar", "reminders", "contacts", "notes", "github",
                             "drive", "pdf", "library", "news", "media", "image", "maps", "device", "lab", "re"]

    /// The fraction of the window the tool definitions may use.
    public static let defaultShare = 0.3

    static func group(of name: String) -> String { String(name.split(separator: "_").first ?? Substring(name)) }

    public static func fit(_ specs: [ToolSpec], window: Int, share: Double = defaultShare) -> Result {
        let weights = specs.map { ContextCompactor.toolSchemaTokens([$0.providerTool]) }
        let total = weights.reduce(0, +)
        let allowance = Int(Double(window) * share)
        guard total > allowance else { return Result(tools: specs, totalCount: specs.count, omittedGroups: []) }

        var used = 0
        var kept = Set<Int>()
        // Core tools one by one, in order.
        let core = specs.indices.filter { coreOrder.contains(group(of: specs[$0].name)) }
            .sorted { (coreOrder.firstIndex(of: group(of: specs[$0].name)) ?? 0, $0) < (coreOrder.firstIndex(of: group(of: specs[$1].name)) ?? 0, $1) }
        for index in core where used + weights[index] <= allowance { kept.insert(index); used += weights[index] }

        // Module groups whole, so a group is never half there.
        var members: [String: [Int]] = [:]
        for index in specs.indices where !coreOrder.contains(group(of: specs[index].name)) { members[group(of: specs[index].name), default: []].append(index) }
        let ordered = groupOrder.filter { members[$0] != nil } + members.keys.filter { !groupOrder.contains($0) }.sorted()
        var omitted: [String] = []
        for name in ordered {
            let indices = members[name] ?? []
            let weight = indices.reduce(0) { $0 + weights[$1] }
            if used + weight <= allowance { kept.formUnion(indices); used += weight } else { omitted.append(name) }
        }
        let tools = specs.indices.filter { kept.contains($0) }.map { specs[$0] }
        return Result(tools: tools, totalCount: specs.count, omittedGroups: omitted)
    }
}
