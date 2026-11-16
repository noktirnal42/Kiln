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
            .tool("maps_directions", "Find directions with alternatives, ETA and steps", .execute),
            .tool("maps_location", "Read last requested location", .execute),
            .tool("maps_viewport", "Inspect map viewport", .read),
            .tool("maps_navigate", "Navigate map", .write),
            .tool("maps_set_layer", "Change map layer", .write),
            .tool("maps_search_places", "Search for a place", .execute),
            .tool("maps_search_historical", "Find historical USGS maps", .execute),
            .tool("maps_bookmark", "Create a named region bookmark", .write),
            .tool("maps_category_search", "Search for places by category", .execute),
            .tool("maps_export_gpx", "Export map pins and route as a GPX file", .write),
            .tool("maps_flyover", "Show realistic 3D imagery", .write),
            .tool("maps_import_gpx", "Import a GPX file", .execute),
            .tool("maps_offline_download", "Explain that offline maps are not available", .read),
            .tool("maps_select_route", "Show one of the alternative routes", .write),
            .tool("maps_save_state", "Save current map state as artifact", .write),
            .tool("maps_transit_routing", "Calculate transit/walking/cycling directions", .execute),
        ], registerTools: { context in MapsTool.register(into: context.registry) })
}
