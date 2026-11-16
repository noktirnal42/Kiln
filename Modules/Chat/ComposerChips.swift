import SwiftUI
import AppKit

/// Small pill used for attachments, queued messages and attached names in the thread.
struct ComposerChip: View {
    let symbol: String
    let title: String
    var detail: String?
    var tint: Color = .secondary
    var onRemove: (() -> Void)?
    var removeLabel = "Remove"

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
            Text(title).font(ThemeRuntime.font(11.5)).lineLimit(1).truncationMode(.middle)
            if let detail { Text(detail).font(ThemeRuntime.font(10)).foregroundStyle(.tertiary) }
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(removeLabel)
                    .accessibilityLabel("\(removeLabel) \(title)")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(SSColor.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(SSColor.hairline))
        .frame(maxWidth: 240)
        .accessibilityElement(children: .contain)
    }

    static func symbol(for kind: ComposerAttachment.Kind) -> String {
        switch kind { case .file: "doc.text"; case .folder: "folder"; case .image: "photo" }
    }
}

/// Attached files above the composer, and messages waiting for the current run to end.
struct ComposerContextRow: View {
    let session: ChatSession

    var body: some View {
        if !session.attachments.isEmpty || !session.queuedMessages.isEmpty {
            VStack(alignment: .leading, spacing: SSSpacing.xs) {
                if !session.queuedMessages.isEmpty {
                    HStack(spacing: SSSpacing.xs) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(session.queuePaused ? "Queued (paused)" : "Queued").font(SSTypography.caption()).foregroundStyle(.secondary)
                        ForEach(session.queuedMessages) { message in
                            ComposerChip(symbol: "clock", title: message.text, onRemove: { session.removeQueued(message.id) }, removeLabel: "Remove queued message")
                        }
                        if session.queuePaused, !session.isStreaming {
                            Button("Send now") { Task { await session.sendNextQueued() } }
                                .controlSize(.small).buttonStyle(.bordered)
                        }
                    }
                }
                if !session.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: SSSpacing.xs) {
                            ForEach(session.attachments) { attachment in
                                ComposerChip(symbol: ComposerChip.symbol(for: attachment.kind), title: attachment.name,
                                             tint: SSColor.accent, onRemove: { session.removeAttachment(attachment.id) }, removeLabel: "Remove attachment")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, SSSpacing.m).padding(.top, SSSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Matches for the `@` being typed, shown above the box; click (or Tab) to complete.
struct MentionList: View {
    let matches: [String]
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element) { index, path in
                Button { onPick(path) } label: {
                    HStack(spacing: SSSpacing.s) {
                        Image(systemName: path.hasSuffix("/") ? "folder" : "doc.text").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                        Text((path as NSString).lastPathComponent.isEmpty ? path : (path.hasSuffix("/") ? (String(path.dropLast()) as NSString).lastPathComponent + "/" : (path as NSString).lastPathComponent))
                            .font(ThemeRuntime.font(12, .medium))
                        Text(path).font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer()
                        if index == 0 { SSKeyCap("⇥") }
                    }
                    .padding(.horizontal, SSSpacing.s).padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reference \(path)")
            }
        }
        .background(SSColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, SSSpacing.m)
    }
}
