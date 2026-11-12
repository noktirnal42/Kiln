import Foundation

/// A source in the research library. Authors are "Family, Given" strings.
public struct Source: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var authors: [String]
    public var year: Int?
    public var venue: String          // journal, conference or site
    public var doi: String
    public var url: String
    public var filePath: String       // a PDF on this Mac, if any
    public var tags: [String]
    public var notes: String
    public var added: Date

    public init(id: UUID = UUID(), title: String, authors: [String] = [], year: Int? = nil, venue: String = "", doi: String = "", url: String = "",
                filePath: String = "", tags: [String] = [], notes: String = "", added: Date = Date()) {
        self.id = id; self.title = title; self.authors = authors; self.year = year; self.venue = venue; self.doi = doi
        self.url = url; self.filePath = filePath; self.tags = tags; self.notes = notes; self.added = added
    }
}

public enum CitationStyle: String, CaseIterable, Sendable { case apa, mla, bibtex }

/// Formats sources as citations. Pure functions: nothing here touches the network or disk.
public enum Citations {
    /// "Lovelace, Ada" -> ("Lovelace", "Ada"); a single name is treated as the family name (organisations).
    static func split(_ name: String) -> (family: String, given: String) {
        let parts = name.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return (parts.first ?? name, parts.count > 1 ? parts[1] : "")
    }

    static func initials(_ given: String) -> String {
        given.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." }).compactMap { $0.first.map { "\($0.uppercased())." } }.joined(separator: " ")
    }

    static func apaAuthors(_ authors: [String]) -> String {
        let formatted = authors.map { a -> String in let (f, g) = split(a); return g.isEmpty ? f : "\(f), \(initials(g))" }
        switch formatted.count {
        case 0: return ""
        case 1: return formatted[0]
        case 2: return "\(formatted[0]), & \(formatted[1])"
        case 3...20: return formatted.dropLast().joined(separator: ", ") + ", & " + formatted.last!
        default: return formatted.prefix(19).joined(separator: ", ") + ", . . . " + formatted.last!
        }
    }

    static func mlaAuthors(_ authors: [String]) -> String {
        guard let first = authors.first else { return "" }
        let (f, g) = split(first)
        let lead = g.isEmpty ? f : "\(f), \(g)"
        switch authors.count {
        case 1: return lead
        case 2: let (f2, g2) = split(authors[1]); return "\(lead), and \(g2.isEmpty ? f2 : "\(g2) \(f2)")"
        default: return "\(lead), et al"
        }
    }

    static func link(_ s: Source) -> String {
        if !s.doi.isEmpty { return "https://doi.org/\(s.doi)" }
        return s.url
    }

    static func end(_ text: String) -> String { text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!") ? text : text + "." }

    public static func format(_ s: Source, style: CitationStyle) -> String {
        switch style {
        case .apa:
            var parts: [String] = []
            let a = apaAuthors(s.authors)
            parts.append(a.isEmpty ? end(s.title) : end(a))
            parts.append("(\(s.year.map(String.init) ?? "n.d.")).")
            if !a.isEmpty { parts.append(end(s.title)) }
            if !s.venue.isEmpty { parts.append(end(s.venue)) }
            let l = link(s); if !l.isEmpty { parts.append(l) }
            return parts.joined(separator: " ")
        case .mla:
            var parts: [String] = []
            let a = mlaAuthors(s.authors); if !a.isEmpty { parts.append(end(a)) }
            parts.append("\"\(end(s.title))\"")
            if !s.venue.isEmpty { parts.append(s.venue + (s.year != nil ? "," : ".")) }
            if let y = s.year { parts.append("\(y).") }
            let l = link(s); if !l.isEmpty { parts.append(l.replacingOccurrences(of: "https://", with: "") + ".") }
            return parts.joined(separator: " ")
        case .bibtex:
            func esc(_ v: String) -> String { v.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}").replacingOccurrences(of: "\n", with: " ") }
            var fields: [String] = ["  title = {\(esc(s.title))}"]
            if !s.authors.isEmpty { fields.append("  author = {\(s.authors.map(esc).joined(separator: " and "))}") }
            if let y = s.year { fields.append("  year = {\(y)}") }
            if !s.venue.isEmpty { fields.append("  journal = {\(esc(s.venue))}") }
            if !s.doi.isEmpty { fields.append("  doi = {\(esc(s.doi))}") }
            if !s.url.isEmpty && s.doi.isEmpty { fields.append("  url = {\(esc(s.url))}") }
            return "@article{\(bibKey(s)),\n" + fields.joined(separator: ",\n") + "\n}"
        }
    }

    /// "lovelace2026analytical": first author's family name, year, first significant title word. ASCII letters and digits only.
    public static func bibKey(_ s: Source) -> String {
        func clean(_ t: String) -> String { String(t.folding(options: .diacriticInsensitive, locale: .current).lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }) }
        let family = s.authors.first.map { clean(split($0).family) } ?? ""
        let stop: Set<String> = ["a", "an", "the", "of", "on", "in", "and", "for", "to"]
        let word = s.title.split(separator: " ").map { clean(String($0)) }.first { !$0.isEmpty && !stop.contains($0) } ?? ""
        let key = family + (s.year.map(String.init) ?? "") + word
        return key.isEmpty ? "source" : key
    }
}

/// Reads the metadata Crossref returns for a DOI (api.crossref.org/works/<doi>).
public enum Crossref {
    /// A DOI as it appears in text or a URL, or nil if it is not one. Only characters DOIs use survive, so it is safe in a URL path.
    public static func normalizeDOI(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "doi:", "DOI:"] where s.lowercased().hasPrefix(prefix.lowercased()) { s = String(s.dropFirst(prefix.count)) }
        guard s.range(of: #"^10\.\d{4,9}/[-._;()/:A-Za-z0-9]+$"#, options: .regularExpression) != nil, !s.contains("..") else { return nil }
        return s
    }

    public static func url(for doi: String) -> URL? {
        guard let clean = normalizeDOI(doi), let encoded = clean.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")) else { return nil }
        return URL(string: "https://api.crossref.org/works/" + encoded)
    }

    public static func parse(_ data: Data) -> Source? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let m = root["message"] as? [String: Any],
              let title = (m["title"] as? [String])?.first, !title.isEmpty else { return nil }
        let authors = (m["author"] as? [[String: Any]] ?? []).compactMap { a -> String? in
            let family = a["family"] as? String ?? a["name"] as? String ?? "", given = a["given"] as? String ?? ""
            return family.isEmpty ? nil : (given.isEmpty ? family : "\(family), \(given)")
        }
        let year = ((m["issued"] as? [String: Any])?["date-parts"] as? [[Any]])?.first?.first as? Int
        let strip: (String) -> String = { $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
        return Source(title: strip(title), authors: authors, year: year, venue: strip((m["container-title"] as? [String])?.first ?? ""),
                      doi: (m["DOI"] as? String).flatMap(normalizeDOI) ?? "", url: (m["URL"] as? String) ?? "")
    }
}
