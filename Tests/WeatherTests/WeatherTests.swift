import Foundation
import Testing
@testable import Kiln

/// Answers weather.gov calls in process; one host name per test.
final class WeatherStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (URL, [String: String]) -> (Int, [String: Any])
    nonisolated(unsafe) static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) static var urls: [String: [URL]] = [:]
    nonisolated(unsafe) static var agents: [String: String] = [:]
    static let lock = NSLock()
    static func install(host: String, _ handler: @escaping Handler) { lock.lock(); handlers[host] = handler; urls[host] = []; lock.unlock() }
    static func seen(_ host: String) -> [URL] { lock.lock(); defer { lock.unlock() }; return urls[host] ?? [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!, host = url.host ?? ""
        Self.lock.lock(); Self.urls[host, default: []].append(url); Self.agents[host] = request.value(forHTTPHeaderField: "User-Agent"); let handler = Self.handlers[host]; Self.lock.unlock()
        let (status, body) = handler?(url, request.allHTTPHeaderFields ?? [:]) ?? (404, [:])
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/geo+json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}

private func service(host: String, _ handler: @escaping WeatherStub.Handler) -> WeatherService {
    WeatherStub.install(host: host, handler)
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [WeatherStub.self]
    return WeatherService(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration))
}

private func period(_ name: String, _ temp: Int, _ short: String, hourly: Bool = false) -> [String: Any] {
    ["name": hourly ? "" : name, "startTime": "2026-11-12T18:00:00-07:00", "endTime": "2026-11-12T19:00:00-07:00", "temperature": temp, "temperatureUnit": "F", "isDaytime": true,
     "shortForecast": short, "detailedForecast": "Detail", "windSpeed": "10 mph", "windDirection": "NW", "probabilityOfPrecipitation": ["value": 20]]
}

private func happyPath(host: String, issued: String = "2026-11-12T22:00:00Z", alerts: [[String: Any]] = []) -> WeatherService {
    service(host: host) { url, _ in
        let path = url.path
        if path.hasPrefix("/points/") {
            return (200, ["properties": ["forecast": "https://\(host)/gridpoints/PSR/1,1/forecast", "forecastHourly": "https://\(host)/gridpoints/PSR/1,1/forecast/hourly",
                                         "relativeLocation": ["properties": ["city": "Phoenix", "state": "AZ"]]]])
        }
        if path.hasSuffix("/forecast/hourly") { return (200, ["properties": ["generatedAt": issued, "periods": [period("", 75, "Clear", hourly: true), period("", 73, "Clear", hourly: true)]]]) }
        if path.hasSuffix("/forecast") { return (200, ["properties": ["generatedAt": issued, "periods": [period("Tonight", 62, "Mostly Clear"), period("Friday", 88, "Sunny")]]]) }
        if path.hasPrefix("/alerts/active") { return (200, ["features": alerts]) }
        return (404, [:])
    }
}

struct WeatherServiceTests {
    @Test func aReportCombinesDaysHoursAndAlertsAndSaysWhereItCameFrom() async throws {
        let host = "w-\(UUID().uuidString.prefix(8)).weather.test"
        let alert: [String: Any] = ["properties": ["event": "Excessive Heat Warning", "severity": "Severe", "headline": "Heat warning until 8 PM", "areaDesc": "Phoenix Metro", "ends": "2026-11-13T03:00:00Z", "senderName": "NWS Phoenix AZ", "instruction": "Stay hydrated."]]
        let report = try await happyPath(host: host, alerts: [alert]).report(latitude: 33.44839, longitude: -112.07398, hours: 12)
        #expect(report.place == "Phoenix, AZ")
        #expect(report.periods.map(\.name) == ["Tonight", "Friday"] && report.periods[0].temperature == 62 && report.periods[0].precipitationChance == 20)
        #expect(report.hourly.count == 2 && report.hourly[0].name == "Hour")
        #expect(report.alerts.map(\.event) == ["Excessive Heat Warning"] && report.alerts[0].sender == "NWS Phoenix AZ")
        #expect(report.issued == ISO8601DateFormatter().date(from: "2026-11-12T22:00:00Z"))
        let seen = WeatherStub.seen(host).map(\.absoluteString)
        #expect(seen.contains { $0.contains("/points/33.4484,-112.0740") }, "coordinates go rounded to four decimals: \(seen)")
        #expect(seen.contains { $0.contains("/alerts/active") && $0.contains("point=33.4484,-112.0740") })
        #expect(WeatherStub.agents[host]?.hasPrefix("Kiln (https://github.com/noktirnal42/Kiln)") == true, "a descriptive User-Agent with no personal contact details")
    }

    @Test func hoursAreCappedAndAZeroHourReportSkipsThem() async throws {
        let host = "w-\(UUID().uuidString.prefix(8)).weather.test"
        let svc = happyPath(host: host)
        #expect(try await svc.report(latitude: 40, longitude: -100, hours: 1).hourly.count == 1)
        #expect(try await svc.report(latitude: 40, longitude: -100, hours: 0).hourly.isEmpty)
    }

    @Test func aForecastOlderThanFourHoursIsStale() {
        let issued = Date(timeIntervalSince1970: 1_000_000)
        let report = WeatherReport(place: "X", issued: issued, periods: [], hourly: [], alerts: [])
        #expect(!report.isStale(now: issued.addingTimeInterval(3 * 3600)))
        #expect(report.isStale(now: issued.addingTimeInterval(4 * 3600 + 1)))
    }

    @Test func outsideTheUnitedStatesIsSaidPlainlyAndBadCoordinatesNeverLeaveTheMac() async {
        let host = "w-\(UUID().uuidString.prefix(8)).weather.test"
        let svc = service(host: host) { _, _ in (404, ["title": "Data Unavailable For Requested Point"]) }
        await #expect(throws: WeatherError.outsideCoverage) { _ = try await svc.report(latitude: 51.5, longitude: -0.12) }
        await #expect(throws: WeatherError.badCoordinates) { _ = try await svc.report(latitude: 95, longitude: 0) }
        await #expect(throws: WeatherError.badCoordinates) { _ = try await svc.alerts(latitude: .nan, longitude: 0) }
        #expect(WeatherStub.seen(host).count == 1, "only the valid-looking request went out")
        let limited = service(host: "w-\(UUID().uuidString.prefix(8)).weather.test") { _, _ in (429, [:]) }
        await #expect(throws: WeatherError.rateLimited) { _ = try await limited.report(latitude: 40, longitude: -100) }
    }

    @Test func aFailedAlertLookupDoesNotHideTheForecast() async throws {
        let host = "w-\(UUID().uuidString.prefix(8)).weather.test"
        let svc = service(host: host) { url, _ in
            if url.path.hasPrefix("/points/") { return (200, ["properties": ["forecast": "https://\(host)/f", "relativeLocation": ["properties": ["city": "Reno", "state": "NV"]]]]) }
            if url.path == "/f" { return (200, ["properties": ["updateTime": "2026-11-12T22:00:00Z", "periods": [period("Today", 50, "Cloudy")]]]) }
            return (500, [:])
        }
        let report = try await svc.report(latitude: 39.5, longitude: -119.8)
        #expect(report.periods.count == 1 && report.alerts.isEmpty && report.hourly.isEmpty)
    }
}

struct WeatherToolTests {
    private let context = ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())

    @Test func theForecastToolLabelsTheSourceAgeAndAlertsAndResolvesAPlaceName() async throws {
        let host = "w-\(UUID().uuidString.prefix(8)).weather.test"
        let tool = WeatherTool(kind: .forecast, service: happyPath(host: host, issued: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600)), alerts: [["properties": ["event": "Wind Advisory", "senderName": "NWS Phoenix AZ"]]]),
                               resolve: { place in place == "Phoenix" ? ("Phoenix, AZ", 33.4484, -112.0740) : nil })
        let text = try await tool.execute(argumentsJSON: #"{"place":"Phoenix","hours":1}"#, context: context)
        #expect(text.hasPrefix(WeatherTool.note))
        #expect(text.contains("Source: National Weather Service (api.weather.gov), issued 10 minutes ago."))
        #expect(text.contains("ALERTS:") && text.contains("Wind Advisory") && text.contains("issued by NWS Phoenix AZ"))
        #expect(text.contains("Tonight: 62°F, Mostly Clear, 20% chance of precipitation"))
        await #expect(throws: (any Error).self) { _ = try await tool.execute(argumentsJSON: #"{"place":"Nowhereville"}"#, context: context) }
        await #expect(throws: (any Error).self) { _ = try await tool.execute(argumentsJSON: "{}", context: context) }
    }

    @Test func anOldForecastIsMarkedStaleAndAlertsHaveTheirOwnTool() async throws {
        let host = "w-\(UUID().uuidString.prefix(8)).weather.test"
        let old = WeatherTool(kind: .forecast, service: happyPath(host: host, issued: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7 * 3600))))
        #expect(try await old.execute(argumentsJSON: #"{"latitude":33.4,"longitude":-112.1}"#, context: context).contains("STALE"))
        let quiet = WeatherTool(kind: .alerts, service: happyPath(host: "w-\(UUID().uuidString.prefix(8)).weather.test"))
        #expect(try await quiet.execute(argumentsJSON: #"{"latitude":33.4,"longitude":-112.1}"#, context: context).contains("No active alerts"))
    }

    @Test func theToolsAreExecuteTierAndPrefixed() {
        for kind in WeatherTool.Kind.allCases {
            let spec = WeatherTool(kind: kind).spec
            #expect(spec.name.hasPrefix("weather_") && spec.permission == .execute, "reading sends coordinates to weather.gov")
        }
    }
}
