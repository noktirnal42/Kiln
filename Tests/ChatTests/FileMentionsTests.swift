import Foundation
import Testing
@testable import Kiln

@Suite("File mentions")
struct FileMentionsTests {
    private let existing: Set<String> = ["/proj/Sources/Pagination.swift", "/proj/README.md", "/proj/Sources"]

    private func extract(_ text: String) -> [FileMention] {
        FileMentions.extract(from: text, root: "/proj", exists: { existing.contains($0) })
    }

    @Test func codeSpansNamingExistingFilesBecomeMentions() {
        let found = extract("I edited `Sources/Pagination.swift:42` and `README.md`, not `Missing.swift`.")
        #expect(found.map(\.path) == ["Sources/Pagination.swift", "README.md"])
        #expect(found.first?.line == 42)
        #expect(found.first?.name == "Pagination.swift")
    }

    @Test func fencedCodeUrlsCommandsAndDirectoriesAreIgnored() {
        let text = "```\n`README.md`\n```\nSee `https://example.com/a.md`, run `swift test`, and `Sources`."
        #expect(extract(text).isEmpty)
    }

    @Test func repeatsCollapseAndTheListIsCapped() {
        #expect(extract("`README.md` then `README.md` again").count == 1)
        let many = FileMentions.extract(from: (1...20).map { "`f\($0).txt`" }.joined(separator: " "), root: "/proj", limit: 3, exists: { _ in true })
        #expect(many.count == 3)
    }

    @Test func noProjectMeansNoChips() {
        #expect(FileMentions.extract(from: "`README.md`", root: nil, exists: { _ in true }).isEmpty)
    }

    @Test func spansNeedAnExtensionAndNoSpaces() {
        #expect(FileMentions.parse("main.swift:10:4") == FileMention(path: "main.swift", line: 10))
        #expect(FileMentions.parse("Makefile") == nil)
        #expect(FileMentions.parse("a b.swift") == nil)
        #expect(FileMentions.parse("file.swift:abc") == nil)
    }
}
