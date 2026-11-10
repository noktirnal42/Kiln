import Foundation

/// Parses the zoo of date formats found in RSS, Atom, RDF and NNTP headers.
public enum FeedDateParser {
    public static func parse(_ raw: String?) -> Date? {
        guard var string = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }

        // Some feeds wrap dates in extra whitespace or newlines.
        string = string.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)

        if let date = parseISO8601(string) { return date }
        if let date = parseRFC822(string) { return date }

        // Unix timestamps are occasionally used.
        if let seconds = Double(string), seconds > 100_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        // Dates without a time zone: assume UTC.
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = TimeZone(secondsFromGMT: 0)
        naive.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = naive.date(from: string) { return date }

        naive.dateFormat = "yyyy-MM-dd"
        return naive.date(from: string)
    }

    private static func parseRFC822(_ string: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd HH:mm:ss Z"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    /// Human-friendly relative date used across the UI.
    public static func relativeString(from date: Date, relativeTo now: Date = .now) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3_600 { return "\(Int(interval / 60))m" }
        if interval < 86_400 { return "\(Int(interval / 3_600))h" }
        if interval < 604_800 { return "\(Int(interval / 86_400))d" }
        if interval < 2_419_200 { return "\(Int(interval / 604_800))w" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
