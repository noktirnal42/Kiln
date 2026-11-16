import Foundation
import MapKit
import Observation

struct HistoricalMap: Decodable, Identifiable, Sendable {
    let sourceId: String
    let title: String
    let publicationDate: String?
    let format: String?
    let downloadURL: URL?
    let metaUrl: URL?
    var id: String { sourceId }
}

struct MapPlace: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let latitude: Double
    let longitude: Double
}

@MainActor @Observable final class MapsState {
    static let shared = MapsState()
    var latitude = 33.4484
    var longitude = -112.0740
    var latitudeSpan = 0.15
    var longitudeSpan = 0.15
    var layer = "standard"  // standard, satellite, hybrid, terrain, imagery, usgs_topo, transit, flyover
    var mapType: MapType = .standard  // track explicit map type
    var historical: [HistoricalMap] = []
    var placeResults: [MapPlace] = []
    var pins: [MapPlace] = []
    var route: MKRoute?
    /// Every route of the last Directions request (alternatives), and the one shown.
    var routes: [MKRoute] = []
    var selectedRouteIndex = 0
    /// A line from an imported GPX file.
    var track: [CLLocationCoordinate2D] = []
    var routeRevision = 0
    var mapState: MapStateArtifact?  // saved map state
    var bookmarks: [MapBookmark] = []  // region bookmarks
    var message: String?
    var query = ""
    var busy = false
    var revision = 0
    // Radar layer (NOAA MRMS, contiguous US). Frames are the service's own timestamps, oldest first.
    var radarOn = false
    var radarOpacity = 0.7
    var radarFrames: [Date] = []
    var radarIndex = 0
    var radarFetched: Date?
    var radarPlaying = false
    var radarMessage: String?
    var radarRevision = 0

    var radarFrame: Date? { radarFrames.indices.contains(radarIndex) ? radarFrames[radarIndex] : nil }

    /// Shows or hides radar. Showing fetches the frame list and starts on the newest frame; a failure leaves the layer off and says why.
    func setRadar(_ on: Bool, service: RadarService = RadarService()) async {
        guard on else { radarOn = false; radarPlaying = false; radarMessage = nil; radarRevision += 1; return }
        radarMessage = "Loading radar…"
        do {
            let loaded = try await service.frames()
            radarFrames = loaded.frames; radarIndex = loaded.frames.count - 1; radarFetched = loaded.fetched
            radarOn = true
            if RadarWMS.covers(latitude: latitude, longitude: longitude) {
                radarMessage = loaded.isStale() ? "Radar is more than 20 minutes old; the service may be behind." : nil
            } else {
                radarMessage = "Radar covers the contiguous United States only; nothing is drawn for this area."
            }
        } catch {
            radarOn = false; radarPlaying = false
            radarMessage = error.localizedDescription
        }
        radarRevision += 1
    }
    func selectRadarFrame(_ index: Int) {
        guard radarFrames.indices.contains(index), index != radarIndex else { return }
        radarIndex = index; radarRevision += 1
    }

    enum MapType: String, Sendable { case standard, satellite, hybrid, terrain, imagery, usgs_topo, transit, flyover }
    enum RouteMode: String, Sendable { case automobile, walking, cycling, transit }

    struct MapStateArtifact: Sendable {
        let centerLatitude: Double
        let centerLongitude: Double
        let span: Double
        let mapType: MapType
        let layers: [String]  // active base layers
        let pinsCount: Int
        let hasRoute: Bool
        let timestamp: Date
    }

    struct MapBookmark: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let latitude: Double
        let longitude: Double
        let span: Double
        let created: Date = Date()
    }

    func navigate(latitude: Double, longitude: Double, span: Double) throws {
        guard latitude.isFinite, longitude.isFinite, span.isFinite, (-85...85).contains(latitude), (-180...180).contains(longitude), (0.001...90).contains(span) else { throw MapsError.invalid("Latitude must be -85...85, longitude -180...180, and span 0.001...90 degrees.") }
        self.latitude = latitude; self.longitude = longitude; latitudeSpan = span; longitudeSpan = span; revision += 1
        // Update mapType based on new viewport if needed
    }

    func setLayer(_ value: String) throws {
        guard ["standard", "satellite", "hybrid", "terrain", "imagery", "usgs_topo", "transit", "flyover"].contains(value) else { throw MapsError.invalid("Layer must be standard, satellite, hybrid, terrain, imagery, usgs_topo, transit, or flyover.") }
        layer = value == "imagery" ? "satellite" : value
        mapType = MapType(rawValue: value) ?? .standard
    }

    func addPin(name: String, latitude: Double, longitude: Double) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
              latitude.isFinite, longitude.isFinite, (-85...85).contains(latitude), (-180...180).contains(longitude) else { throw MapsError.invalid("Provide a name and valid coordinates.") }
        pins.append(MapPlace(name: name, latitude: latitude, longitude: longitude)); routeRevision += 1
    }

    /// Routes from the map centre to a destination. With `alternatives` MapKit may return several; the first is shown on the map.
    func directions(latitude: Double, longitude: Double, routeMode: RouteMode = .automobile, alternatives: Bool = false) async throws -> String {
        guard latitude.isFinite, longitude.isFinite, (-85...85).contains(latitude), (-180...180).contains(longitude) else { throw MapsError.invalid("Invalid destination coordinates.") }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: self.latitude, longitude: self.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        switch routeMode {
        case .automobile: request.transportType = .automobile
        case .walking: request.transportType = .walking
        case .cycling: request.transportType = .cycling
        case .transit: request.transportType = .transit
        }
        request.requestsAlternateRoutes = alternatives
        let result = try await MKDirections(request: request).calculate()
        guard let first = result.routes.first else { throw MapsError.invalid("No \(routeMode.rawValue) route was found.") }
        routes = result.routes; selectRoute(0)
        _ = first
        return RouteSummary.describe(result.routes.map(Self.summary), mode: routeMode == .automobile ? "driving" : routeMode.rawValue)
    }

    func transitDirections(latitude: Double, longitude: Double, routeMode: RouteMode) async throws -> String {
        try await directions(latitude: latitude, longitude: longitude, routeMode: routeMode)
    }

    static func summary(_ route: MKRoute) -> RouteSummary {
        RouteSummary(name: route.name, meters: route.distance, seconds: route.expectedTravelTime, steps: route.steps.map(\.instructions))
    }

    /// Shows one of the calculated alternatives on the map.
    func selectRoute(_ index: Int) {
        guard routes.indices.contains(index) else { return }
        selectedRouteIndex = index; route = routes[index]; routeRevision += 1
    }

    /// Everything on the map as GPX: pins as waypoints, the shown route (or an imported track) as a track.
    func exportGPX() -> String {
        var line: [GPXPoint] = []
        if let route {
            let polyline = route.polyline
            var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
            polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
            line = coordinates.map { GPXPoint(name: nil, latitude: $0.latitude, longitude: $0.longitude) }
        } else {
            line = track.map { GPXPoint(name: nil, latitude: $0.latitude, longitude: $0.longitude) }
        }
        return GPX.encode(waypoints: pins.map { GPXPoint(name: $0.name, latitude: $0.latitude, longitude: $0.longitude) }, track: line)
    }

    /// Adds a GPX file's waypoints as pins and its first route or track as the line on the map. Returns a summary.
    func importGPX(_ data: Data) throws -> String {
        let document = try GPX.parse(data)
        guard !document.isEmpty else { throw MapsError.invalid("The GPX file has no waypoints, routes or tracks.") }
        for point in document.waypoints.prefix(500) { try addPin(name: point.name ?? "Waypoint", latitude: point.latitude, longitude: point.longitude) }
        let line = document.tracks.first ?? document.routes.first ?? []
        track = line.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        route = nil; routeRevision += 1
        if let focus = document.waypoints.first ?? line.first { try navigate(latitude: max(-85, min(85, focus.latitude)), longitude: focus.longitude, span: 0.15) }
        return "Imported \(min(document.waypoints.count, 500)) waypoints and \(line.count) track points (\(document.routes.count) routes, \(document.tracks.count) tracks in the file; the first one is drawn)."
    }

    func places(_ query: String) async throws -> [MapPlace] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 200 else { throw MapsError.invalid("Enter a search of 1–200 characters.") }
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
        let result = try await MKLocalSearch(request: request).start()
        return result.mapItems.prefix(10).map { MapPlace(name: $0.name ?? "Place", latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude) }
    }

    func searchHistorical() async throws -> [HistoricalMap] {
        let west = max(-180, longitude - longitudeSpan / 2), east = min(180, longitude + longitudeSpan / 2)
        let south = max(-90, latitude - latitudeSpan / 2), north = min(90, latitude + latitudeSpan / 2)
        var components = URLComponents(string: "https://tnmaccess.nationalmap.gov/api/v1/products")!
        components.queryItems = [URLQueryItem(name: "datasets", value: "Historical Topographic Maps"), URLQueryItem(name: "bbox", value: "\(west),\(south),\(east),\(north)"), URLQueryItem(name: "max", value: "50"), URLQueryItem(name: "outputFormat", value: "JSON")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MapsError.invalid("USGS historical map search failed.") }
        struct Page: Decodable { let items: [HistoricalMap] }
        let maps = try JSONDecoder().decode(Page.self, from: data).items
        historical = maps; return maps
    }

    func categorySearch(_ query: String, filters: String? = nil) async throws -> [MapPlace] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 200 else { throw MapsError.invalid("Enter a search of 1–200 characters.") }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        // Add category filters if provided
        // Note: MapKit MKLocalSearch.Request does not have an 'alias' property;
        // category filtering is handled differently or omitted for simplicity
        let result = try await MKLocalSearch(request: request).start()
        return result.mapItems.prefix(10).map { MapPlace(name: $0.name ?? "Place", latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude) }
    }

    func saveMapState() -> MapStateArtifact {
        let artifact = MapStateArtifact(
            centerLatitude: latitude,
            centerLongitude: longitude,
            span: max(latitudeSpan, longitudeSpan),
            mapType: mapType,
            layers: [layer],  // simplified - could track multiple active layers
            pinsCount: pins.count,
            hasRoute: route != nil,
            timestamp: Date()
        )
        mapState = artifact
        return artifact
    }

    func addBookmark(name: String, latitude: Double, longitude: Double, span: Double) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              latitude.isFinite, longitude.isFinite, (-85...85).contains(latitude), (-180...180).contains(longitude), (0.001...90).contains(span) else { throw MapsError.invalid("Provide a valid name and coordinates.") }
        bookmarks.append(MapBookmark(name: name, latitude: latitude, longitude: longitude, span: span))
        routeRevision += 1
    }

    func removeBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        routeRevision += 1
    }
}

enum MapsError: LocalizedError { case invalid(String); var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil } }