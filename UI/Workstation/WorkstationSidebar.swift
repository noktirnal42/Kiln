import SwiftUI
import AppKit

/// The one sidebar: where you are working (the project), what you have talked about (chat history), and the
/// tools that share that conversation. It replaces an icon rail whose entries each opened a separate screen.
struct WorkstationSidebar: View {
    @Bindable var workstation: WorkstationModel
    @Environment(AppModel.self) private var app
    @State private var history = ChatHistoryModel()

    private struct RefreshKey: Hashable {
        var conversation: UUID?
        var messages: Int
        var title: String
        var streaming: Bool
        var listGeneration: Int
    }

    private var refreshKey: RefreshKey {
        let session = app.chatSession
        return RefreshKey(conversation: session?.conversationID, messages: session?.messages.count ?? 0,
                          title: session?.conversationTitle ?? "", streaming: session?.isStreaming ?? false,
                          listGeneration: session?.conversationListGeneration ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: SSSpacing.m) {
                newChat
                scheduledTasks
                ProjectSwitcher()
            }
            .padding(.horizontal, SSSpacing.s)
            .padding(.bottom, SSSpacing.m)
            ScrollView {
                VStack(alignment: .leading, spacing: SSSpacing.m) { chats }
                    .padding(.horizontal, SSSpacing.s)
                    .padding(.bottom, SSSpacing.m)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: 244)
        .background(SSColor.surface)
        .task(id: refreshKey) { if let session = app.chatSession { await history.refresh(session) } }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: SSSpacing.s) {
            Button { workstation.select(.home, app: app) } label: {
                HStack(spacing: SSSpacing.s) {
                    Image("KilnMark").resizable().scaledToFit().frame(width: 22, height: 22)
                    Text("Kiln").font(.system(size: 15, weight: .bold, design: .rounded))
                }
            }
            .buttonStyle(.plain)
            .help("Overview")
            Spacer()
            Button { workstation.showPalette = true } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26)
            }
            .buttonStyle(SSIconButtonStyle())
            .help("Search and commands (⌘K)")
            .accessibilityLabel("Search and commands")
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.top, SSSpacing.m)
        .padding(.bottom, SSSpacing.s)
    }

    private var newChat: some View {
        Button {
            Task { await app.chatSession?.newConversation() }
            workstation.select(.agent, app: app)
        } label: {
            Label("New chat", systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SSSpacing.s).padding(.vertical, 7)
                .background(SSColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Start a new conversation (⌘N)")
    }

    private var scheduledTasks: some View {
        Button {
            workstation.select(.agent, app: app)
            app.chatSession?.requestedPane = .schedules
        } label: {
            Label("Scheduled tasks", systemImage: "calendar.badge.clock")
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SSSpacing.s).padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("View and manage scheduled tasks")
        .disabled(app.chatSession == nil)
    }

    @ViewBuilder
    private var chats: some View {
        let groups = HistoryGrouping.group(history.items, openID: app.chatSession?.conversationID)
        if groups.isEmpty {
            Text("Your conversations will appear here.")
                .font(SSTypography.caption()).foregroundStyle(.tertiary)
                .padding(.horizontal, SSSpacing.s)
        }
        ForEach(groups, id: \.bucket) { group in
            VStack(alignment: .leading, spacing: 2) {
                SSSectionLabel(group.bucket.title).padding(.horizontal, SSSpacing.s).padding(.bottom, 2)
                ForEach(group.items) { item in chatRow(item) }
            }
        }
    }

    private func chatRow(_ item: ConversationSummary) -> some View {
        let selected = workstation.selected == .agent && app.chatSession?.conversationID == item.id
        return Button {
            Task { await app.chatSession?.loadConversation(item.id) }
            workstation.select(.agent, app: app)
        } label: {
            Text(item.title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SSSpacing.s).padding(.vertical, 6)
                .background(selected ? SSColor.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(selected ? Color.primary : .secondary)
                .contentShape(Rectangle())   // the whole row is the target, not just the title text
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Delete", role: .destructive) { Task { await app.chatSession?.deleteConversation(item.id) } }
        }
    }

    private var footer: some View {
        let pending = app.approvalCenter.pending.count
        return HStack(spacing: SSSpacing.xs) {
            Button { workstation.showApprovals = true } label: {
                Image(systemName: pending > 0 ? "exclamationmark.shield.fill" : "checkmark.shield")
                    .frame(width: 28, height: 26)
                    .overlay(alignment: .topTrailing) {
                        if pending > 0 {
                            Text("\(pending)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4).background(SSColor.accent, in: Capsule()).offset(x: 2, y: -2)
                        }
                    }
            }
            .buttonStyle(SSIconButtonStyle(selected: pending > 0))
            .help(pending > 0 ? "\(pending) tool call(s) waiting for you" : "Approvals and standing grants")
            .accessibilityLabel(pending > 0 ? "Approvals, \(pending) waiting" : "Approvals and standing grants")
            SettingsLink { Image(systemName: "gearshape").frame(width: 28, height: 26) }
                .buttonStyle(SSIconButtonStyle())
                .help("Settings and API keys (⌘,)")
                .accessibilityLabel("Settings")
            Spacer()
            Button { workstation.toggleDock() } label: {
                Image(systemName: "sidebar.right").frame(width: 28, height: 26)
            }
            .buttonStyle(SSIconButtonStyle(selected: workstation.dockVisible))
            .help(workstation.dockVisible ? "Hide the agent panel (⌘⌥A)" : "Show the agent panel (⌘⌥A)")
            .accessibilityLabel(workstation.dockVisible ? "Hide agent panel" : "Show agent panel")
        }
        .padding(.horizontal, SSSpacing.s).padding(.vertical, SSSpacing.s)
    }
}

/// The current project: the folder the agent works in. Always visible, because it decides what the agent can see.
struct ProjectSwitcher: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let session = app.chatSession
        let current = session?.workspaceRoot
        return Menu {
            ForEach(WorkspaceStore.shared.recents()) { entry in
                Button { session?.openRecentWorkspace(entry) } label: {
                    Label(entry.name, systemImage: entry.path == current ? "checkmark" : "folder")
                }
            }
            if !WorkspaceStore.shared.recents().isEmpty { Divider() }
            Button("Choose Folder…") { choose() }
            if current != nil { Button("Work without a project") { session?.setWorkspace(nil) } }
        } label: {
            HStack(spacing: SSSpacing.s) {
                Image(systemName: current == nil ? "folder.badge.plus" : "folder.fill")
                    .foregroundStyle(current == nil ? Color.secondary : SSColor.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(current.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose a project")
                        .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(current == nil ? "The agent can't read files yet" : "Agent works in this folder")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, SSSpacing.s).padding(.vertical, 6)
            .background(SSColor.canvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SSColor.hairline))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(current ?? "Choose the folder the agent works in")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose the project folder the agent should work in."
        if panel.runModal() == .OK, let url = panel.url { app.chatSession?.setWorkspace(url) }
    }
}
