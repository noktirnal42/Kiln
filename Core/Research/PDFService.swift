import Foundation
import PDFKit
import AppKit

public struct PDFPageText: Equatable, Sendable { public var page: Int; public var text: String }
public struct PDFHit: Equatable, Sendable { public var page: Int; public var snippet: String }
public struct PDFInfo: Equatable, Sendable {
    public var pages: Int
    public var title: String
    public var author: String
    public var isLocked: Bool
    public var hasText: Bool
}

public enum PDFError: Error, Equatable, LocalizedError {
    case cannotOpen(String), locked, pageOutOfRange(Int, Int), noMatch(String), wouldOverwrite(String), notPDF, emptyQuery
    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let p): "Could not open \(p) as a PDF."
        case .locked: "This PDF is password protected. Kiln does not unlock PDFs."
        case .pageOutOfRange(let p, let n): "Page \(p) does not exist; the PDF has \(n) pages."
        case .noMatch(let q): "No text matches \"\(q)\"."
        case .wouldOverwrite(let p): "\(p) already exists. Choose a new name; Kiln never overwrites a PDF."
        case .notPDF: "The output name must end in .pdf."
        case .emptyQuery: "Give the text to look for."
        }
    }
}

/// Reads, searches and annotates PDFs with PDFKit. Annotating always writes a NEW file; the original is never modified.
public struct PDFService: Sendable {
    public init() {}

    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw PDFError.cannotOpen(url.lastPathComponent) }
        if doc.isLocked { throw PDFError.locked }
        return doc
    }

    public func info(_ url: URL) throws -> PDFInfo {
        let doc = try Self.open(url)
        let attrs = doc.documentAttributes ?? [:]
        let sample = (0..<min(doc.pageCount, 3)).compactMap { doc.page(at: $0)?.string }.joined()
        return PDFInfo(pages: doc.pageCount, title: (attrs[PDFDocumentAttribute.titleAttribute] as? String) ?? "", author: (attrs[PDFDocumentAttribute.authorAttribute] as? String) ?? "",
                       isLocked: false, hasText: !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Text of pages `from...to` (1-based, inclusive), at most `maxCharacters` in total.
    public func text(_ url: URL, from: Int = 1, to: Int? = nil, maxCharacters: Int = 20_000) throws -> [PDFPageText] {
        let doc = try Self.open(url)
        let last = min(to ?? doc.pageCount, doc.pageCount)
        guard from >= 1, from <= doc.pageCount else { throw PDFError.pageOutOfRange(from, doc.pageCount) }
        var out: [PDFPageText] = [], used = 0
        for number in from...max(from, last) {
            guard used < maxCharacters, let page = doc.page(at: number - 1) else { break }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if used + text.count > maxCharacters { text = String(text.prefix(maxCharacters - used)) }
            used += text.count
            out.append(PDFPageText(page: number, text: text))
        }
        return out
    }

    public func search(_ url: URL, query: String, limit: Int = 20) throws -> [PDFHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw PDFError.emptyQuery }
        let doc = try Self.open(url)
        return doc.findString(q, withOptions: [.caseInsensitive]).prefix(max(1, limit)).compactMap { selection in
            guard let page = selection.pages.first else { return nil }
            let context = selection.copy() as? PDFSelection
            context?.extendForLineBoundaries()
            let line = (context?.string ?? selection.string ?? "").replacingOccurrences(of: "\n", with: " ")
            return PDFHit(page: doc.index(for: page) + 1, snippet: String(line.prefix(200)))
        }
    }

    static func checkedOutput(_ output: URL) throws {
        guard output.pathExtension.lowercased() == "pdf" else { throw PDFError.notPDF }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw PDFError.wouldOverwrite(output.lastPathComponent) }
    }

    /// Highlights every match of `query` and saves a copy to `output`. Returns how many highlights were added.
    @discardableResult
    public func highlight(_ url: URL, query: String, to output: URL, color: NSColor = NSColor.systemYellow.withAlphaComponent(0.5)) throws -> Int {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw PDFError.emptyQuery }
        try Self.checkedOutput(output)
        let doc = try Self.open(url)
        let matches = doc.findString(q, withOptions: [.caseInsensitive])
        guard !matches.isEmpty else { throw PDFError.noMatch(q) }
        var count = 0
        for selection in matches {
            for page in selection.pages {
                let bounds = selection.bounds(for: page)
                guard !bounds.isEmpty else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = color
                page.addAnnotation(annotation); count += 1
            }
        }
        guard doc.write(to: output) else { throw PDFError.cannotOpen(output.lastPathComponent) }
        return count
    }

    /// Adds a sticky-note comment at the top-left of a page and saves a copy.
    public func addNote(_ url: URL, page number: Int, text: String, to output: URL) throws {
        try Self.checkedOutput(output)
        let doc = try Self.open(url)
        guard number >= 1, number <= doc.pageCount, let page = doc.page(at: number - 1) else { throw PDFError.pageOutOfRange(number, doc.pageCount) }
        let box = page.bounds(for: .mediaBox)
        let note = PDFAnnotation(bounds: CGRect(x: box.minX + 24, y: box.maxY - 48, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = String(text.prefix(2000)); note.iconType = .comment
        page.addAnnotation(note)
        guard doc.write(to: output) else { throw PDFError.cannotOpen(output.lastPathComponent) }
    }

    /// Highlights and notes already in a PDF (so an agent can read what the person marked).
    public func annotations(_ url: URL) throws -> [(page: Int, kind: String, text: String)] {
        let doc = try Self.open(url)
        var out: [(Int, String, String)] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations {
                let kind = (a.type ?? "").lowercased()
                guard kind == "highlight" || kind == "text" || kind == "note" else { continue }
                let highlighted = kind == "highlight" ? (doc.selection(from: page, at: CGPoint(x: a.bounds.minX + 1, y: a.bounds.midY), to: page, at: CGPoint(x: a.bounds.maxX - 1, y: a.bounds.midY))?.string ?? "") : ""
                out.append((i + 1, kind, a.contents ?? highlighted))
            }
        }
        return out
    }
}
