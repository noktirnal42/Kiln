import Foundation

public struct ForecastPeriod: Equatable, Sendable {
    public var name: String
    public var start: Date
    public var end: Date
    public var temperature: Int
    public var unit: String
    public var isDaytime: Bool
    public var shortForecast: String
    public var detailedForecast: String
    public var wind: String
    /// Chance of precipitation in percent, when the service gives one.
    public var precipitationChance: Int?
}

public struct WeatherAlert: Equatable, Sendable {
    public var event: String
    public var severity: String
    public var headline: String
    public var area: String
    public var ends: Date?
    /// The issuing office, for example "NWS Phoenix AZ".
    public var sender: String
    public var instruction: String
}

public struct WeatherReport: Equatable, Sendable {
    public var place: String            // "Phoenix, AZ" from the service's own relative location
    public var issued: Date             // when the forecast was generated, as the service says
    public var periods: [ForecastPeriod]
    public var hourly: [ForecastPeriod]
    public var alerts: [WeatherAlert]
    public static let source = "National Weather Service (api.weather.gov)"
    /// A forecast older than this is called stale.
    public static let staleAfter: TimeInterval = 4 * 3600
    public func isStale(now: Date = Date()) -> Bool { now.timeIntervalSince(issued) > Self.staleAfter }
}

public enum WeatherError: Error, Equatable, LocalizedError {
    case outsideCoverage
    case badCoordinates
    case rateLimited
    case network(String)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .outsideCoverage: "The National Weather Service covers the United States and its territories only; it has no forecast for that place."
        case .badCoordinates: "Latitude must be -85...85 and longitude -180...180."
        case .rateLimited: "The weather service asked Kiln to slow down. Try again in a minute."
        case .network(let m): "Could not reach the weather service: \(m)"
        case .unexpected(let m): "The weather service sent something Kiln could not read: \(m)"
        }
    }
}

/// Forecasts and alerts from the US National Weather Service (https://www.weather.gov/documentation/services-web-api): public, no key. Only the
/// coordinates leave the Mac, rounded to four decimals as the service requires. It covers US places only.
public struct WeatherService: Sendable {
    let baseURL: URL
    let session: URLSession
    static let userAgent = "Kiln (https://github.com/noktirnal42/Kiln)"

    public init(baseURL: URL = URL(string: "https://api.weather.gov")!, session: URLSession = .shared) { self.baseURL = baseURL; self.session = session }

    func get(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw WeatherError.network(error.localizedDescription) }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw WeatherError.outsideCoverage }
            if http.statusCode == 429 { throw WeatherError.rateLimited }
            if !(200..<300).contains(http.statusCode) { throw WeatherError.network("HTTP \(http.statusCode)") }
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw WeatherError.unexpected("not JSON") }
        return object
    }

    static func rounded(_ value: Double) -> String { String(format: "%.4f", (value * 10_000).rounded() / 10_000) }

    static func check(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite, (-85...85).contains(latitude), (-180...180).contains(longitude) else { throw WeatherError.badCoordinates }
    }

    public func report(latitude: Double, longitude: Double, hours: Int = 12) async throws -> WeatherReport {
        try Self.check(latitude: latitude, longitude: longitude)
        let point = "\(Self.rounded(latitude)),\(Self.rounded(longitude))"
        let meta = try await get(baseURL.appendingPathComponent("points/\(point)"))
        guard let props = meta["properties"] as? [String: Any], let forecastURL = (props["forecast"] as? String).flatMap(URL.init(string:)) else { throw WeatherError.unexpected("no forecast link") }
        let location = (props["relativeLocation"] as? [String: Any])?["properties"] as? [String: Any]
        let place = [location?["city"] as? String, location?["state"] as? String].compactMap { $0 }.joined(separator: ", ")
        let daily = try await get(forecastURL)
        var hourly: [ForecastPeriod] = []
        if let hourlyURL = (props["forecastHourly"] as? String).flatMap(URL.init(string:)), let object = try? await get(hourlyURL) { hourly = Self.periods(object) }
        let alertsObject = try? await get(baseURL.appendingPathComponent("alerts/active").appending(queryItems: [URLQueryItem(name: "point", value: point)]))
        let dailyProps = daily["properties"] as? [String: Any]
        let issued = Self.date(dailyProps?["generatedAt"] as? String) ?? Self.date(dailyProps?["updateTime"] as? String) ?? Date()
        return WeatherReport(place: place.isEmpty ? "this point" : place, issued: issued, periods: Self.periods(daily), hourly: Array(hourly.prefix(max(0, hours))),
                             alerts: alertsObject.map(Self.alerts) ?? [])
    }

    public func alerts(latitude: Double, longitude: Double) async throws -> [WeatherAlert] {
        try Self.check(latitude: latitude, longitude: longitude)
        let point = "\(Self.rounded(latitude)),\(Self.rounded(longitude))"
        return Self.alerts(try await get(baseURL.appendingPathComponent("alerts/active").appending(queryItems: [URLQueryItem(name: "point", value: point)])))
    }

    // MARK: Parsing

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let withFraction = ISO8601DateFormatter(); withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ISO8601DateFormatter().date(from: text) ?? withFraction.date(from: text)
    }

    static func periods(_ object: [String: Any]) -> [ForecastPeriod] {
        let list = (object["properties"] as? [String: Any])?["periods"] as? [[String: Any]] ?? []
        return list.compactMap { p in
            guard let name = p["name"] as? String, let start = date(p["startTime"] as? String), let end = date(p["endTime"] as? String), let temperature = p["temperature"] as? Int else { return nil }
            let chance = (p["probabilityOfPrecipitation"] as? [String: Any])?["value"] as? Int
            return ForecastPeriod(name: name.isEmpty ? "Hour" : name, start: start, end: end, temperature: temperature, unit: p["temperatureUnit"] as? String ?? "F",
                                  isDaytime: p["isDaytime"] as? Bool ?? true, shortForecast: p["shortForecast"] as? String ?? "", detailedForecast: p["detailedForecast"] as? String ?? "",
                                  wind: [p["windSpeed"] as? String, p["windDirection"] as? String].compactMap { $0 }.joined(separator: " "), precipitationChance: chance)
        }
    }

    static func alerts(_ object: [String: Any]) -> [WeatherAlert] {
        (object["features"] as? [[String: Any]] ?? []).compactMap { feature in
            guard let p = feature["properties"] as? [String: Any], let event = p["event"] as? String else { return nil }
            return WeatherAlert(event: event, severity: p["severity"] as? String ?? "Unknown", headline: p["headline"] as? String ?? event, area: p["areaDesc"] as? String ?? "",
                                ends: date(p["ends"] as? String) ?? date(p["expires"] as? String), sender: p["senderName"] as? String ?? "National Weather Service",
                                instruction: p["instruction"] as? String ?? "")
        }
    }
}
