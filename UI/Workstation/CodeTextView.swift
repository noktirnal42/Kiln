import AppKit
import SwiftUI

/// A native NSTextView in a scroll view: system undo/redo, the standard find bar (⌘F, ⌘G), spell-free code typing,
/// a line-number gutter, auto-indent and regex syntax colouring.
struct CodeTextView: NSViewRepresentable {
    @Bindable var document: EditorDocument
    var settings: EditorSettings = .shared
    var language: SyntaxHighlighter.Language
    /// Line and column to move to, once.
    var jump: (line: Int, column: Int)?
    var onJumpDone: () -> Void
    var onCaretMove: (_ line: Int, _ column: Int) -> Void
    /// Live diagnostics for this file, drawn as underlines.
    var diagnostics: [LSPDiagnostic] = []
    var onEdited: () -> Void = {}
    /// ⌘-click: 0-based line and UTF-16 column.
    var onDefinition: (_ line: Int, _ column: Int) -> Void = { _, _ in }
    /// ⌥Esc / F5: asks the server, then shows the system completion popup.
    var onComplete: (_ line: Int, _ column: Int) async -> [String] = { _, _ in [] }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = CodeNSTextView(frame: .zero)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = context.coordinator
        textView.onCommandClick = { [weak coordinator = context.coordinator] index in coordinator?.commandClick(at: index) }
        textView.fetchCompletions = { [weak coordinator = context.coordinator] done in coordinator?.fetchCompletions(done) }
        textView.string = document.text
        scroll.documentView = textView

        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = LineNumberRuler(scrollView: scroll, textView: textView)

        context.coordinator.textView = textView
        context.coordinator.rehighlight(immediately: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != document.text {
            // The model changed underneath (reload from disk, recovery): keep the caret near where it was.
            let selected = textView.selectedRange()
            coordinator.isUpdatingFromModel = true
            textView.string = document.text
            coordinator.isUpdatingFromModel = false
            textView.setSelectedRange(NSRange(location: min(selected.location, (document.text as NSString).length), length: 0))
            coordinator.rehighlight(immediately: true)
        }
        coordinator.applySettings(settings, to: textView, scroll: scroll)
        coordinator.applyDiagnostics(diagnostics, to: textView)
        if coordinator.lastGitBase != document.gitBase {
            coordinator.lastGitBase = document.gitBase
            coordinator.refreshGutter()
        }
        if coordinator.lastLanguage != language {
            coordinator.lastLanguage = language
            coordinator.rehighlight(immediately: true)
        }
        if let jump {
            coordinator.go(to: jump.line, column: jump.column)
            DispatchQueue.main.async { onJumpDone() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var appliedFontSize: Double = 0
        private var appliedWrap: Bool?
        private var appliedLineNumbers: Bool?

        /// Applies live preference changes: font size, soft wrap and the line-number gutter.
        func applySettings(_ settings: EditorSettings, to textView: NSTextView, scroll: NSScrollView) {
            if appliedFontSize != settings.fontSize {
                appliedFontSize = settings.fontSize
                textView.font = NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
                rehighlight(immediately: true)
            }
            if appliedWrap != settings.softWrap {
                appliedWrap = settings.softWrap
                scroll.hasHorizontalScroller = !settings.softWrap
                textView.isHorizontallyResizable = !settings.softWrap
                textView.textContainer?.widthTracksTextView = settings.softWrap
                textView.textContainer?.containerSize = NSSize(
                    width: settings.softWrap ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude)
                textView.autoresizingMask = [.width]
            }
            if appliedLineNumbers != settings.showLineNumbers {
                appliedLineNumbers = settings.showLineNumbers
                scroll.rulersVisible = settings.showLineNumbers
            }
        }

        private func highlightMatchingBracket(in textView: NSTextView) {
            guard let layout = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            guard let (a, b) = BracketMatcher.match(in: textView.string, caret: textView.selectedRange().location),
                  textView.selectedRange().length == 0 else { return }
            for range in [a, b] {
                layout.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.3), forCharacterRange: range)
            }
        }
        var parent: CodeTextView
        weak var textView: NSTextView?
        var isUpdatingFromModel = false
        var lastLanguage: SyntaxHighlighter.Language?
        var lastGitBase: String?
        private var pending: DispatchWorkItem?

        init(_ parent: CodeTextView) {
            self.parent = parent
            self.lastLanguage = parent.language
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromModel, let textView else { return }
            parent.document.text = textView.string
            rehighlight(immediately: false)
            refreshGutter()
            editWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.parent.onEdited() }
            editWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        private var gutterWork: DispatchWorkItem?
        private var editWork: DispatchWorkItem?
        private var appliedDiagnostics: [LSPDiagnostic] = []
        var completionCache: [String] = []

        /// (line, UTF-16 column), both 0-based, for a character offset.
        func position(of index: Int, in text: NSString) -> (Int, Int) {
            var line = 0, lineStart = 0
            var cursor = 0
            while cursor < min(index, text.length) {
                if text.character(at: cursor) == 10 { line += 1; lineStart = cursor + 1 }
                cursor += 1
            }
            return (line, max(0, min(index, text.length) - lineStart))
        }

        func commandClick(at index: Int) {
            guard let textView else { return }
            let (line, column) = position(of: index, in: textView.string as NSString)
            parent.onDefinition(line, column)
        }

        func fetchCompletions(_ done: @escaping () -> Void) {
            guard let textView else { return done() }
            let (line, column) = position(of: textView.selectedRange().location, in: textView.string as NSString)
            Task { @MainActor in
                self.completionCache = await self.parent.onComplete(line, column)
                done()
            }
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let prefix = (textView.string as NSString).substring(with: charRange).lowercased()
            return completionCache.filter { prefix.isEmpty || $0.lowercased().hasPrefix(prefix) }
        }

        /// Underlines the ranges the language server flagged; red for errors, orange for warnings.
        func applyDiagnostics(_ diagnostics: [LSPDiagnostic], to textView: NSTextView) {
            guard diagnostics != appliedDiagnostics, let layout = textView.layoutManager else { return }
            appliedDiagnostics = diagnostics
            let text = textView.string as NSString
            let full = NSRange(location: 0, length: text.length)
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
            layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
            var lineStarts = [0]
            for i in 0..<text.length where text.character(at: i) == 10 { lineStarts.append(i + 1) }
            for diagnostic in diagnostics where diagnostic.line < lineStarts.count && diagnostic.endLine < lineStarts.count {
                let start = lineStarts[diagnostic.line] + diagnostic.column
                var end = lineStarts[diagnostic.endLine] + diagnostic.endColumn
                if end <= start { end = start + 1 }
                guard start < text.length else { continue }
                let range = NSRange(location: start, length: min(end, text.length) - start)
                layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.patternDot.union(.single).rawValue, forCharacterRange: range)
                layout.addTemporaryAttribute(.underlineColor, value: diagnostic.severity == .error ? NSColor.systemRed : NSColor.systemOrange, forCharacterRange: range)
            }
        }

        /// Recomputes the change markers shortly after the text or the committed base changes.
        func refreshGutter() {
            gutterWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let ruler = self.textView?.enclosingScrollView?.verticalRulerView as? LineNumberRuler else { return }
                ruler.hunks = self.parent.document.gitHunks
            }
            gutterWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let location = textView.selectedRange().location
            let text = textView.string as NSString
            let prefix = text.substring(to: min(location, text.length))
            let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let lastBreak = (prefix as NSString).range(of: "\n", options: .backwards)
            let column = lastBreak.location == NSNotFound ? location + 1 : location - NSMaxRange(lastBreak) + 1
            parent.onCaretMove(line, column)
            highlightMatchingBracket(in: textView)
        }

        /// Keeps the previous line's indentation after Return.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) {
                textView.insertText(parent.settings.indentUnit, replacementRange: textView.selectedRange())
                return true
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let text = textView.string as NSString
            let caret = textView.selectedRange().location
            let lineRange = text.lineRange(for: NSRange(location: min(caret, max(0, text.length - 1)), length: 0))
            let line = text.substring(with: lineRange)
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
            return true
        }

        func go(to line: Int, column: Int) {
            guard let textView else { return }
            let text = textView.string as NSString
            var location = 0
            var current = 1
            while current < line, location < text.length {
                let range = text.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(range)
                current += 1
            }
            let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            let target = min(lineRange.location + max(0, column - 1), NSMaxRange(lineRange))
            textView.setSelectedRange(NSRange(location: target, length: 0))
            textView.scrollRangeToVisible(lineRange)
            textView.showFindIndicator(for: lineRange)
            textView.window?.makeFirstResponder(textView)
        }

        func rehighlight(immediately: Bool) {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.applyHighlighting() }
            pending = work
            if immediately { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work) }
        }

        private func applyHighlighting() {
            guard let textView, let layout = textView.layoutManager else { return }
            let text = textView.string
            let full = NSRange(location: 0, length: (text as NSString).length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            for span in SyntaxHighlighter.spans(in: text, language: parent.language) {
                layout.addTemporaryAttribute(.foregroundColor, value: Self.color(for: span.kind), forCharacterRange: span.range)
            }
        }

        static func color(for kind: TokenKind) -> NSColor {
            func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
                NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
            }
            switch kind {
            case .comment: return dynamic(NSColor(white: 0.45, alpha: 1), NSColor(white: 0.55, alpha: 1))
            case .string: return dynamic(NSColor(red: 0.77, green: 0.10, blue: 0.09, alpha: 1), NSColor(red: 0.99, green: 0.42, blue: 0.36, alpha: 1))
            case .number: return dynamic(NSColor(red: 0.11, green: 0.0, blue: 0.81, alpha: 1), NSColor(red: 0.82, green: 0.75, blue: 0.40, alpha: 1))
            case .keyword: return dynamic(NSColor(red: 0.61, green: 0.14, blue: 0.58, alpha: 1), NSColor(red: 0.99, green: 0.37, blue: 0.64, alpha: 1))
            case .type: return dynamic(NSColor(red: 0.11, green: 0.43, blue: 0.51, alpha: 1), NSColor(red: 0.37, green: 0.85, blue: 0.84, alpha: 1))
            case .attribute: return dynamic(NSColor(red: 0.39, green: 0.22, blue: 0.13, alpha: 1), NSColor(red: 0.99, green: 0.56, blue: 0.27, alpha: 1))
            }
        }
    }
}

/// Line numbers in the gutter, drawn from the layout manager.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    /// Committed-vs-current differences, drawn as coloured bars beside the numbers.
    var hunks: [LineDiff.Hunk] = [] { didSet { needsDisplay = true } }

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func refresh() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.windowBackgroundColor.withAlphaComponent(0.6).setFill()
        rect.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let text = textView.string as NSString
        var line = 1
        // Count lines before the first visible glyph.
        let firstChar = layout.characterIndexForGlyph(at: glyphs.location)
        var index = 0
        while index < firstChar {
            let range = text.lineRange(for: NSRange(location: index, length: 0))
            if NSMaxRange(range) <= firstChar { line += 1 }
            index = NSMaxRange(range)
            if range.length == 0 { break }
        }
        var glyphIndex = glyphs.location
        while glyphIndex < NSMaxRange(glyphs) {
            var lineGlyphs = NSRange()
            let fragment = layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphs)
            let charIndex = layout.characterIndexForGlyph(at: glyphIndex)
            let paragraph = text.lineRange(for: NSRange(location: charIndex, length: 0))
            if paragraph.location == charIndex {
                let label = "\(line)" as NSString
                let size = label.size(withAttributes: attributes)
                let y = fragment.minY + textView.textContainerInset.height - visible.minY
                label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragment.height - size.height) / 2), withAttributes: attributes)
                if let hunk = LineDiff.hunk(at: line - 1, in: hunks) {
                    let color: NSColor = hunk.kind == .added ? .systemGreen : hunk.kind == .modified ? .systemBlue : .systemRed
                    color.setFill()
                    if hunk.kind == .removed {
                        NSRect(x: 0, y: y - 1, width: ruleThickness, height: 2).fill()
                    } else {
                        NSRect(x: ruleThickness - 4, y: y, width: 3, height: fragment.height).fill()
                    }
                }
                line += 1
            }
            glyphIndex = NSMaxRange(lineGlyphs)
        }
    }
}

/// NSTextView with ⌘-click (go to definition) and server-backed completion.
final class CodeNSTextView: NSTextView {
    var onCommandClick: ((Int) -> Void)?
    var fetchCompletions: ((@escaping () -> Void) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            onCommandClick?(characterIndexForInsertion(at: point))
            return
        }
        super.mouseDown(with: event)
    }

    private func showCompletionPopup(_ sender: Any?) { super.complete(sender) }

    override func complete(_ sender: Any?) {
        guard let fetchCompletions else { return super.complete(sender) }
        fetchCompletions { [weak self] in self?.showCompletionPopup(sender) }
    }
}
