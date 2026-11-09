import Foundation

/// URL handling for the Browser, kept pure so it can be tested without a web view.
enum BrowserURL {
    /// Schemes a page or an agent may navigate to. `file:`, `javascript:` and `data:` are refused: a
    /// `file:` URL would read local files into the page, and the others run script the user never saw.
    static let navigableSchemes: Set<String> = ["http", "https"]

    static let searchTemplate = "https://duckduckgo.com/?q="

    /// What the address bar means by `input`: a URL as typed, a bare host promoted to https
    /// (http for localhost and IP addresses, which rarely have certificates), or a web search.
    static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.lowercased() == "about:blank" { return URL(string: "about:blank") }
        if let scheme = explicitScheme(of: text) {
            guard navigableSchemes.contains(scheme),
                  let url = URL(string: text), url.host?.isEmpty == false else { return nil }
            return url
        }
        if looksLikeHost(text) {
            let scheme = isLocalHost(text) ? "http" : "https"
            if let url = URL(string: "\(scheme)://\(text)"), url.host?.isEmpty == false { return url }
        }
        return searchURL(for: text)
    }

    /// Strict variant for the agent: a real http(s) URL or nothing. The agent never gets a silent search.
    static func resolveStrict(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = explicitScheme(of: text), navigableSchemes.contains(scheme),
              let url = URL(string: text), url.host?.isEmpty == false else { return nil }
        return url
    }

    static func searchURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: searchTemplate + encoded)
    }

    /// The scheme the user typed, if they typed one: `https://x`, `mailto:a@b`, `javascript:…`.
    /// `localhost:3000` is a host and a port, not a scheme.
    static func explicitScheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = String(text[..<colon])
        guard let first = candidate.first, first.isLetter,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        let rest = text[text.index(after: colon)...]
        if rest.hasPrefix("//") { return candidate.lowercased() }
        // `host:port` — digits straight after the colon (and nothing like a scheme name).
        if let firstRest = rest.first, firstRest.isNumber, rest.prefix(while: \.isNumber).count <= 5,
           rest.drop(while: \.isNumber).first.map({ $0 == "/" || $0 == "?" }) ?? true { return nil }
        return candidate.lowercased()
    }

    static func looksLikeHost(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        let hostPart = text.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? text
        let name = hostPart.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostPart
        if name.lowercased() == "localhost" { return true }
        return name.contains(".") && !name.hasPrefix(".") && !name.hasSuffix(".")
    }

    static func isLocalHost(_ text: String) -> Bool {
        let hostPart = text.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? text
        let name = (hostPart.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostPart).lowercased()
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") { return true }
        let parts = name.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    // MARK: Downloads

    /// Files the package intake can do something with: app packages and native binaries.
    static let packageExtensions: Set<String> = [
        "apk", "apks", "xapk", "aab", "ipa", "dmg", "pkg", "deb", "exe", "msi", "dll", "so", "dylib", "appimage", "bin", "elf",
    ]

    static func isPackageName(_ fileName: String) -> Bool {
        packageExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// A name that stays inside the downloads folder and does not overwrite an earlier download.
    static func uniqueDownloadName(suggested: String, existing: (String) -> Bool) -> String {
        let base = KilnPackageCatalog.fileName(for: URL(fileURLWithPath: "/" + suggested))
        guard existing(base) else { return base }
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        for n in 2...999 {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            if !existing(candidate) { return candidate }
        }
        return "\(stem)-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
    }
}
