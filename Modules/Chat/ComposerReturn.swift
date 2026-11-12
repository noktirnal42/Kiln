import AppKit
import SwiftUI

/// What pressing Return in the chat composer should do. Kept free of views so the rules are testable
/// without synthesising key events.
enum ComposerReturn: Equatable {
    case send
    case newline
    /// Return is swallowed (streaming, or nothing to send) so it never inserts a stray line break.
    case ignore
    /// An input method is composing: let it confirm its candidate instead of sending.
    case passThrough

    /// Same rules for a raw AppKit key event.
    nonisolated static func decide(flags: NSEvent.ModifierFlags, text: String, isStreaming: Bool, hasMarkedText: Bool) -> ComposerReturn {
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return decide(modifiers: modifiers, text: text, isStreaming: isStreaming, hasMarkedText: hasMarkedText)
    }

    /// Return sends (or queues, while the agent works). Shift, Option and Control Return add a line break. ⌘Return also sends or queues,
    /// as in Claude Code, so it never leaves a stray line break in a message that is about to go.
    nonisolated static func decide(modifiers: EventModifiers, text: String, isStreaming: Bool, hasMarkedText: Bool) -> ComposerReturn {
        if hasMarkedText { return .passThrough }
        if !modifiers.isDisjoint(with: [.shift, .option, .control]) { return .newline }
        // While a run is going Return still sends: the session queues the message and sends it when the run ends.
        let ready = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ready ? .send : .ignore
    }

    /// Whether the focused text view is mid-composition (Japanese, Chinese, Korean input, dead keys).
    @MainActor static var focusedViewIsComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }
}
