import KilnRemoteKit
import SwiftUI

struct ConversationsView: View {
    @Environment(RemoteSession.self) private var session
    @Environment(VoiceController.self) private var voice
    @State private var path: [String] = []
    @State private var showSettings = false

    var body: some View {
        @Bindable var session = session
        NavigationStack(path: $path) {
            List {
                StatusBanner().listRowSeparator(.hidden)
                if !session.approvals.isEmpty {
                    Section("Waiting for you") {
                        ForEach(session.approvals) { ApprovalCard(approval: $0) }
                    }
                }
                Section("Conversations") {
                    if session.conversations.isEmpty {
                        Text(session.isConnected ? "No conversations yet. Tap + to start one." : "Conversations will appear when your Mac connects.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.conversations) { conversation in
                        Button {
                            session.open(conversation.id)
                            path.append(conversation.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conversation.title).font(.headline).lineLimit(2)
                                Text(conversation.updatedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Opens this conversation")
                    }
                }
            }
            .navigationTitle(session.hostName ?? "Kiln")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { _ in ConversationView() }
            .refreshable { session.refreshConversations() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        session.newConversation()
                        path.append("new")
                    } label: { Image(systemName: "square.and.pencil") }
                        .disabled(!session.isConnected)
                        .accessibilityLabel("New conversation")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}

struct SettingsView: View {
    @Environment(RemoteSession.self) private var session
    @Environment(VoiceController.self) private var voice
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        @Bindable var voice = voice
        NavigationStack {
            Form {
                Section("Paired Mac") {
                    LabeledContent("Name", value: session.mac?.hostName ?? "None")
                    LabeledContent("Status", value: statusText)
                    LabeledContent("Internet relay", value: session.mac?.relay?.host ?? "Not set up")
                    TextField("Mac address, e.g. 100.101.102.103:47900", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onSubmit { session.setManualAddress(address) }
                        .accessibilityLabel("Mac address")
                        .accessibilityHint("Optional. A Tailscale or direct host and port, used instead of finding the Mac on this network")
                    Button("Unpair this Mac", role: .destructive) { session.unpair(); dismiss() }
                        .accessibilityHint("Deletes the saved key; scan the code on your Mac to pair again")
                }
                WatchSection()
                Section("Voice") {
                    Toggle("Read replies aloud", isOn: $voice.readRepliesAloud)
                }
                if let error = session.lastError { Section("Last problem") { Text(error) } }
            }
            .onAppear { address = session.mac?.address ?? "" }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var statusText: String {
        switch session.status {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .needsRepairing: "Needs pairing again"
        case .unpaired: "Not paired"
        }
    }
}

struct WatchSection: View {
    private var watch: WatchHandoff { .shared }

    var body: some View {
        Section("Apple Watch") {
            row("Watch paired with this iPhone", watch.watchPaired)
            row("Kiln Remote installed on watch", watch.watchAppInstalled)
            row("Watch reachable now", watch.reachable)
            LabeledContent("Watch bridge") {
                Text(bridgeText).foregroundStyle(bridgeOn ? .green : .secondary)
            }
            if let seen = WatchBridge.shared.lastWatchActivity {
                LabeledContent("Last watch request", value: seen.formatted(date: .omitted, time: .standard))
            }
            LabeledContent("Pairing sent", value: watch.lastSent.map { $0.formatted(date: .omitted, time: .standard) } ?? "Not yet")
            if let blocked = watch.blocked { Text(blocked).font(.footnote).foregroundStyle(.orange) }
            Button("Send pairing to watch") { watch.resend() }
                .accessibilityHint("Sends the Mac pairing to the Kiln Remote app on your Apple Watch")
        }
    }

    private var bridgeOn: Bool { watch.activated && watch.watchPaired && session.isConnected }
    private var bridgeText: String {
        if bridgeOn { return "on" }
        if !watch.watchPaired { return "off: no watch" }
        return "off: not connected to the Mac"
    }
    @Environment(RemoteSession.self) private var session

    private func row(_ title: String, _ on: Bool) -> some View {
        LabeledContent(title) {
            Image(systemName: on ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(on ? .green : .secondary)
                .accessibilityLabel(on ? "Yes" : "No")
        }
    }
}
