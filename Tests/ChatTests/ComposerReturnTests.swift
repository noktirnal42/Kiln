import SwiftUI
import Testing
@testable import Kiln

@Suite("Composer Return key")
struct ComposerReturnTests {
    private func decide(_ mods: EventModifiers = [], text: String = "hello", streaming: Bool = false, marked: Bool = false) -> ComposerReturn {
        ComposerReturn.decide(modifiers: mods, text: text, isStreaming: streaming, hasMarkedText: marked)
    }

    @Test("plain Return sends a real message") func sends() { #expect(decide() == .send) }
    @Test("Shift, Option and Control Return add a line break") func newline() {
        for mods: EventModifiers in [.shift, .option, .control, [.shift, .option]] { #expect(decide(mods) == .newline) }
    }
    @Test("Command Return sends like Return: it never leaves a stray line break") func commandSends() {
        #expect(decide(.command) == .send)
        #expect(decide(.command, text: "") == .ignore)
    }
    @Test("an empty or whitespace-only box does not send and does not insert a line break") func empty() {
        #expect(decide(text: "") == .ignore)
        #expect(decide(text: "  \n \t") == .ignore)
    }
    @Test("Return while the model is streaming still sends: the session queues the message") func streaming() { #expect(decide(streaming: true) == .send) }
    @Test("an empty box does not send while streaming either") func emptyWhileStreaming() { #expect(decide(text: " ", streaming: true) == .ignore) }
    @Test("line-break shortcuts still work while streaming and when the box is empty") func newlineAlways() {
        #expect(decide(.shift, text: "", streaming: true) == .newline)
    }
    @Test("Return during input-method composition is left to the input method, even with a modifier") func ime() {
        #expect(decide(marked: true) == .passThrough)
        #expect(decide(.shift, marked: true) == .passThrough)
    }
    @Test("multiline text with trailing newline still sends") func multiline() { #expect(decide(text: "a\nb\n") == .send) }
}
