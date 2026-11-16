import Foundation

struct GPXPoint: Equatable, Sendable {
    var name: String?
    var latitude: Double
    var longitude: Double
}

struct GPXDocument: Equatable, Sendable {
    var waypoints: [GPXPoint] = []
    var routes: [[GPXPoint]] = []
    var tracks: [[GPXPoint]] = []
    var isEmpty: Bool { waypoints.isEmpty && routes.isEmpty && tracks.isEmpty }
}

enum GPXError: LocalizedError {
    case malformed(String)
    case tooLarge
    var errorDescription: String? {
        switch self {
        case .malformed(let why): "Not a readable GPX file: \(why)"
        case .tooLarge: "The GPX file is larger than 10 MB."
        }
    }
}

/// GPX 1.1 reading and writing (waypoints, routes, tracks). Kiln's own GPX; KML is not supported.
enum GPX {
    static let maxBytes = 10_000_000

    static func encode(waypoints: [GPXPoint], track: [GPXPoint] = [], trackName: String = "Route") -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var out = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        out += #"<gpx version="1.1" creator="Kiln" xmlns="http://www.topografix.com/GPX/1/1">"# + "\n"
        for point in waypoints {
            out += #"  <wpt lat="\#(point.latitude)" lon="\#(point.longitude)">"#
            if let name = point.name { out += "<name>\(esc(name))</name>" }
            out += "</wpt>\n"
        }
        if !track.isEmpty {
            out += "  <trk><name>\(esc(trackName))</name><trkseg>\n"
            for point in track { out += #"    <trkpt lat="\#(point.latitude)" lon="\#(point.longitude)"/>"# + "\n" }
            out += "  </trkseg></trk>\n"
        }
        return out + "</gpx>\n"
    }

    static func parse(_ data: Data) throws -> GPXDocument {
        guard data.count <= maxBytes else { throw GPXError.tooLarge }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), reader.sawRoot else {
            throw GPXError.malformed(reader.problem ?? parser.parserError?.localizedDescription ?? "no <gpx> element")
        }
        if let problem = reader.problem { throw GPXError.malformed(problem) }
        return reader.document
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var document = GPXDocument()
        var sawRoot = false
        var problem: String?
        private var path: [String] = []
        private var current: GPXPoint?
        private var line: [GPXPoint] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            path.append(name)
            text = ""
            switch name {
            case "gpx": sawRoot = true
            case "wpt", "rtept", "trkpt":
                guard let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init),
                      (-90...90).contains(lat), (-180...180).contains(lon) else {
                    problem = "a point has a missing or out-of-range lat/lon"; parser.abortParsing(); return
                }
                current = GPXPoint(name: nil, latitude: lat, longitude: lon)
            case "rte", "trkseg": line = []
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast() }
            let parent = path.count >= 2 ? path[path.count - 2] : ""
            switch name {
            case "name" where parent == "wpt" || parent == "rtept" || parent == "trkpt":
                current?.name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "wpt": if let p = current { document.waypoints.append(p) }; current = nil
            case "rtept", "trkpt": if let p = current { line.append(p) }; current = nil
            case "rte": if !line.isEmpty { document.routes.append(line) }; line = []
            case "trkseg": if !line.isEmpty { document.tracks.append(line) }; line = []
            default: break
            }
        }
    }
}

/// One route as the Directions panel and the agent describe it.
struct RouteSummary: Equatable, Sendable {
    var name: String
    var meters: Double
    var seconds: Double
    var steps: [String]

    var distanceText: String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters)) m"
    }
    var durationText: String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
    func arrival(from start: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeStyle = .short; formatter.dateStyle = .none
        return formatter.string(from: start.addingTimeInterval(seconds))
    }

    /// "Route 1 · via I-10: 23.4 km, 24 min, arrive 3:12 PM" then the steps.
    static func describe(_ routes: [RouteSummary], mode: String, start: Date = Date()) -> String {
        routes.enumerated().map { index, route in
            let label = routes.count > 1 ? "Route \(index + 1)\(route.name.isEmpty ? "" : " via \(route.name)")" : mode.capitalized
            let head = "\(label): \(route.distanceText), \(route.durationText), arrive \(route.arrival(from: start))."
            let steps = route.steps.filter { !$0.isEmpty }
            return steps.isEmpty ? head : head + " " + steps.joined(separator: " → ")
        }.joined(separator: "\n\n")
    }
}
