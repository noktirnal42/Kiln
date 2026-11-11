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

    nonisolated static func decide(modifiers: EventModifiers, text: String, isStreaming: Bool, hasMarkedText: Bool) -> ComposerReturn {
        if hasMarkedText { return .passThrough }
        if !modifiers.isDisjoint(with: [.command, .shift, .option]) { return .newline }
        // While a run is going Return still sends: the session queues the message and sends it when the run ends.
        let ready = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ready ? .send : .ignore
    }

    /// Whether the focused text view is mid-composition (Japanese, Chinese, Korean input, dead keys).
    @MainActor static var focusedViewIsComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }
}
