import Testing
@testable import Kiln

@Suite("Spoken text")
struct SpokenTextTests {
    @Test("code blocks are not read out") func codeBlocks() {
        let spoken = SpokenText.clean("Here you go:\n```swift\nlet x = 1\n```\nDone.")
        #expect(!spoken.contains("let x"))
        #expect(spoken.contains("Here you go"))
        #expect(spoken.hasSuffix("The code is on screen."))
    }

    @Test("markdown punctuation and links are tidied") func markdown() {
        let spoken = SpokenText.clean("## Title\n- **bold** item with `code`\n[the docs](https://example.com/x) and https://example.com/y")
        #expect(spoken == "Title\nbold item with code\nthe docs and a link")
    }

    @Test("long replies split on paragraph and sentence boundaries") func chunks() {
        let paragraph = (1...30).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let chunks = SpokenText.chunks(paragraph + "\n\nShort one.", limit: 200)
        #expect(chunks.count > 2)
        #expect(chunks.allSatisfy { $0.count <= 260 })
        #expect(chunks.last == "Short one.")
    }

    @Test("empty replies produce nothing to say") func empty() {
        #expect(SpokenText.chunks(SpokenText.clean("  \n ")).isEmpty)
    }
}
