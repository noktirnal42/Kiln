import Foundation
import Testing
@testable import Kiln

struct QuickAskTests {
    @Test func anAskLinkFillsTheMessageBoxAndNeverSendsAtOnce() throws {
        let request = try #require(QuickAskLink.parse(URL(string: "kiln://ask?text=What%20changed%20today%3F")!))
        #expect(request.text == "What changed today?" && request.source == .link)
        #expect(!request.maySendAtOnce, "a link can come from any web page: the person decides to send")
        #expect(QuickAskRequest(text: "x", source: .menuBar).maySendAtOnce)
        #expect(!QuickAskRequest(text: "x", source: .share).maySendAtOnce)
    }

    @Test func onlyAskAndShareOnKilnAreAccepted() {
        for bad in ["https://example.com/?text=x", "kiln://open?text=x", "kiln://ask", "kiln://ask?text=%20%0A%20", "kiln://ask?other=x", "file:///etc/passwd", "kiln:ask?text=x"] {
            #expect(QuickAskLink.parse(URL(string: bad)!) == nil, "\(bad)")
        }
        #expect(QuickAskLink.parse(URL(string: "KILN://ASK?text=hi")!)?.text == "hi", "scheme and host are not case sensitive")
    }

    @Test func aSharedPageBecomesTitleAddressAndText() throws {
        let url = URL(string: "kiln://share?title=Release%20notes&url=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1&text=Summarize%20this")!
        let request = try #require(QuickAskLink.parse(url))
        #expect(request.text == "Release notes\nhttps://example.com/a?b=1\n\nSummarize this" && request.source == .share)
        #expect(QuickAskLink.parse(URL(string: "kiln://share?url=https%3A%2F%2Fexample.com")!)?.text == "https://example.com")
        #expect(QuickAskLink.parse(URL(string: "kiln://share?text=just%20words")!)?.text == "just words")
    }

    @Test func aSharedAddressThatIsNotWebIsDropped() {
        #expect(QuickAskLink.combine(title: "", url: "file:///Users/me/secret.txt", text: "").isEmpty)
        #expect(QuickAskLink.combine(title: "T", url: "javascript:alert(1)", text: "") == "T")
        #expect(QuickAskLink.combine(title: "", url: "ftp://host/x", text: "t") == "t")
    }

    @Test func controlCharactersAreRemovedAndLongTextIsClipped() {
        #expect(QuickAskLink.sanitize("a\u{0}b\u{7}c\r\nd\re\tf\u{202E}g") == "abc\nd\ne\tfg", "control and format characters go, line endings are normalised, tabs stay")
        #expect(QuickAskLink.sanitize("  hi \n ") == "hi")
        let long = String(repeating: "x", count: QuickAskLink.maxCharacters + 500)
        #expect(QuickAskLink.sanitize(long).count == QuickAskLink.maxCharacters)
    }

    @Test func mergingNeverReplacesWhatThePersonIsTyping() {
        #expect(QuickAskLink.merge(existing: "", adding: "new") == "new")
        #expect(QuickAskLink.merge(existing: "  \n", adding: "new") == "new")
        #expect(QuickAskLink.merge(existing: "my draft", adding: "new") == "my draft\n\nnew")
        #expect(QuickAskLink.merge(existing: "my draft\n\n", adding: "new") == "my draft\n\nnew")
    }

    @Test func linksBuiltByKilnParseBackToTheSameText() throws {
        let text = "Why is 2 + 2 = 4? & what about \"quotes\" and é, 日本語?\nSecond line"
        let link = try #require(QuickAskLink.askLink(text))
        #expect(link.scheme == "kiln" && link.host == "ask")
        #expect(QuickAskLink.parse(link)?.text == text)
        let share = try #require(QuickAskLink.shareLink(title: "T", url: "https://example.com/x?y=1&z=2", text: "body"))
        #expect(QuickAskLink.parse(share)?.text == "T\nhttps://example.com/x?y=1&z=2\n\nbody")
    }
}
