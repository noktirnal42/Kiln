import Foundation

struct MapsTool: ToolExecuting {
    enum Kind: String, CaseIterable { case pins, remove_pin, clear_route, add_pin, directions, location, viewport, navigate, set_layer, search_places, search_historical }
    let kind: Kind
    @MainActor static func register(into registry: ToolRegistry) { for kind in Kind.allCases { registry.register(MapsTool(kind: kind)) } }
    var spec: ToolSpec {
        switch kind {
        case .pins: ToolSpec(name: "maps_pins", summary: "List session map pins with IDs and coordinates.", permission: .read)
        case .remove_pin: ToolSpec(name: "maps_remove_pin", summary: "Remove a session map pin by its exact ID. Requires approval.", parameters: [ToolParam(name: "id", description: "Pin ID from maps_pins")], permission: .write)
        case .clear_route: ToolSpec(name: "maps_clear_route", summary: "Clear the displayed route. Requires approval.", permission: .write)
        case .add_pin: ToolSpec(name: "maps_add_pin", summary: "Add a named pin to the map. Requires approval.", parameters: [ToolParam(name: "name", description: "Pin name"), ToolParam(name: "latitude", type: "number", description: "Latitude"), ToolParam(name: "longitude", type: "number", description: "Longitude")], permission: .write)
        case .directions: ToolSpec(name: "maps_directions", summary: "Calculate driving directions from the map center to a destination using Apple Maps. Requires approval and sends coordinates to Apple.", parameters: [ToolParam(name: "latitude", type: "number", description: "Destination latitude"), ToolParam(name: "longitude", type: "number", description: "Destination longitude")], permission: .execute)
        case .location: ToolSpec(name: "maps_location", summary: "Read the last location explicitly requested in Maps, including accuracy and time. Requires approval; never requests macOS location permission itself.", permission: .execute)
        case .viewport: ToolSpec(name: "maps_viewport", summary: "Read the Maps activity's center, span and selected layer.", permission: .read)
        case .navigate: ToolSpec(name: "maps_navigate", summary: "Move the Maps activity to coordinates. Requires approval.", parameters: [ToolParam(name: "latitude", type: "number", description: "Latitude in degrees"), ToolParam(name: "longitude", type: "number", description: "Longitude in degrees"), ToolParam(name: "span", type: "number", description: "Approximate width in degrees, 0.001 to 90", required: false)], permission: .write)
        case .set_layer: ToolSpec(name: "maps_set_layer", summary: "Change the Maps activity's base layer. Requires approval.", parameters: [ToolParam(name: "layer", description: "standard, imagery, or usgs_topo")], permission: .write)
        case .search_places: ToolSpec(name: "maps_search_places", summary: "Search Apple MapKit for named places; sends the query to Apple. Requires approval.", parameters: [ToolParam(name: "query", description: "Place name or address")], permission: .execute)
        case .search_historical: ToolSpec(name: "maps_search_historical", summary: "Search USGS historical map records for the current viewport. Sends coordinates to USGS; requires approval. Returns up to 50 records, not downloaded maps.", permission: .execute)
        }
    }
    func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = ToolArgs.object(from: argumentsJSON) ?? [:]
        return try await run(args)
    }
    @MainActor private func run(_ args: [String: Any]) async throws -> String {
        let state = MapsState.shared
        switch kind {
        case .pins: return state.pins.isEmpty ? "No pins." : state.pins.map { "\($0.id.uuidString) | \($0.name) | \($0.latitude), \($0.longitude)" }.joined(separator: "\n")
        case .remove_pin:
            guard let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)), state.pins.contains(where: { $0.id == id }) else { throw MapsError.invalid("Pin not found.") }
            state.pins.removeAll { $0.id == id }; state.routeRevision += 1; return "Pin removed."
        case .clear_route: state.route = nil; state.routeRevision += 1; return "Route cleared."
        case .add_pin:
            guard let lat = args["latitude"] as? Double, let lon = args["longitude"] as? Double else { throw MapsError.invalid("Coordinates required.") }
            try state.addPin(name: args["name"] as? String ?? "", latitude: lat, longitude: lon); return "Pin added."
        case .directions:
            guard let lat = args["latitude"] as? Double, let lon = args["longitude"] as? Double else { throw MapsError.invalid("Coordinates required.") }
            return try await state.directions(latitude: lat, longitude: lon)
        case .location:
            guard let location = MapsLocation.shared.location else { return "No location available. Use My Location in Maps and allow macOS Location Services." }
            return "Latitude: \(location.coordinate.latitude), longitude: \(location.coordinate.longitude), accuracy: \(location.horizontalAccuracy) meters, timestamp: \(location.timestamp.ISO8601Format())."
        case .viewport: return "Center: \(state.latitude), \(state.longitude); span: \(state.latitudeSpan) × \(state.longitudeSpan) degrees; layer: \(state.layer)"
        case .navigate:
            guard let lat = args["latitude"] as? Double, let lon = args["longitude"] as? Double else { throw MapsError.invalid("latitude and longitude are required numbers.") }
            try state.navigate(latitude: lat, longitude: lon, span: args["span"] as? Double ?? 0.15); return "Map centered at \(lat), \(lon)."
        case .set_layer:
            guard let layer = args["layer"] as? String else { throw MapsError.invalid("layer is required.") }
            try state.setLayer(layer); return "Map layer: \(layer)."
        case .search_places: return try await state.places(args["query"] as? String ?? "").map { "\($0.name) | \($0.latitude), \($0.longitude)" }.joined(separator: "\n")
        case .search_historical:
            let maps = try await state.searchHistorical()
            return maps.isEmpty ? "No historical map records found for this viewport." : maps.map { "\($0.title) | \($0.publicationDate ?? "date unknown") | \($0.format ?? "format unknown") | \($0.downloadURL?.absoluteString ?? "no download URL")" }.joined(separator: "\n")
        }
    }
}
