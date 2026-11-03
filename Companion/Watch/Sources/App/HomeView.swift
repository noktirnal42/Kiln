import KilnRemoteKit
import SwiftUI

struct HomeView: View {
    let session: RemoteSession
    var pair: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                StatusRow(link: session.link, stage: session.stage)
                if session.link == .unpaired {
                    UnpairedView(status: session.phoneStatus, pair: pair)
                } else {
                    TalkButton(session: session)
                    if !session.pendingApprovals.isEmpty {
                        Button { session.reviewing = session.pendingApprovals.first } label: {
                            Label("\(session.pendingApprovals.count) to approve", systemImage: "exclamationmark.shield.fill")
                        }
                        .tint(.orange)
                        .accessibilityLabel("\(session.pendingApprovals.count) approvals waiting")
                        .accessibilityHint("Opens the approval")
                    }
                    ReplyCaption(session: session)
                    if case .offline = session.link {
                        Button("Retry") { session.connect() }
                            .accessibilityLabel("Retry connecting to your Mac")
                        Button("Pair again") { pair() }
                            .accessibilityLabel("Ask the iPhone to send the pairing again")
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .sheet(item: Binding(get: { session.reviewing }, set: { session.reviewing = $0 })) { approval in
            ApprovalView(approval: approval) { decision in session.decide(approval, decision) }
        }
    }
}

struct StatusRow: View {
    let link: RemoteSession.Link
    var stage = ""

    private var text: String {
        switch link {
        case .unpaired: "Not paired"
        case .connecting: stage.isEmpty ? "Connecting…" : stage
        case .connected(let host): host
        case .offline(let reason): reason
        }
    }
    private var color: Color {
        switch link {
        case .connected: .green
        case .connecting: .yellow
        case .unpaired, .offline: .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption2).lineLimit(2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection: \(text)")
    }
}

struct TalkButton: View {
    let session: RemoteSession

    private var symbol: String {
        switch session.talk {
        case .idle: "mic.fill"
        case .listening: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        }
    }
    private var label: String {
        switch session.talk {
        case .idle: "Talk to Kiln"
        case .listening: "Listening"
        case .thinking: "Kiln is working. Tap to stop"
        case .speaking: "Kiln is speaking. Tap to silence"
        }
    }

    var body: some View {
        Button { Task { await session.talkTapped() } } label: {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .symbolEffect(.pulse, isActive: session.talk != .idle)
                .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 32))
        .tint(session.isConnected ? .orange : .gray)
        .accessibilityLabel(label)
        .accessibilityHint(session.isConnected ? "Dictate a message to Kiln on your Mac" : "Reconnects to your Mac")
    }
}

struct ReplyCaption: View {
    let session: RemoteSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !session.lastHeard.isEmpty {
                Text("You: \(session.lastHeard)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let activity = session.activity {
                Text(activity).font(.caption2).foregroundStyle(.orange).lineLimit(1)
            }
            if !session.latestReply.isEmpty {
                Text(SpokenText.clean(session.latestReply)).font(.footnote).lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.latestReply.isEmpty ? "No reply yet" : "Latest reply: \(SpokenText.clean(session.latestReply))")
    }
}

struct UnpairedView: View {
    let status: String
    let pair: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone.and.arrow.forward").font(.title2).foregroundStyle(.orange)
            Text("Waiting for iPhone to send pairing").font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
            Text(status).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Pair", action: pair)
                .tint(.orange)
                .accessibilityLabel("Pair")
                .accessibilityHint("Asks the iPhone to send the pairing to this watch")
        }
    }
}
