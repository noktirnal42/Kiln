import SwiftUI

extension Activity { static let maps = Activity("maps") }

enum MapsActivity {
    static let descriptor = ActivityDescriptor(
        id: "maps", title: "Maps", symbol: "map", summary: "Explore places, USGS topography and historical maps",
        moduleIdentifier: nil, content: .custom { _ in AnyView(MapsView()) },
        starterPrompts: { _ in [StarterPrompt(title: "Explore a place", symbol: "map", text: "Find a place on the map and look for historical USGS maps covering it.")] },
        toolPrefixes: ["maps_"], agentPromptSentence: "Use maps_* tools to inspect or navigate Maps and search USGS historical map records.",
        capabilities: [
            .tool("maps_pins", "List map pins", .read),
            .tool("maps_remove_pin", "Remove a map pin", .write),
            .tool("maps_clear_route", "Clear the displayed route", .write),
            .tool("maps_add_pin", "Add a map pin", .write),
            .tool("maps_directions", "Find driving directions", .execute),
            .tool("maps_location", "Read last requested location", .execute),
            .tool("maps_viewport", "Inspect map viewport", .read),
            .tool("maps_navigate", "Navigate map", .write),
            .tool("maps_set_layer", "Change map layer", .write),
            .tool("maps_search_places", "Search for a place", .execute),
            .tool("maps_search_historical", "Find historical USGS maps", .execute),
        ], registerTools: { context in MapsTool.register(into: context.registry) })
}
