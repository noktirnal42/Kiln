import Foundation

/// The person's reading list: sources with notes and tags, saved as one JSON file. Nothing is uploaded.
public actor ResearchLibrary {
    private let file: URL
    private var sources: [Source] = []
    private var loaded = false

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Kiln/Research", isDirectory: true)
    }

    public init(directory: URL = ResearchLibrary.defaultDirectory()) {
        self.file = directory.appendingPathComponent("library.json")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file) else { return }
        // Dates are saved as ISO 8601, so they must be read back the same way (the default decoder rejects them and the library would load empty).
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([Source].self, from: data) else { return }
        sources = decoded
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sources).write(to: file, options: .atomic)
    }

    static func titleKey(_ s: Source) -> String {
        s.title.lowercased().filter { $0.isLetter || $0.isNumber } + ":" + (s.year.map(String.init) ?? "")
    }

    /// The same source: the same DOI (case does not matter), or the same title and year even when only one copy has a DOI.
    static func same(_ a: Source, _ b: Source) -> Bool {
        if !a.doi.isEmpty, !b.doi.isEmpty, a.doi.lowercased() == b.doi.lowercased() { return true }
        return titleKey(a) == titleKey(b)
    }

    public enum AddResult: Equatable, Sendable { case added(Source), duplicate(Source) }

    /// Adds a source unless the same DOI (or the same title and year) is already there.
    @discardableResult
    public func add(_ source: Source) throws -> AddResult {
        load()
        var s = source
        s.title = s.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.title.isEmpty else { throw LibraryError.emptyTitle }
        if let existing = sources.first(where: { Self.same($0, s) }) { return .duplicate(existing) }
        sources.append(s)
        try save()
        return .added(s)
    }

    public func all() -> [Source] { load(); return sources.sorted { $0.added > $1.added } }

    public func source(id: UUID) -> Source? { load(); return sources.first { $0.id == id } }

    /// Sources whose title, authors, venue, tags or notes contain every word of `query`, optionally with a tag.
    public func search(_ query: String = "", tag: String? = nil) -> [Source] {
        load()
        let words = query.lowercased().split(separator: " ").map(String.init)
        return sources.filter { s in
            if let tag, !tag.isEmpty, !s.tags.contains(where: { $0.lowercased() == tag.lowercased() }) { return false }
            let haystack = ([s.title, s.venue, s.notes, s.doi] + s.authors + s.tags).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }.sorted { $0.added > $1.added }
    }

    public func appendNote(_ id: UUID, _ text: String) throws {
        load()
        guard let i = sources.firstIndex(where: { $0.id == id }) else { throw LibraryError.notFound }
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        sources[i].notes = sources[i].notes.isEmpty ? note : sources[i].notes + "\n" + note
        try save()
    }

    public func setTags(_ id: UUID, _ tags: [String]) throws {
        load()
        guard let i = sources.firstIndex(where: { $0.id == id }) else { throw LibraryError.notFound }
        sources[i].tags = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })).sorted()
        try save()
    }

    public func remove(_ id: UUID) throws {
        load()
        guard sources.contains(where: { $0.id == id }) else { throw LibraryError.notFound }
        sources.removeAll { $0.id == id }
        try save()
    }
}

public enum LibraryError: Error, Equatable, LocalizedError {
    case emptyTitle, notFound
    public var errorDescription: String? {
        switch self { case .emptyTitle: "A source needs a title."; case .notFound: "That source is not in the library." }
    }
}
