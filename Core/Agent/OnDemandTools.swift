import Foundation

/// Loads module tools when the model asks for them, instead of sending every definition on every request.
///
/// Kiln has more than 200 tools, about 21,500 tokens of definitions. When those would use more than a tenth of the
/// model's window, a run starts with the core tools (files, search, shell, git, web) and one tool, `kiln_tool_search`.
/// The model searches by what it needs ("email", "calendar"), the matching tools are added to its tool list for the rest
/// of the run, and their definitions are returned in the reply. Calling a tool that has not been loaded loads it and
/// returns its definition instead of running it. The tools themselves, their permissions and their approvals are
/// unchanged; only when the model gets to see them changes.
public final class ToolLoader: @unchecked Sendable {
    public static let searchToolName = "kiln_tool_search"
    /// On-demand loading starts when the full set of definitions would use more than this fraction of the window.
    public static let deferFraction = 0.10
    static let maxLoadedPerSearch = 10

    private let lock = NSLock()
    private let immediate: [ToolSpec]
    private let deferred: [ToolSpec]
    private let groupSummaries: [String: String]
    private var loaded: [String] = []

    public let searchSpec: ToolSpec

    /// Nil when the whole toolbox fits comfortably, in which case every tool is simply offered.
    init?(offered: [ToolSpec], window: Int, activities: [ActivityDescriptor] = ActivityRegistry.standard.descriptors) {
        let total = ContextCompactor.toolSchemaTokens(offered.map(\.providerTool))
        guard Double(total) > Double(window) * Self.deferFraction else { return nil }
        let isCore: (ToolSpec) -> Bool = { ToolFit.coreOrder.contains(ToolFit.group(of: $0.name)) }
        let deferred = offered.filter { !isCore($0) }
        guard !deferred.isEmpty else { return nil }
        self.immediate = offered.filter(isCore)
        self.deferred = deferred
        var summaries: [String: String] = [:]
        for activity in activities {
            for prefix in activity.toolPrefixes { summaries[String(prefix.split(separator: "_").first ?? Substring(prefix))] = activity.summary }
        }
        self.groupSummaries = summaries
        self.searchSpec = Self.makeSearchSpec(deferred: deferred, summaries: summaries)
    }

    private static func makeSearchSpec(deferred: [ToolSpec], summaries: [String: String]) -> ToolSpec {
        let groups = Dictionary(grouping: deferred, by: { ToolFit.group(of: $0.name) })
        let order = ToolFit.groupOrder.filter { groups[$0] != nil } + groups.keys.filter { !ToolFit.groupOrder.contains($0) }.sorted()
        let catalog = order.map { name -> String in
            let count = groups[name]?.count ?? 0
            let about = summaries[name].map { ": \($0)" } ?? ""
            return "\(name) (\(count))\(about)"
        }.joined(separator: "; ")
        return ToolSpec(
            name: searchToolName,
            summary: "Load more tools by what you need. Tools beyond the basics are not listed until you load them.",
            detail: "Groups you can load, with their tool counts: \(catalog). Pass a few keywords (\"email\", \"calendar reminders\") or select:name1,name2 for exact names. The matching tools become callable in your next step.",
            parameters: [ToolParam(name: "query", type: "string", description: "Keywords, or select: followed by comma-separated tool names", required: true)],
            permission: .read
        )
    }

    /// The tools the model should see right now: the basics, the search tool, and whatever it has loaded.
    public func offered() -> [ToolSpec] {
        lock.lock(); defer { lock.unlock() }
        return immediate + [searchSpec] + deferred.filter { loaded.contains($0.name) }
    }

    /// The tools a run starts with. For the context meter, which has no run yet.
    public func initial() -> [ToolSpec] { immediate + [searchSpec] }

    public func isDeferredAndNotLoaded(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return deferred.contains { $0.name == name } && !loaded.contains(name)
    }

    /// Loads one named tool and describes it, for a call that arrived before it was loaded.
    public func loadNamed(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let spec = deferred.first(where: { $0.name == name }) else { return nil }
        if !loaded.contains(name) { loaded.append(name) }
        return "\(name) was not loaded, so it did not run. It is loaded now; call it again.\n" + Self.describe(spec)
    }

    /// Runs a search, loads the best matches and returns the text the model reads.
    public func search(_ rawQuery: String) -> String {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        var matches: [ToolSpec] = []
        if query.lowercased().hasPrefix("select:") {
            let names = query.dropFirst("select:".count).split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0).lowercased() }
            matches = names.compactMap { name in deferred.first { $0.name.lowercased() == name } }
        } else {
            let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
            let scored = deferred.compactMap { spec -> (ToolSpec, Int)? in
                var score = 0
                let name = spec.name.lowercased(), group = ToolFit.group(of: spec.name)
                let text = (spec.summary + " " + spec.detail).lowercased() + " " + (groupSummaries[group]?.lowercased() ?? "")
                for word in words {
                    if group == word { score += 10 } else if name.contains(word) { score += 5 }
                    if text.contains(word) { score += 2 }
                }
                return score > 0 ? (spec, score) : nil
            }
            matches = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }.prefix(Self.maxLoadedPerSearch).map(\.0)
        }
        guard !matches.isEmpty else {
            let groups = Set(deferred.map { ToolFit.group(of: $0.name) }).sorted().joined(separator: ", ")
            return "No tool matches \"\(query)\". Tool groups: \(groups)."
        }
        for spec in matches where !loaded.contains(spec.name) { loaded.append(spec.name) }
        return "Loaded \(matches.count) tool\(matches.count == 1 ? "" : "s"); you can call \(matches.count == 1 ? "it" : "them") now.\n" + matches.map(Self.describe).joined(separator: "\n")
    }

    static func describe(_ spec: ToolSpec) -> String {
        let args = spec.parameters.map { "\($0.name)\($0.required ? "" : "?"): \($0.type)" }.joined(separator: ", ")
        return "- \(spec.name)(\(args)): \(spec.summary)"
    }
}
