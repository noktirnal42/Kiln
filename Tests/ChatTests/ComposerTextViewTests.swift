import AppKit
import SwiftUI
import Testing
@testable import Kiln

/// Real key events into the real text view: what the reported "Shift+Return does not work" bug needed and the logic tests could not give.
@MainActor
@Suite("Composer text view keys")
struct ComposerTextViewTests {
    final class Probe { var text = ""; var sent = 0; var tabs = 0; var tabHandles = true }

    private struct Harness {
        let window: NSWindow
        let textView: NSTextView
        let probe: Probe
    }

    private func harness(streaming: Bool = false) throws -> Harness {
        let probe = Probe()
        let view = ComposerTextView(text: Binding(get: { probe.text }, set: { probe.text = $0 }), isStreaming: streaming,
                                    onSend: { probe.sent += 1 }, onTab: { probe.tabs += 1; return probe.tabHandles })
        let host = NSHostingView(rootView: view.frame(width: 400, height: 120))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSTextView? {
            if let found = view as? ComposerNSTextView { return found }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        let textView = try #require(find(host))
        window.makeFirstResponder(textView)
        return Harness(window: window, textView: textView, probe: probe)
    }

    private func press(_ h: Harness, _ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: h.window.windowNumber,
                                                  context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        h.textView.keyDown(with: event)
    }

    private let returnKey: UInt16 = 36
    private let tabKey: UInt16 = 48

    @Test func shiftReturnInsertsALineBreakAndDoesNotSend() throws {
        let h = try harness()
        h.textView.insertText("first", replacementRange: NSRange(location: NSNotFound, length: 0))
        try press(h, "\r", code: returnKey, .shift)
        h.textView.insertText("second", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(h.textView.string == "first\nsecond")
        #expect(h.probe.text == "first\nsecond", "the binding follows the text view")
        #expect(h.probe.sent == 0)
    }

    @Test func optionAndControlReturnAlsoInsertALineBreak() throws {
        let h = try harness()
        h.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        try press(h, "\r", code: returnKey, .option)
        try press(h, "\r", code: returnKey, .control)
        #expect(h.textView.string == "a\n\n")
        #expect(h.probe.sent == 0)
    }

    @Test func plainReturnAndCommandReturnSendWithoutAddingALineBreak() throws {
        let h = try harness()
        h.textView.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        try press(h, "\r", code: returnKey)
        #expect(h.probe.sent == 1)
        try press(h, "\r", code: returnKey, .command)
        #expect(h.probe.sent == 2)
        #expect(h.textView.string == "hello", "sending is not typing a newline")
    }

    @Test func returnInAnEmptyBoxDoesNothing() throws {
        let h = try harness()
        try press(h, "\r", code: returnKey)
        #expect(h.probe.sent == 0)
        #expect(h.textView.string.isEmpty)
    }

    @Test func returnWhileTheAgentWorksStillSendsSoItIsQueued() throws {
        let h = try harness(streaming: true)
        h.textView.insertText("next", replacementRange: NSRange(location: NSNotFound, length: 0))
        try press(h, "\r", code: returnKey)
        #expect(h.probe.sent == 1)
    }

    @Test func tabIsHandedToTheComposerForCompletion() throws {
        let h = try harness()
        try press(h, "\t", code: tabKey)
        #expect(h.probe.tabs == 1)
        h.probe.tabHandles = false
        try press(h, "\t", code: tabKey)
        #expect(h.probe.tabs == 2)
    }
}
