import SwiftUI

struct ChatRootView: View {
    @Bindable var session: ChatSession
    @State private var input = ""
    @State private var showModelPicker = false
    @State private var showConversationList = false
    @State private var showArtifacts = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ConversationListView(session: session, isVisible: $showConversationList)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    if session.messages.isEmpty && !session.isStreaming {
                        SSEmptyState(symbol: "sparkles", title: "Ask anything",
                                     message: "Chat with any model you have set up, or turn on Agent to let it read files, run commands and use Kiln's tools. Pick a model above to begin.")
                            .padding(.top, SSSpacing.xl)
                    }
                    LazyVStack(alignment: .leading, spacing: SSSpacing.m) {
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
                                isStreaming: true
                            )
                            .id("streaming")
                        }
                    }
                    .padding(SSSpacing.m)
                }
                .onChange(of: session.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: session.streamingText) { _, _ in
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
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView(session: session)
        }
        .sheet(isPresented: $showArtifacts) {
            ArtifactsBrowserView(artifactStore: session.artifacts)
        }
    }

    private var toolbar: some View {
        HStack(spacing: SSSpacing.s) {
            Button {
                showConversationList.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)

            Button {
                showModelPicker = true
            } label: {
                HStack(spacing: SSSpacing.xs) {
                    Image(systemName: "cpu")
                    Text(session.selectedModelID.isEmpty ? "Select model" : session.selectedModelID)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(SSTypography.caption())
                }
            }
            .buttonStyle(.bordered)

            Spacer()

            if session.isStreaming {
                Button("Stop") {
                    session.stopStreaming()
                }
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

struct ConversationListView: View {
    let session: ChatSession
    @Binding var isVisible: Bool
    @State private var conversations: [ConversationSummary] = []

    var body: some View {
        if isVisible {
            HStack {
                List {
                    Section {
                        Button {
                            Task { await session.newConversation(); conversations = await session.conversations() }
                        } label: {
                            Label("New Conversation", systemImage: "plus.bubble")
                        }
                        .buttonStyle(.plain)
                    }
                    Section("Recent") {
                        ForEach(conversations) { summary in
                            Button {
                                Task {
                                    await session.loadConversation(summary.id)
                                    isVisible = false
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(summary.title).font(SSTypography.body()).lineLimit(1)
                                    Text("\(summary.messageCount) messages · \(summary.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(SSTypography.caption())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 240)
                Divider()
            }
            .frame(height: 220)
            .task {
                conversations = await session.conversations()
            }
        }
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
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: SSSpacing.s) {
            TextEditor(text: $input)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 44, maxHeight: 160)
                .overlay(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("Message…  (@ to reference files, ⌘⏎ to send)")
                            .foregroundStyle(.tertiary)
                            .font(SSTypography.caption())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
                .onSubmit { onSend() }

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
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘⏎)")
            }
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.vertical, SSSpacing.s)
    }
}
