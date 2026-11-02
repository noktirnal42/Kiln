import SwiftUI

struct ChatRootView: View {
    @Bindable var session: ChatSession
    @State private var input = ""
    @State private var showArtifacts = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    if session.messages.isEmpty && !session.isStreaming {
                        ChatHero(session: session)
                    }
                    LazyVStack(alignment: .leading, spacing: SSSpacing.l) {
                        ForEach(session.messages) { message in
                            MessageBubble(session: session, message: message)
                                .id(message.id)
                        }
                        AgentActivityView(session: session)
                        if session.isStreaming {
                            MessageBubble(
                                session: session,
                                message: MessageSnapshot(
                                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
                                    role: .assistant,
                                    content: session.streamingText,
                                    toolCalls: session.streamingToolCalls,
                                    modelID: session.selectedModelID,
                                    createdAt: Date()
                                ),
                                isStreaming: true,
                                liveReasoning: session.streamingReasoning
                            )
                            .id("streaming")
                        }
                    }
                    .padding(SSSpacing.m)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: session.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: session.streamingText) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: session.streamingReasoning) { _, _ in
                    scrollToBottom(proxy)
                }
            }
            Divider()
            if let error = session.errorText {
                Text(error)
                    .font(SSTypography.caption())
                    .foregroundStyle(SSColor.danger)
                    .padding(.horizontal, SSSpacing.m)
                    .padding(.vertical, SSSpacing.xs)
                Divider()
            }
            ComposerView(session: session, input: $input, onSend: send)
        }
        .sheet(isPresented: $showArtifacts) {
            ArtifactsBrowserView(artifactStore: session.artifacts)
        }
    }

    private var toolbar: some View {
        HStack(spacing: SSSpacing.s) {
            Text(session.conversationTitle == ConversationTitle.placeholder ? "New chat" : session.conversationTitle)
                .font(SSTypography.headline())
                .lineLimit(1)
            Spacer()

            if session.isStreaming {
                Button("Stop") { session.stopStreaming() }
                    .buttonStyle(.bordered)
            } else {
                Button {
                    Task { await session.regenerate() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Regenerate last response")
            }

            Button {
                showArtifacts = true
            } label: {
                Image(systemName: "shippingbox")
            }
            .buttonStyle(.borderless)
            .help("Artifacts")
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.vertical, SSSpacing.s)
    }

    private func send() {
        let text = input
        input = ""
        Task { await session.send(text) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("streaming", anchor: .bottom)
        }
    }
}

/// What the conversation looks like before the first message: a question, with the project it is about, so the
/// agent's context is the first thing you see instead of a blank page.
struct ChatHero: View {
    let session: ChatSession

    var body: some View {
        VStack(spacing: SSSpacing.s) {
            Image("KilnMark").resizable().scaledToFit().frame(width: 44, height: 44).opacity(0.9)
            if let root = session.workspaceRoot {
                Text("What should we work on in ").font(.system(size: 24, weight: .light))
                    + Text(URL(fileURLWithPath: root).lastPathComponent).font(.system(size: 24, weight: .medium)).foregroundColor(SSColor.accent)
                    + Text("?").font(.system(size: 24, weight: .light))
            } else {
                Text("What should we work on?").font(.system(size: 24, weight: .light))
            }
            Text(session.selectedModelID.isEmpty
                 ? "Pick a model below to begin."
                 : "Ask a question, or turn on Agent to let it read, edit, run and build.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            StarterPromptList(session: session, activity: .agent).padding(.top, SSSpacing.l)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

struct ComposerView: View {
    let session: ChatSession
    @Binding var input: String
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AgentModeBar(session: session)
            composer
        }
        .onChange(of: session.draft) { _, text in takeDraft(text) }
        .onAppear { takeDraft(session.draft) }
    }

    /// A starter prompt or handed-over context lands in the box for the user to edit and send.
    private func takeDraft(_ text: String) {
        guard !text.isEmpty else { return }
        input = text
        session.draft = ""
    }

    /// Return sends; ⌘/⇧/⌥-Return puts a line break at the caret instead.
    private func insertNewline() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        } else {
            input += "\n"
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: SSSpacing.s) {
            TextEditor(text: $input)
                .font(.system(size: 14))
                .frame(minHeight: 44, maxHeight: 160)
                .overlay(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("Message…  (@ to reference files, ⏎ to send, ⌘⏎ for a new line)")
                            .foregroundStyle(.tertiary)
                            .font(SSTypography.caption())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.isDisjoint(with: [.command, .shift, .option]) {
                        let ready = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        if ready && !session.isStreaming { onSend() }
                        return .handled
                    }
                    insertNewline()
                    return .handled
                }

            if session.isStreaming {
                Button { session.stopStreaming() } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .help("Stop")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (⏎)")
            }
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.vertical, SSSpacing.s)
    }
}
