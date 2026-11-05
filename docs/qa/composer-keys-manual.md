# Composer keys: manual check list (issue #8)

Automated coverage: `ComposerReturnTests` pins the decision (send / newline / ignore / pass-through) for Return with and without ⌘ ⇧ ⌥, an empty box, streaming, and an active input-method composition.

**Why there is no key-event UI test.** A hosted `ComposerView` in a window created by the unit-test runner never becomes the key window (`isKeyWindow == false`), so SwiftUI's `onKeyPress` and `NSApp.keyWindow.firstResponder` are not reached by `NSWindow.sendEvent`. An attempt (2026-11-04) produced only vacuous passes, so it was not committed. A real check needs an XCUITest target with Accessibility permission, or the manual steps below.

Run on a build of the app, in Chat and in the agent dock composer:

1. Type `abcd`, move the caret between `b` and `c`, press ⌘Return, ⇧Return, ⌥Return in turn: each inserts a line break at the caret (`ab⏎c…`), nothing is sent.
2. Press Return with text: it sends, no stray line break remains in the box.
3. Press Return with an empty or whitespace-only box: nothing happens.
4. While a reply streams, press Return with text in the box: nothing is sent and no line break appears; Stop still works.
5. IME: switch to Japanese (Hiragana) or Pinyin, type `nihon`, press Return to confirm the candidate: the text is committed, nothing is sent. Press Return again: the message sends.
6. Dead keys (US International: `'` then `e`): composes `é`, Return afterwards sends.
7. Repeat 1-3 on one non-US layout (e.g. German, Dvorak).

Record the result, layout names and macOS version in the issue.
