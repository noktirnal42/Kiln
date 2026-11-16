import Foundation
import MapKit

/// The NOAA / National Weather Service radar composite: MRMS base reflectivity for the contiguous United States, served as a WMS by
/// https://opengeo.ncep.noaa.gov (public, no key; its capabilities document says fees "none" and access constraints "none"). It covers the
/// contiguous US only, keeps roughly the last two hours as frames about two minutes apart, and has no service-level promise.
public enum RadarWMS {
    public static let layer = "conus_bref_qcd"
    public static let endpoint = URL(string: "https://opengeo.ncep.noaa.gov/geoserver/conus/conus_bref_qcd/ows")!
    public static let source = "NOAA National Weather Service, MRMS radar composite (opengeo.ncep.noaa.gov)"
    public static let userAgent = "Kiln (https://github.com/noktirnal42/Kiln)"
    /// Rough bounds of the contiguous-US composite, used only to say so when the map is somewhere else.
    public static let coverage = (minLat: 20.0, maxLat: 55.0, minLon: -135.0, maxLon: -60.0)
    /// A frame older than this is called stale.
    public static let staleAfter: TimeInterval = 20 * 60

    public static func covers(latitude: Double, longitude: Double) -> Bool {
        (coverage.minLat...coverage.maxLat).contains(latitude) && (coverage.minLon...coverage.maxLon).contains(longitude)
    }

    private static let worldHalf = 20037508.342789244

    /// Web-mercator bounds (minX, minY, maxX, maxY) of an XYZ tile.
    public static func bounds(x: Int, y: Int, z: Int) -> (Double, Double, Double, Double) {
        let size = 2 * worldHalf / Double(1 << z)
        let minX = -worldHalf + Double(x) * size
        let maxY = worldHalf - Double(y) * size
        return (minX, maxY - size, minX + size, maxY)
    }

    public static func tileURL(x: Int, y: Int, z: Int, frame: Date?) -> URL {
        let b = bounds(x: x, y: y, z: z)
        var items = [
            URLQueryItem(name: "service", value: "WMS"), URLQueryItem(name: "version", value: "1.1.1"), URLQueryItem(name: "request", value: "GetMap"),
            URLQueryItem(name: "layers", value: layer), URLQueryItem(name: "styles", value: ""), URLQueryItem(name: "format", value: "image/png"),
            URLQueryItem(name: "transparent", value: "true"), URLQueryItem(name: "srs", value: "EPSG:3857"),
            URLQueryItem(name: "width", value: "256"), URLQueryItem(name: "height", value: "256"),
            URLQueryItem(name: "bbox", value: String(format: "%.4f,%.4f,%.4f,%.4f", b.0, b.1, b.2, b.3)),
        ]
        if let frame { items.append(URLQueryItem(name: "time", value: iso(frame))) }
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = items
        return parts.url!
    }

    public static func capabilitiesURL() -> URL {
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "service", value: "WMS"), URLQueryItem(name: "version", value: "1.3.0"), URLQueryItem(name: "request", value: "GetCapabilities")]
        return parts.url!
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: date)
    }

    /// The discrete timestamps from the capabilities document's `time` dimension, oldest first. Ranges ("a/b/step") are not expanded;
    /// a document that only offers ranges gives no frames, and the layer then says so instead of guessing.
    public static func parseFrames(_ xml: Data) -> [Date] {
        guard let text = String(data: xml, encoding: .utf8),
              let open = text.range(of: #"<Dimension[^>]*name="time"[^>]*>"#, options: .regularExpression),
              let close = text.range(of: "</Dimension>", range: open.upperBound..<text.endIndex) else { return [] }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        let dates = text[open.upperBound..<close.lowerBound].split(separator: ",").compactMap { piece -> Date? in
            let s = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.contains("/") { return nil }
            return fractional.date(from: s) ?? plain.date(from: s)
        }
        return dates.sorted()
    }
}

public struct RadarFrames: Equatable, Sendable {
    public var frames: [Date]
    public var fetched: Date
    public var latest: Date? { frames.last }
    public func isStale(now: Date = Date()) -> Bool { guard let latest else { return true }; return now.timeIntervalSince(latest) > RadarWMS.staleAfter }
    public func ageMinutes(of frame: Date, now: Date = Date()) -> Int { max(0, Int(now.timeIntervalSince(frame) / 60)) }
}

public enum RadarError: Error, Equatable, LocalizedError {
    case network(String)
    case noFrames
    public var errorDescription: String? {
        switch self {
        case .network(let m): "Could not reach the radar service: \(m)"
        case .noFrames: "The radar service listed no frames. Radar is not shown, which does not mean it is dry."
        }
    }
}

public struct RadarService: Sendable {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func frames(now: Date = Date()) async throws -> RadarFrames {
        var request = URLRequest(url: RadarWMS.capabilitiesURL(), timeoutInterval: 20)
        request.setValue(RadarWMS.userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { throw RadarError.network("the service answered with an error") }
            data = body
        } catch let error as RadarError { throw error } catch { throw RadarError.network(error.localizedDescription) }
        let frames = RadarWMS.parseFrames(data)
        guard !frames.isEmpty else { throw RadarError.noFrames }
        return RadarFrames(frames: frames, fetched: now)
    }
}

/// A map overlay that draws one radar frame. A new overlay is made per frame.
final class RadarTileOverlay: MKTileOverlay, @unchecked Sendable {
    let frame: Date?
    init(frame: Date?) {
        self.frame = frame
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = false
        minimumZ = 3; maximumZ = 12
    }
    override func url(forTilePath path: MKTileOverlayPath) -> URL { RadarWMS.tileURL(x: path.x, y: path.y, z: path.z, frame: frame) }
    override func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        var request = URLRequest(url: url(forTilePath: path), timeoutInterval: 20)
        request.setValue(RadarWMS.userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { result(nil, error); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.mimeType == "image/png" else { result(nil, URLError(.badServerResponse)); return }
            result(data, nil)
        }.resume()
    }
}
