import SwiftUI
import AppKit

/// The message box. An `NSTextView` instead of SwiftUI's `TextEditor`, so Return, Shift+Return, ⌥Return, ⌘Return and Tab are decided in one place
/// that sees the real key event (SwiftUI's `onKeyPress` never reliably saw Shift+Return inside a TextEditor, which is why multi-line input did not work).
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isStreaming: Bool
    var onSend: () -> Void
    /// Tab completes a mention or slash command; return true when it did.
    var onTab: () -> Bool = { false }
    var onHeight: (CGFloat) -> Void = { _ in }
    var font = NSFont.systemFont(ofSize: 14)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // Replace the stock document view with ours (it has the same configuration).
        let textView = ComposerNSTextView()
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Apple's Writing Tools (proofread, rewrite, summarize) where the Mac has them. The message is plain text, so results come back as plain text.
        textView.writingToolsBehavior = .complete
        textView.allowedWritingToolsResultOptions = [.plainText]
        textView.setAccessibilityLabel("Message")
        textView.delegate = context.coordinator
        textView.onCommandReturn = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else { return false }
            return coordinator.handleReturn(flags: .command, textView: textView)
        }
        textView.string = text
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.moveToEndOfDocument(nil)
        }
        textView.font = font
        context.coordinator.reportHeight()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            reportHeight()
        }

        func reportHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
            let report = parent.onHeight
            DispatchQueue.main.async { report(height) }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let flags = (textView as? ComposerNSTextView)?.lastKeyFlags ?? NSApp.currentEvent?.modifierFlags ?? []
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                return handleReturn(flags: flags, textView: textView)
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // Shift/Control/Option Return as AppKit names them: a line break in the message.
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.insertTab(_:)):
                return parent.onTab()
            default:
                return false
            }
        }

        /// Decided by `ComposerReturn`, the same rules the unit tests cover.
        func handleReturn(flags: NSEvent.ModifierFlags, textView: NSTextView) -> Bool {
            switch ComposerReturn.decide(flags: flags, text: textView.string, isStreaming: parent.isStreaming, hasMarkedText: textView.hasMarkedText()) {
            case .send: parent.onSend(); return true
            case .newline: textView.insertNewlineIgnoringFieldEditor(nil); return true
            case .ignore: return true
            case .passThrough: return false
            }
        }
    }
}

/// Remembers the modifier keys of the key event being processed, because AppKit turns the key into a command (`insertNewline:`) and drops them.
final class ComposerNSTextView: NSTextView {
    var lastKeyFlags: NSEvent.ModifierFlags = []
    /// ⌘Return never becomes an `insertNewline:` command (AppKit keeps it as a key equivalent), so it is routed here.
    var onCommandReturn: (() -> Bool)?
    override func keyDown(with event: NSEvent) {
        lastKeyFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        defer { lastKeyFlags = [] }
        if lastKeyFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76, onCommandReturn?() == true { return }
        super.keyDown(with: event)
    }
}
