import SwiftUI

/// One message, laid out like the reference chat apps: the user's words in a soft right-aligned bubble,
/// the assistant's reply as plain full-width text with no chrome, and a quiet action row that appears on hover.
struct MessageBubble: View {
    let session: ChatSession
    let message: MessageSnapshot
    var isStreaming = false
    /// Live thinking text while a reasoning model is still working on its answer.
    var liveReasoning = ""
    @State private var showReasoning = false
    @State private var hovering = false

    private var isUser: Bool { message.role == .user }
    private var reasoningText: String {
        isStreaming ? liveReasoning : (message.reasoning ?? "")
    }

    var body: some View {
        Group {
            if isUser { userBody } else { assistantBody }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { copy() }
            Button("Fork from here") { Task { await session.fork(at: message.id) } }
            if message.role == .user {
                Button("Rewind to here (restore files)") { Task { await session.rewind(to: message.id, restoreFiles: true) } }
                    .disabled(session.isStreaming)
                Button("Rewind conversation only") { Task { await session.rewind(to: message.id, restoreFiles: false) } }
                    .disabled(session.isStreaming)
            }
            Button("Delete", role: .destructive) { Task { await session.deleteMessage(message.id) } }
        }
    }

    // MARK: User

    private var userBody: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer(minLength: 60)
                Text(message.content)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            actionRow
        }
    }

    // MARK: Assistant

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !reasoningText.isEmpty { reasoningView }

            if !message.content.isEmpty {
                MarkdownBlockView(text: message.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isStreaming { ThinkingDots(label: message.content.isEmpty && reasoningText.isEmpty ? "Working" : nil) }

            if !message.toolCalls.isEmpty {
                StoredToolRunView(calls: message.toolCalls)
            }

            if !isStreaming { actionRow }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reasoningView: some View {
        let open = isStreaming ? true : showReasoning
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if !isStreaming { showReasoning.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text(isStreaming ? "Thinking…" : "Thought process").font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if open {
                ScrollView {
                    Text(reasoningText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: isStreaming ? 120 : 220)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2) }
            }
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: 6) {
            // A message whose run changed files always shows that it can be undone; the rest appear on hover.
            if message.role == .user, session.checkpointedMessageIDs.contains(message.id) {
                Button { Task { await session.rewind(to: message.id) } } label: {
                    Label("Rewind", systemImage: "arrow.uturn.backward").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .help("Rewind to before this message, restoring the files the agent changed")
                .accessibilityLabel("Rewind to before this message and restore files")
            }
            HStack(spacing: 2) {
                actionButton("doc.on.doc", "Copy") { copy() }
                if message.role == .assistant {
                    actionButton("arrow.clockwise", "Regenerate") { Task { await session.regenerate() } }
                }
                actionButton("arrow.triangle.branch", "Fork conversation from here") { Task { await session.fork(at: message.id) } }
                actionButton("trash", "Delete message") { Task { await session.deleteMessage(message.id) } }
                if message.role == .assistant {
                    Text(meta)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 6)
                        .lineLimit(1)
                }
            }
            // Never fully transparent: SwiftUI drops opacity-0 controls from the accessibility tree, which left these
            // actions unreachable for VoiceOver and keyboard users. To the eye they still appear only on hover.
            .opacity(hovering ? 1 : 0.01)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let model = message.modelID, !model.isEmpty { parts.append(model) }
        if message.tokenCount > 0 { parts.append("\(message.tokenCount) tok") }
        if message.id == session.messages.last?.id, let timing = session.lastTiming {
            if let first = timing.firstTokenSeconds { parts.append(String(format: "first token %.1f s", first)) }
            parts.append(String(format: "total %.1f s", timing.totalSeconds))
        }
        parts.append(message.createdAt.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private func actionButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }
}

/// Three softly pulsing dots shown while a reply is still arriving.
struct ThinkingDots: View {
    var label: String?
    @State private var phase = false
    @State private var since = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            dots(waited: context.date.timeIntervalSince(since))
        }
        .onAppear { phase = true; since = Date() }
        .accessibilityLabel("Assistant is responding")
    }

    private func dots(waited: TimeInterval) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(phase ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2), value: phase)
            }
            if let label {
                Text(waited > 60 ? "No answer after \(Int(waited)) s. The provider may be busy: Stop, then pick another model from the model menu."
                     : waited > 15 ? "Still waiting for the model to start responding" : label)
                    .font(.system(size: 12)).foregroundStyle(waited > 60 ? SSColor.warning : .secondary)
            }
        }
    }
}

struct ToolCallChipsView: View {
    let calls: [ToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.xs) {
            ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                HStack(spacing: SSSpacing.xs) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(SSTypography.caption())
                        .foregroundStyle(SSColor.warning)
                    Text(call.name.isEmpty ? "tool call" : call.name)
                        .font(SSTypography.mono(11))
                    Spacer()
                }
                .padding(.horizontal, SSSpacing.s)
                .padding(.vertical, SSSpacing.xs)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: SSCornerRadius.small))
            }
        }
    }
}
