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
    var layer = "standard"
    var historical: [HistoricalMap] = []
    var placeResults: [MapPlace] = []
    var pins: [MapPlace] = []
    var route: MKRoute?
    var routeRevision = 0
    var message: String?
    var query = ""
    var busy = false
    var revision = 0
    func navigate(latitude: Double, longitude: Double, span: Double) throws {
        guard latitude.isFinite, longitude.isFinite, span.isFinite, (-85...85).contains(latitude), (-180...180).contains(longitude), (0.001...90).contains(span) else { throw MapsError.invalid("Latitude must be -85…85, longitude -180…180, and span 0.001…90 degrees.") }
        self.latitude = latitude; self.longitude = longitude; latitudeSpan = span; longitudeSpan = span; revision += 1
    }
    func setLayer(_ value: String) throws {
        guard ["standard", "imagery", "usgs_topo"].contains(value) else { throw MapsError.invalid("Layer must be standard, imagery, or usgs_topo.") }
        layer = value
    }
    func addPin(name: String, latitude: Double, longitude: Double) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
              latitude.isFinite, longitude.isFinite, (-85...85).contains(latitude), (-180...180).contains(longitude) else { throw MapsError.invalid("Provide a name and valid coordinates.") }
        pins.append(MapPlace(name: name, latitude: latitude, longitude: longitude)); routeRevision += 1
    }
    func directions(latitude: Double, longitude: Double) async throws -> String {
        guard latitude.isFinite, longitude.isFinite, (-85...85).contains(latitude), (-180...180).contains(longitude) else { throw MapsError.invalid("Invalid destination coordinates.") }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: self.latitude, longitude: self.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        request.transportType = .automobile
        let result = try await MKDirections(request: request).calculate()
        guard let route = result.routes.first else { throw MapsError.invalid("No driving route was found.") }
        self.route = route; routeRevision += 1
        return "Driving: \(Int(route.distance)) m, about \(Int(route.expectedTravelTime / 60)) min. " + route.steps.map(\.instructions).filter { !$0.isEmpty }.joined(separator: " → ")
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
}

enum MapsError: LocalizedError { case invalid(String); var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil } }
