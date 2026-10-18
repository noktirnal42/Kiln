import SwiftUI

struct MessageBubble: View {
    let session: ChatSession
    let message: MessageSnapshot
    var isStreaming = false
    @State private var showReasoning = false

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            HStack(spacing: SSSpacing.xs) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(SSTypography.caption())
                Text(roleName)
                    .font(SSTypography.caption())
                    .foregroundStyle(.secondary)
                if let model = message.modelID, !model.isEmpty {
                    Text(model)
                        .font(SSTypography.caption())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if message.tokenCount > 0 {
                    Text("\(message.tokenCount) tok")
                        .font(SSTypography.caption())
                        .foregroundStyle(.tertiary)
                }
                Text(message.createdAt, style: .time)
                    .font(SSTypography.caption())
                    .foregroundStyle(.tertiary)
            }

            if let reasoning = message.reasoning, !reasoning.isEmpty {
                DisclosureGroup(isExpanded: $showReasoning) {
                    Text(reasoning)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(SSSpacing.s)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: SSCornerRadius.small))
                } label: {
                    Text("Reasoning").font(SSTypography.caption())
                }
            }

            if !message.content.isEmpty {
                MarkdownBlockView(text: message.content)
                    .textSelection(.enabled)
            } else if isStreaming {
                Text("…")
                    .foregroundStyle(.tertiary)
            }

            if !message.toolCalls.isEmpty {
                ToolCallChipsView(calls: message.toolCalls)
            }

            if !isStreaming {
                HStack(spacing: SSSpacing.xs) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")

                    if message.role == .assistant {
                        Button {
                            Task { await session.regenerate() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Regenerate")
                    }

                    Button {
                        Task { await session.fork(at: message.id) }
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .buttonStyle(.borderless)
                    .help("Fork conversation from here")

                    Button {
                        Task { await session.deleteMessage(message.id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete message")
                }
                .font(SSTypography.caption())
                .foregroundStyle(.secondary)
            }
        }
        .padding(SSSpacing.m)
        .background(isStreaming ? Color.accentColor.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: SSCornerRadius.medium))
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
            }
            Button("Fork from here") {
                Task { await session.fork(at: message.id) }
            }
            Button("Delete", role: .destructive) {
                Task { await session.deleteMessage(message.id) }
            }
        }
    }

    private var icon: String {
        switch message.role {
        case .user: return "person.crop.circle"
        case .assistant: return "sparkles"
        case .system: return "gearshape"
        case .tool: return "wrench.and.screwdriver"
        }
    }

    private var color: Color {
        switch message.role {
        case .user: return SSColor.accent
        case .assistant: return SSColor.success
        case .system: return .secondary
        case .tool: return SSColor.warning
        }
    }

    private var roleName: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .system: return "System"
        case .tool: return "Tool"
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
