import Foundation

struct MapsTool: ToolExecuting {
    enum Kind: String, CaseIterable {
        // Original tools (unchanged)
        case pins, remove_pin, clear_route, add_pin, directions, location, viewport, navigate, set_layer
        case search_places, search_historical
        // Parity additions for Apple Maps feature completeness
        case transit_routing, flyover, offline_download, category_search
        case save_state, bookmark, import_gpx, export_gpx, select_route
    }
    let kind: Kind
    @MainActor static func register(into registry: ToolRegistry) { for kind in Kind.allCases { registry.register(MapsTool(kind: kind)) } }
    var spec: ToolSpec {
        switch kind {
        // Original tools (unchanged specs)
        case .pins: ToolSpec(name: "maps_pins", summary: "List session map pins with IDs and coordinates.", permission: .read)
        case .remove_pin: ToolSpec(name: "maps_remove_pin", summary: "Remove a session map pin by its exact ID. Requires approval.", parameters: [ToolParam(name: "id", type: "string", description: "Pin ID from maps_pins", required: false)], permission: .write)
        case .clear_route: ToolSpec(name: "maps_clear_route", summary: "Clear the displayed route. Requires approval.", permission: .write)
        case .add_pin: ToolSpec(name: "maps_add_pin", summary: "Add a named pin to the map. Requires approval.", parameters: [ToolParam(name: "name", type: "string", description: "Pin name"), ToolParam(name: "latitude", type: "number", description: "Latitude"), ToolParam(name: "longitude", type: "number", description: "Longitude")], permission: .write)
        case .directions: ToolSpec(name: "maps_directions", summary: "Calculate directions (driving by default) from the map center to a destination using Apple Maps, with ETA and steps. Requires approval and sends coordinates to Apple.", parameters: [ToolParam(name: "latitude", type: "number", description: "Destination latitude"), ToolParam(name: "longitude", type: "number", description: "Destination longitude"), ToolParam(name: "route_mode", type: "string", description: "driving (default), walking, cycling or transit", required: false), ToolParam(name: "alternatives", type: "boolean", description: "Also return alternative routes with distance, time and arrival", required: false)], permission: .execute)
        case .location: ToolSpec(name: "maps_location", summary: "Read the last location explicitly requested in Maps, including accuracy and time. Requires approval; never requests macOS location permission itself.", permission: .execute)
        case .viewport: ToolSpec(name: "maps_viewport", summary: "Read the Maps activity's center, span and selected layer.", permission: .read)
        case .navigate: ToolSpec(name: "maps_navigate", summary: "Move the Maps activity to coordinates. Requires approval.", parameters: [ToolParam(name: "latitude", type: "number", description: "Latitude in degrees"), ToolParam(name: "longitude", type: "number", description: "Longitude in degrees"), ToolParam(name: "span", type: "number", description: "Approximate width in degrees, 0.001 to 90", required: false)], permission: .write)
        case .set_layer: ToolSpec(name: "maps_set_layer", summary: "Change the Maps activity's base layer. Requires approval.", parameters: [ToolParam(name: "layer", type: "string", description: "standard, satellite, hybrid, terrain, or usgs_topo")], permission: .write)
        case .search_places: ToolSpec(name: "maps_search_places", summary: "Search Apple MapKit for named places; sends the query to Apple. Requires approval.", parameters: [ToolParam(name: "query", type: "string", description: "Place name or address")], permission: .execute)
        case .search_historical: ToolSpec(name: "maps_search_historical", summary: "Search USGS historical map records for the current viewport. Sends coordinates to USGS; requires approval. Returns up to 50 records, not downloaded maps.", permission: .execute)
        // Parity additions
        case .transit_routing: ToolSpec(name: "maps_transit_routing", summary: "Calculate transit/walking/cycling directions from map center to destination. Requires approval and sends coordinates to Apple.", parameters: [ToolParam(name: "latitude", type: "number", description: "Destination latitude"), ToolParam(name: "longitude", type: "number", description: "Destination longitude"), ToolParam(name: "route_mode", type: "string", description: "walking, cycling, or transit")], permission: .execute)
        case .flyover: ToolSpec(name: "maps_flyover", summary: "Switch the map to realistic 3D imagery at the current location (MapKit imagery with elevation; Apple's Flyover tours are not available to apps). Requires approval.", permission: .write)
        case .offline_download: ToolSpec(name: "maps_offline_download", summary: "Not available: MapKit has no public offline-maps API. Returns an explanation; use maps_export_gpx or the USGS layer instead.", permission: .read)
        case .category_search: ToolSpec(name: "maps_category_search", summary: "Search for places by category (restaurants, gas, hotels, etc.). Requires approval and sends query to Apple.", parameters: [ToolParam(name: "query", type: "string", description: "Place category or filter"), ToolParam(name: "filters", type: "string", description: "Optional refinements (e.g. open now, price level)", required: false)], permission: .execute)
        case .save_state: ToolSpec(name: "maps_save_state", summary: "Save current map state (center, zoom, layers, pins, route) as a project artifact. Write, requires approval.", permission: .write)
        case .bookmark: ToolSpec(name: "maps_bookmark", summary: "Create a named region bookmark with center coordinates and span. Write, requires approval.", parameters: [ToolParam(name: "name", type: "string", description: "Bookmark name"), ToolParam(name: "latitude", type: "number", description: "Center latitude"), ToolParam(name: "longitude", type: "number", description: "Center longitude"), ToolParam(name: "span", type: "number", description: "Approximate width in degrees")], permission: .write)
        case .import_gpx: ToolSpec(name: "maps_import_gpx", summary: "Import a GPX file: waypoints become pins and the first track or route is drawn. KML is not supported. Requires approval.", parameters: [ToolParam(name: "file_path", type: "string", description: "Path to a .gpx file (10 MB at most)")], permission: .execute)
        case .export_gpx: ToolSpec(name: "maps_export_gpx", summary: "Write the pins and the shown route to a new .gpx file. Refuses to overwrite. Requires approval.", parameters: [ToolParam(name: "file_path", type: "string", description: "Where to write the .gpx file (must not exist)")], permission: .write)
        case .select_route: ToolSpec(name: "maps_select_route", summary: "Show one of the alternatives from the last maps_directions call on the map. Requires approval.", parameters: [ToolParam(name: "index", type: "integer", description: "1-based route number")], permission: .write)
        }
    }
    func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        let args = ToolArgs.object(from: argumentsJSON) ?? [:]
        return try await run(args)
    }
    static func mode(_ text: String?) -> MapsState.RouteMode {
        switch text?.lowercased() { case "walking": .walking; case "cycling": .cycling; case "transit": .transit; default: .automobile }
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
            return try await state.directions(latitude: lat, longitude: lon, routeMode: Self.mode(args["route_mode"] as? String), alternatives: args["alternatives"] as? Bool ?? false)
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
        case .search_historical: let maps = try await state.searchHistorical(); return maps.isEmpty ? "No historical map records found for this viewport." : maps.map { "\($0.title) | \($0.publicationDate ?? "date unknown") | \($0.format ?? "format unknown") | \($0.downloadURL?.absoluteString ?? "no download URL")" }.joined(separator: "\n")
        // Parity additions
        case .transit_routing:
            guard let lat = args["latitude"] as? Double, let lon = args["longitude"] as? Double else { throw MapsError.invalid("Coordinates required.") }
            return try await state.directions(latitude: lat, longitude: lon, routeMode: Self.mode(args["route_mode"] as? String))
        case .flyover:
            try state.setLayer("flyover"); return "Showing realistic 3D imagery at \(state.latitude), \(state.longitude). Tilt the map to see elevation; Apple's Flyover tours are not available to apps."
        case .offline_download:
            throw MapsError.invalid("Offline maps are not available: MapKit has no public API for them. Use maps_export_gpx to keep a route, or the USGS topo layer.")
        case .category_search:
            guard let query = args["query"] as? String else { throw MapsError.invalid("query is required.") }
            let filters = args["filters"] as? String
            return try await state.categorySearch([query, filters].compactMap { $0 }.joined(separator: " "), filters: filters).map { "\($0.name) | \($0.latitude), \($0.longitude)" }.joined(separator: "\n")
        case .save_state:
            let artifact = state.saveMapState(); return "Map state saved as artifact (pins: \(artifact.pinsCount), route: \(artifact.hasRoute))."
        case .bookmark:
            guard let name = args["name"] as? String, let lat = args["latitude"] as? Double, let lon = args["longitude"] as? Double else { throw MapsError.invalid("name, latitude, longitude required.") }
            try state.addBookmark(name: name, latitude: lat, longitude: lon, span: args["span"] as? Double ?? 0.15); return "Bookmark '\(name)' created."
        case .import_gpx:
            guard let path = args["file_path"] as? String, path.lowercased().hasSuffix(".gpx") else { throw MapsError.invalid("file_path must be a .gpx file.") }
            let url = URL(fileURLWithPath: path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= GPX.maxBytes else { throw GPXError.tooLarge }
            guard let data = try? Data(contentsOf: url) else { throw MapsError.invalid("Could not read \(url.lastPathComponent).") }
            return try state.importGPX(data)
        case .export_gpx:
            guard let path = args["file_path"] as? String, path.lowercased().hasSuffix(".gpx") else { throw MapsError.invalid("file_path must end in .gpx.") }
            let url = URL(fileURLWithPath: path)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw MapsError.invalid("\(url.lastPathComponent) already exists; choose a new name.") }
            guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { throw MapsError.invalid("The folder does not exist.") }
            try state.exportGPX().write(to: url, atomically: true, encoding: .utf8)
            return "Wrote \(url.lastPathComponent): \(state.pins.count) waypoints and \(state.route != nil ? "the shown route" : (state.track.isEmpty ? "no track" : "the imported track"))."
        case .select_route:
            guard let number = args["index"] as? Int, state.routes.indices.contains(number - 1) else { throw MapsError.invalid("No such route. Run maps_directions with alternatives first.") }
            state.selectRoute(number - 1); return "Showing route \(number) of \(state.routes.count)."
        }
    }
}