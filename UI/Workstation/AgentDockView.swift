import SwiftUI

/// The agent beside your work. Same conversation as the Agent activity, in a narrow column, so you
/// can ask about whatever is on screen without leaving it.
struct AgentDockView: View {
    let session: ChatSession
    let context: Activity
    @Bindable var workstation: WorkstationModel

    @State private var input = ""
    @State private var showModelPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            if let error = session.errorText {
                Text(error)
                    .font(SSTypography.caption()).foregroundStyle(SSColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SSSpacing.m).padding(.vertical, SSSpacing.xs)
            }
            Divider()
            ComposerView(session: session, input: $input, onSend: send)
        }
        .frame(width: 360)
        .background(SSColor.canvas)
        .sheet(isPresented: $showModelPicker) { ModelPickerView(session: session) }
    }

    private var header: some View {
        HStack(spacing: SSSpacing.s) {
            Image(systemName: "sparkles").foregroundStyle(SSColor.accent)
            Text("Agent").font(SSTypography.headline())
            SSBadge(text: context.title, tint: .secondary)
            Spacer()
            Button { showModelPicker = true } label: {
                HStack(spacing: 3) {
                    Text(session.selectedModelID.isEmpty ? "Select model" : shortModel)
                        .lineLimit(1).font(SSTypography.caption())
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(SSColor.surfaceRaised, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(session.selectedModelID.isEmpty ? "Pick a model" : session.selectedModelID)
            Button {
                Task { await session.newConversation() }
            } label: { Image(systemName: "plus.bubble").frame(width: 24, height: 24) }
                .buttonStyle(SSIconButtonStyle())
                .help("New conversation")
            Button { workstation.dockVisible = false } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
            }
            .buttonStyle(SSIconButtonStyle())
            .help("Hide the agent dock (⌘⌥A)")
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.vertical, SSSpacing.s)
    }

    private var shortModel: String {
        let id = session.selectedModelID
        return id.count > 22 ? String(id.prefix(21)) + "…" : id
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if session.messages.isEmpty && !session.isStreaming {
                    SSEmptyState(symbol: "sparkles", title: "Ask anything",
                                 message: "Chat with any model you have set up. Pick one above to begin.")
                        .padding(.top, SSSpacing.xl)
                }
                LazyVStack(alignment: .leading, spacing: SSSpacing.m) {
                    ForEach(session.messages) { message in
                        MessageBubble(session: session, message: message).id(message.id)
                    }
                    AgentActivityView(session: session)
                    if session.isStreaming {
                        MessageBubble(
                            session: session,
                            message: MessageSnapshot(
                                id: UUID(), role: .assistant, content: session.streamingText,
                                toolCalls: session.streamingToolCalls, modelID: session.selectedModelID,
                                createdAt: Date()),
                            isStreaming: true
                        )
                        .id("streaming")
                    }
                }
                .padding(SSSpacing.m)
            }
            .onChange(of: session.messages.count) { _, _ in scroll(proxy) }
            .onChange(of: session.streamingText) { _, _ in scroll(proxy) }
        }
    }

    private func send() {
        let text = input
        input = ""
        Task { await session.send(text) }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("streaming", anchor: .bottom) }
    }
}
