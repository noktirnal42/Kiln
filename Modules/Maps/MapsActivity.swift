import SwiftUI

extension Activity { static let maps = Activity("maps") }

enum MapsActivity {
    static let descriptor = ActivityDescriptor(
        id: "maps", title: "Maps", symbol: "map", summary: "Explore places, USGS topography and historical maps",
        moduleIdentifier: nil, content: .custom { _ in AnyView(MapsView()) },
        starterPrompts: { _ in [StarterPrompt(title: "Explore a place", symbol: "map", text: "Find a place on the map and look for historical USGS maps covering it.")] },
        toolPrefixes: ["maps_", "weather_"], agentPromptSentence: "Use maps_* tools to inspect or navigate Maps and search USGS historical map records. Use weather_forecast and weather_alerts for US weather (source, issue time and alert office are in the reply; official warnings decide safety).",
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
            .tool("maps_bookmark", "Create a named region bookmark", .write),
            .tool("maps_category_search", "Search for places by category", .execute),
            .tool("maps_export_gpx", "Export map routes and pins as GPX", .write),
            .tool("maps_flyover", "Activate 3D flyover view", .execute),
            .tool("maps_import_gpx", "Import GPX or KML file", .execute),
            .tool("maps_offline_download", "Download offline map region", .execute),
            .tool("maps_save_state", "Save current map state as artifact", .write),
            .tool("maps_transit_routing", "Calculate transit/walking/cycling directions", .execute),
            .tool("weather_forecast", "Forecast and alerts for a US place (National Weather Service)", .execute),
            .tool("weather_alerts", "Active weather alerts for a US place", .execute),
        ], registerTools: { context in MapsTool.register(into: context.registry); WeatherTool.register(into: context.registry) })
}
