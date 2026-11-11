import SwiftUI

/// The agent beside your work. Same conversation as the Agent activity, in a narrow column, so you
/// can ask about whatever is on screen without leaving it.
struct AgentDockView: View {
    let session: ChatSession
    let context: Activity
    @Bindable var workstation: WorkstationModel

    @State private var input = ""

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
    }

    private var header: some View {
        HStack(spacing: SSSpacing.s) {
            Image(systemName: "sparkles").foregroundStyle(SSColor.accent)
            Text("Agent").font(SSTypography.headline())
            SSBadge(text: context.title, tint: .secondary)
            Spacer()
            Button {
                Task { await session.newConversation() }
            } label: { Image(systemName: "plus.bubble").frame(width: 24, height: 24) }
                .buttonStyle(SSIconButtonStyle())
                .help("New conversation")
                .accessibilityLabel("New conversation")
            Button { workstation.dockVisible = false } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
            }
            .buttonStyle(SSIconButtonStyle())
            .help("Hide the agent dock (⌘⌥A)")
            .accessibilityLabel("Hide agent dock")
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.vertical, SSSpacing.s)
    }


    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if session.messages.isEmpty && !session.isStreaming {
                    VStack(spacing: SSSpacing.m) {
                        SSEmptyState(symbol: "sparkles", title: "Ask about this",
                                     message: "The same conversation as the Agent tab, beside whatever you are working on.")
                        StarterPromptList(session: session, activity: context, compact: true)
                            .padding(.horizontal, SSSpacing.m)
                    }
                    .padding(.top, SSSpacing.l)
                }
                LazyVStack(alignment: .leading, spacing: SSSpacing.l) {
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
                            isStreaming: true,
                            liveReasoning: session.streamingReasoning
                        )
                        .id("streaming")
                    }
                }
                .padding(SSSpacing.m)
            }
            .onChange(of: session.messages.count) { _, _ in scroll(proxy) }
            .onChange(of: session.streamingText) { _, _ in scroll(proxy) }
            .onChange(of: session.streamingReasoning) { _, _ in scroll(proxy) }
            .onChange(of: session.isStreaming) { _, _ in scroll(proxy) }
        }
    }

    private func send() {
        let text = input
        input = ""
        Task { await session.send(text) }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            if session.isStreaming { proxy.scrollTo("streaming", anchor: .bottom) }
            else if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}
