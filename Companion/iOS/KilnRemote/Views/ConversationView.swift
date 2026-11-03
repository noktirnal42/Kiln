import KilnRemoteKit
import SwiftUI

struct ConversationView: View {
    @Environment(RemoteSession.self) private var session
    @Environment(VoiceController.self) private var voice
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        StatusBanner()
                        ForEach(session.messages) { MessageBubble(role: $0.role, text: $0.text) }
                        if session.isStreaming {
                            if session.streamingText.isEmpty {
                                Label(session.activity ?? "Kiln is working…", systemImage: "ellipsis").font(.footnote).foregroundStyle(.secondary)
                                    .accessibilityLabel(session.activity ?? "Kiln is working")
                            } else {
                                MessageBubble(role: .assistant, text: session.streamingText)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: session.messages.count) { withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: session.streamingText) { proxy.scrollTo("bottom") }
            }
            ForEach(session.approvals) { ApprovalCard(approval: $0).padding(.horizontal).padding(.bottom, 6) }
            if voice.state != .idle || voice.errorMessage != nil { VoiceStrip() }
            Composer(draft: $draft, focused: $composerFocused)
        }
        .navigationTitle(session.openConversation?.title ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { voice.stopEverything() }
    }
}

struct MessageBubble: View {
    let role: RemoteMessage.Role
    let text: String

    var body: some View {
        HStack {
            if role == .user { Spacer(minLength: 40) }
            Text(rendered)
                .textSelection(.enabled)
                .padding(10)
                .background(role == .user ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            if role == .assistant { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(role == .user ? "You" : "Kiln"): \(SpokenText.clean(text))")
    }

    private var rendered: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct Composer: View {
    @Environment(RemoteSession.self) private var session
    @Environment(VoiceController.self) private var voice
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { voice.handsFree ? voice.stopEverything() : voice.startHandsFree() } label: {
                Image(systemName: voice.handsFree ? "waveform.circle.fill" : "waveform.circle").font(.title2)
            }
            .accessibilityLabel(voice.handsFree ? "End hands-free conversation" : "Start hands-free conversation")
            .accessibilityHint("Kiln listens, answers aloud, then listens again")

            TextField("Message Kiln", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused(focused)
                .accessibilityLabel("Message")

            if session.isStreaming {
                Button { session.stopReply() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .accessibilityLabel("Stop the reply")
            } else if draft.trimmingCharacters(in: .whitespaces).isEmpty {
                Button { voice.toggleDictation() } label: {
                    Image(systemName: voice.state == .listening ? "mic.fill" : "mic").font(.title2)
                        .foregroundStyle(voice.state == .listening ? .red : .accentColor)
                }
                .accessibilityLabel(voice.state == .listening ? "Stop listening and send" : "Dictate a message")
            } else {
                Button {
                    session.send(draft)
                    draft = ""
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(!session.isConnected)
                    .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}

struct VoiceStrip: View {
    @Environment(VoiceController.self) private var voice

    var body: some View {
        VStack(spacing: 2) {
            if let error = voice.errorMessage {
                Text(error).foregroundStyle(.red)
            } else {
                Text(label).font(.footnote.bold())
                if !voice.transcript.isEmpty { Text(voice.transcript).font(.callout).lineLimit(3) }
            }
        }
        .frame(maxWidth: .infinity).padding(8)
        .background(Color(.secondarySystemBackground))
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch voice.state {
        case .listening: "Listening…"
        case .thinking: "Waiting for Kiln…"
        case .speaking: "Speaking…"
        case .idle: ""
        }
    }
}

struct ApprovalCard: View {
    @Environment(RemoteSession.self) private var session
    let approval: RemoteApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(approval.tool) wants to \(verb)", systemImage: icon).font(.headline)
            Text(approval.preview)
                .font(.system(.footnote, design: .monospaced))
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                .lineLimit(8)
            HStack {
                Button("Deny", role: .destructive) { session.decide(approval, .deny) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Deny \(approval.tool)")
                Spacer()
                Button("Allow once") { session.decide(approval, .allowOnce) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Allow \(approval.tool) once")
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private var verb: String {
        switch approval.permission {
        case "read": "read"
        case "write": "change files"
        case "execute": "run a command"
        case "network": "use the network"
        default: "act"
        }
    }

    private var icon: String {
        switch approval.permission {
        case "read": "doc.text"
        case "write": "square.and.pencil"
        case "execute": "terminal"
        case "network": "network"
        default: "exclamationmark.shield"
        }
    }
}
