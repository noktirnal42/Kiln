import SwiftUI

extension Activity { static let messages = Activity("messages") }

enum MessagesActivity {
    static let descriptor = ActivityDescriptor(id: "messages", title: "Messages", symbol: "message", summary: "Write a text and open it in Messages", moduleIdentifier: nil,
        content: .custom { _ in AnyView(MessagesView()) },
        starterPrompts: { _ in [StarterPrompt(title: "Draft a text", symbol: "message", text: "Draft a short text message for me to send, then open it in Messages.")] },
        toolPrefixes: ["messages_"],
        agentPromptSentence: "messages_compose only opens a draft in the Messages app for the person to review and send; you cannot send, read texts or see replies.",
        capabilities: [
            .tool("messages_status", "What Messages handoff can do", .read),
            .tool("messages_compose", "Open a prefilled message in Messages (you press Send)", .admin),
        ], registerTools: { context in MessagesTool.register(into: context.registry) })
}

struct MessagesView: View {
    var body: some View {
        VStack(spacing: 0) {
            SSActivityHeader(title: "Messages", subtitle: "Compose here, review and send in Messages", symbol: "message")
            ScrollView {
                VStack(alignment: .leading, spacing: SSSpacing.m) {
                    TextMessageForm(onClose: {})
                    GroupBox("What this can and cannot do") {
                        Text(MessagesCapability.statement).font(SSTypography.caption()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }.frame(maxWidth: 520)
                }.padding(SSSpacing.m).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(SSColor.canvas)
    }
}
