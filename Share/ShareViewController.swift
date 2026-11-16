import AppKit
import UniformTypeIdentifiers

/// "Ask Kiln" in the Share menu. It takes the text, web address and title being shared, builds a `kiln://share` link and hands it to Kiln, which
/// puts it in the message box (it never sends). The extension is sandboxed and reads only what the sharing app handed it.
final class ShareViewController: NSViewController {
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)) }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { await handOver() }
    }

    private func handOver() async {
        var title = "", address = "", text = ""
        for item in (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] {
            if title.isEmpty { title = item.attributedTitle?.string ?? "" }
            if text.isEmpty, let content = item.attributedContentText?.string { text = content }
            for provider in item.attachments ?? [] {
                if address.isEmpty, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier), let url = value as? URL, !url.isFileURL {
                    address = url.absoluteString
                } else if text.isEmpty, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier), let string = value as? String {
                    text = string
                }
            }
        }
        // A long selection is clipped so the link stays small enough to open.
        let clipped = text.count > 4_000 ? String(text.prefix(4_000)) : text
        if let link = QuickAskLink.shareLink(title: QuickAskLink.sanitize(title), url: address, text: QuickAskLink.sanitize(clipped)) {
            NSWorkspace.shared.open(link)
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
