import SwiftUI

struct ChatRootView: View {
    @Bindable var session: ChatSession
    @State private var showArtifacts = false
    @State private var voice = VoiceController()
    @State private var lastSpokenID: UUID?

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
                        ForEach(Array(session.messages.enumerated()), id: \.element.id) { index, message in
                            MessageBubble(session: session, message: message)
                                .id(message.id)
                            if let owner = diffOwner(at: index) { RunDiffCardView(session: session, messageID: owner) }
                            ForEach(session.contextNotes.filter { $0.afterMessageCount == index + 1 }) { ContextNoteView(note: $0) }
                        }
                        ForEach(session.contextNotes.filter { $0.afterMessageCount > session.messages.count || $0.afterMessageCount <= 0 }) {
                            ContextNoteView(note: $0)
                        }
                        AgentActivityView(session: session)
                        if let report = session.verifierReport, !session.isStreaming {
                            Label(report.summary, systemImage: report.findings.isEmpty && report.unavailable == nil ? "checkmark.shield" : "exclamationmark.shield")
                                .font(SSTypography.caption()).foregroundStyle(report.findings.isEmpty ? Color.secondary : SSColor.warning)
                        }
                        if let plan = session.pendingPlan, !session.isStreaming { PlanCardView(session: session, plan: plan) }
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
                .onChange(of: session.isStreaming) { _, _ in
                    scrollToBottom(proxy)
                }
            }
            Divider()
            if let error = session.errorText {
                HStack(alignment: .firstTextBaseline, spacing: SSSpacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(SSColor.danger)
                    Text(error).font(SSTypography.caption()).foregroundStyle(SSColor.danger).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { session.dismissError() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Dismiss").accessibilityLabel("Dismiss this message")
                }
                .padding(.horizontal, SSSpacing.m)
                .padding(.vertical, SSSpacing.xs)
                .background(SSColor.danger.opacity(0.08))
                Divider()
            }
            ComposerView(session: session, voice: voice, input: $session.composerText, onSend: send)
        }
        .onAppear {
            voice.onUtterance = { text in
                if voice.conversation {
                    session.composerText = ""
                    Task { await session.send(text) }
                } else {
                    session.composerText += (session.composerText.isEmpty ? "" : " ") + text
                }
            }
        }
        .onDisappear { voice.stopEverything() }
        .task(id: session.selectedModelID) { await session.refreshContext() }
        .onChange(of: session.isStreaming) { _, streaming in
            guard !streaming, voice.speakReplies else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                speakLatestReply()
            }
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
                .accessibilityLabel("Regenerate last response")
            }

            Button {
                showArtifacts = true
            } label: {
                Image(systemName: "shippingbox")
            }
            .buttonStyle(.borderless)
            .help("Artifacts")
            .accessibilityLabel("Artifacts")
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.vertical, SSSpacing.s)
    }

    /// Reads the newest assistant message aloud once; with nothing to say in conversation mode, goes straight back to listening.
    private func speakLatestReply() {
        guard let reply = session.messages.last, reply.role == .assistant, reply.id != lastSpokenID else {
            if voice.conversation, voice.phase == .idle { Task { await voice.startListening() } }
            return
        }
        lastSpokenID = reply.id
        voice.speak(reply.content)
    }

    /// The user message whose run just ended at `index` (the last reply before the next prompt), if that run changed files.
    private func diffOwner(at index: Int) -> UUID? {
        let all = session.messages
        guard all[index].role == .assistant, index == all.count - 1 || all[index + 1].role == .user,
              let user = all[..<index].last(where: { $0.role == .user }),
              session.checkpointedMessageIDs.contains(user.id) else { return nil }
        return user.id
    }

    private func send() {
        voice.stopSpeaking()
        let text = session.composerText
        session.composerText = ""
        Task { await session.send(text) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            // The live bubble is replaced by the saved message when a reply ends; follow it instead of jumping to the top.
            if session.isStreaming { proxy.scrollTo("streaming", anchor: .bottom) }
            else if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
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
                Text("What should we work on in ").font(ThemeRuntime.font(24, .light))
                    + Text(URL(fileURLWithPath: root).lastPathComponent).font(ThemeRuntime.font(24, .medium)).foregroundColor(SSColor.accent)
                    + Text("?").font(ThemeRuntime.font(24, .light))
            } else {
                Text("What should we work on?").font(ThemeRuntime.font(24, .light))
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
    var voice: VoiceController?
    @Binding var input: String
    let onSend: () -> Void
    @State private var textHeight: CGFloat = 40
    @State private var mentionMatches: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            if let voiceError = voice?.errorText {
                Text(voiceError).font(SSTypography.caption()).foregroundStyle(SSColor.danger)
                    .padding(.horizontal, SSSpacing.m).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !completions.isEmpty {
                CommandCompletionList(matches: completions) { input = "/\($0.name) " }
                    .padding(.top, SSSpacing.xs)
            }
            if !mentionMatches.isEmpty {
                MentionList(matches: mentionMatches) { input = MentionParser.completing(input, with: $0) }
                    .padding(.top, SSSpacing.xs)
            }
            TodoCardView(session: session)
            ComposerContextRow(session: session)
            if let steps = session.pausedAfterRounds, !session.isStreaming {
                HStack {
                    Text("Paused after \(steps) steps").font(SSTypography.caption()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Keep going") { Task { await session.continuePausedRun() } }
                        .controlSize(.small)
                        .help("Continue in a new turn with the in-memory tool context. Approvals and budget limits still apply.")
                }
                .padding(.horizontal, SSSpacing.m).padding(.vertical, SSSpacing.xs)
            }
            composer
            AgentModeBar(session: session).padding(.top, 2)
        }
        .task(id: MentionParser.activeQuery(in: input)) { await refreshMentions() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in session.attach([url]) }
                }
            }
            return true
        }
        .onChange(of: session.draft) { _, text in takeDraft(text) }
        .onAppear { takeDraft(session.draft) }
    }

    /// Files matching the `@` being typed, searched off the main thread (a project can have thousands).
    private func refreshMentions() async {
        guard let query = MentionParser.activeQuery(in: input), let root = session.workspaceRoot else { mentionMatches = []; return }
        try? await Task.sleep(for: .milliseconds(120))   // let typing settle
        if Task.isCancelled { return }
        let url = URL(fileURLWithPath: root, isDirectory: true)
        let found = await Task.detached(priority: .userInitiated) { WorkspaceFileSearch.matches(query: query, root: url) }.value
        if !Task.isCancelled { mentionMatches = found }
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files or folders to attach to the next message."
        panel.prompt = "Attach"
        if panel.runModal() == .OK { session.attach(panel.urls) }
    }

    private var completions: [SlashCommand] {
        SlashCommands.completions(for: input, commands: session.availableCommands())
    }

    /// A starter prompt or handed-over context lands in the box for the user to edit and send.
    private func takeDraft(_ text: String) {
        guard !text.isEmpty else { return }
        input = text
        session.draft = ""
    }

    /// Dictate, read replies aloud, or hold a spoken conversation.
    private func voiceControls(_ voice: VoiceController) -> some View {
        HStack(spacing: SSSpacing.xs) {
            Button { voice.toggleListening() } label: {
                Image(systemName: voice.phase == .listening ? "mic.fill" : "mic")
                    .font(.title3)
                    .foregroundStyle(voice.phase == .listening ? SSColor.danger : Color.primary)
            }
            .help(voice.phase == .listening ? "Stop listening" : "Dictate into the message")
            .accessibilityLabel(voice.phase == .listening ? "Stop dictation" : "Start dictation")

            Button { voice.speakReplies.toggle(); if !voice.speakReplies { voice.stopEverything() } } label: {
                Image(systemName: voice.speakReplies ? "speaker.wave.2.fill" : "speaker.slash").font(.title3)
            }
            .help(voice.speakReplies ? "Replies are read aloud (click to mute)" : "Read replies aloud")
            .accessibilityLabel(voice.speakReplies ? "Mute spoken replies" : "Read replies aloud")

            Button { voice.conversation ? voice.stopEverything() : voice.setConversation(true) } label: {
                Image(systemName: "waveform.circle\(voice.conversation ? ".fill" : "")")
                    .font(.title3)
                    .foregroundStyle(voice.conversation ? SSColor.accent : Color.primary)
            }
            .help(voice.conversation ? "End the voice conversation" : "Talk with the model: speak, pause to send, hear the reply")
            .accessibilityLabel(voice.conversation ? "End voice conversation" : "Start voice conversation")
        }
        .buttonStyle(.borderless)
    }

    /// One rounded card, like Claude Code and Codex: the text, then a row with "+", voice and send. The model, mode and context sit under it.
    private var composer: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                ComposerTextView(text: $input, isStreaming: session.isStreaming, onSend: onSend, onTab: completeFromTab, onHeight: { textHeight = $0 })
                    .frame(height: min(168, max(40, textHeight + 4)))
                if let voice, voice.phase == .listening {
                    Text(voice.partial.isEmpty ? "Listening…" : voice.partial)
                        .foregroundStyle(.secondary).font(SSTypography.caption())
                        .padding(.horizontal, 8).padding(.top, 8).allowsHitTesting(false)
                } else if input.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary).font(ThemeRuntime.font(13))
                        .padding(.horizontal, 8).padding(.top, 7).allowsHitTesting(false)
                }
            }
            HStack(spacing: SSSpacing.xs) {
                plusMenu
                Spacer(minLength: 0)
                if let voice { voiceControls(voice) }
                sendButtons
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, SSSpacing.s).padding(.vertical, SSSpacing.xs)
        .background(SSColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SSColor.hairline))
        .padding(.horizontal, SSSpacing.m)
        .padding(.top, SSSpacing.xs)
    }

    private var placeholder: String {
        session.isStreaming ? "Type to queue the next message  ·  ⏎ queues it" : "Message  ·  ⏎ send  ·  ⇧⏎ new line  ·  @ file  ·  / command"
    }

    private var plusMenu: some View {
        Menu {
            Button("Attach files or folders…", systemImage: "paperclip") { attachFiles() }
            Button("Reference a project file (@)", systemImage: "at") { if !input.hasSuffix("@") { input += (input.isEmpty || input.hasSuffix(" ") ? "" : " ") + "@" } }
            Button("Slash commands (/)", systemImage: "slash.circle") { if input.isEmpty { input = "/" } }
            Divider()
            Button(session.memory.totalTokens > 0 ? "Memory files (\(session.memory.totalTokens.formatted()) tokens)…" : "Memory files…", systemImage: "brain") { session.requestedPane = .memory }
        } label: {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Attach files, reference a file with @, run a slash command, or open the memory files (KILN.md, AGENTS.md, CLAUDE.md). You can also drop files here.")
        .accessibilityLabel("Add to message")
    }

    @ViewBuilder
    private var sendButtons: some View {
        let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if session.isStreaming {
            if hasText {
                Button(action: onSend) { Image(systemName: "text.append").font(.system(size: 15)) }
                    .buttonStyle(.borderless)
                    .help("Queue this message: it is sent when the agent finishes (⏎)")
                    .accessibilityLabel("Queue message")
            }
            Button { session.stopStreaming() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 22)) }
                .buttonStyle(.borderless)
                .help("Stop")
                .accessibilityLabel("Stop generating")
        } else {
            Button(action: onSend) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                .buttonStyle(.borderless)
                .disabled(!hasText)
                .help("Send (⏎)")
                .accessibilityLabel("Send message")
        }
    }

    /// Tab completes the first mention, else the first slash command.
    private func completeFromTab() -> Bool {
        if let first = mentionMatches.first, MentionParser.activeQuery(in: input) != nil {
            input = MentionParser.completing(input, with: first)
            return true
        }
        if let first = completions.first { input = "/\(first.name) "; return true }
        return false
    }
}

/// "Context compacted (12,400 → 3,100 tokens)", as a quiet divider in the thread.
struct ContextNoteView: View {
    let note: ContextNote

    var body: some View {
        HStack(spacing: SSSpacing.xs) {
            VStack { Divider() }
            Label(note.text, systemImage: "arrow.down.right.and.arrow.up.left")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
                .fixedSize()
            VStack { Divider() }
        }
        .accessibilityElement(children: .combine)
    }
}
