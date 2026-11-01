import SwiftUI

/// Where you land. It answers "what can I do and what state is everything in" with real data,
/// not marketing: recent conversations, analysis projects, which providers actually work, the
/// hardware you have, and whether the audit record is healthy.
struct HomeView: View {
    @Bindable var workstation: WorkstationModel
    @Environment(AppModel.self) private var app

    @State private var prompt = ""
    @State private var conversations: [ConversationSummary] = []
    @State private var providers: [(id: String, availability: ProviderAvailability)] = []
    @State private var auditEvents: Int?

    private var reModule: REModule? {
        app.records.first { $0.id == REModule.identifier }?.module as? REModule
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SSSpacing.l) {
                hero
                actions
                HStack(alignment: .top, spacing: SSSpacing.m) {
                    conversationsPanel
                    projectsPanel
                }
                HStack(alignment: .top, spacing: SSSpacing.m) {
                    providersPanel
                    systemPanel
                }
            }
            .padding(SSSpacing.l)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await load() }
    }

    // MARK: Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            Text("Kiln").font(SSTypography.display())
            Text("An agentic workstation for development, analysis and model work.")
                .font(SSTypography.body()).foregroundStyle(.secondary)
            HStack(spacing: SSSpacing.s) {
                Image(systemName: "sparkles").foregroundStyle(SSColor.accent)
                TextField("Ask the agent…", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit(ask)
                SSKeyCap("⏎")
            }
            .padding(SSSpacing.m)
            .background(SSColor.surface, in: RoundedRectangle(cornerRadius: SSCornerRadius.large))
            .overlay(RoundedRectangle(cornerRadius: SSCornerRadius.large).strokeBorder(SSColor.hairline))
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            SSSectionLabel("Work")
            HStack(alignment: .top, spacing: SSSpacing.m) {
                ForEach(Activity.allCases.filter { $0 != .home }) { activity in
                    Button { workstation.select(activity, app: app) } label: {
                        VStack(alignment: .leading, spacing: SSSpacing.s) {
                            HStack {
                                Image(systemName: activity.symbol)
                                    .font(.system(size: 20)).foregroundStyle(SSColor.accent)
                                Spacer()
                                SSKeyCap("⌘\(activity.shortcutKey)")
                            }
                            Text(activity.title).font(SSTypography.headline())
                            Text(activity.summary)
                                .font(SSTypography.caption()).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                        .ssPanel(padding: SSSpacing.m)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var conversationsPanel: some View {
        panel("Recent conversations", symbol: "bubble.left.and.text.bubble.right") {
            if conversations.isEmpty {
                empty("No conversations yet. Ask the agent something above.")
            } else {
                ForEach(conversations.prefix(5)) { summary in
                    Button {
                        Task {
                            await app.chatSession?.loadConversation(summary.id)
                            workstation.select(.agent, app: app)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(summary.title).font(SSTypography.body()).lineLimit(1)
                            Text("\(summary.messageCount) messages · \(summary.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(SSTypography.caption()).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var projectsPanel: some View {
        panel("Analysis projects", symbol: "magnifyingglass.circle") {
            let projects = reModule?.projects ?? []
            if projects.isEmpty {
                empty("No binaries imported. Open Analyze to import one.")
            } else {
                ForEach(projects.prefix(5)) { project in
                    Button {
                        reModule?.select(projectID: project.id)
                        workstation.select(.analyze, app: app)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.binaryURL.lastPathComponent).font(SSTypography.body())
                                Text(project.analysis?.format.prefix(60).description ?? "not analyzed")
                                    .font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let count = project.analysis?.functions.count {
                                SSBadge(text: "\(count) fn", tint: .secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var providersPanel: some View {
        panel("Model providers", symbol: "cpu") {
            if providers.isEmpty {
                empty("Checking providers…")
            } else {
                ForEach(providers, id: \.id) { provider in
                    HStack(spacing: SSSpacing.s) {
                        SSStatusDot(color: provider.availability.isAvailable ? SSColor.success : .secondary)
                        Text(provider.id).font(SSTypography.body())
                        Spacer()
                        if let reason = provider.availability.reason, !provider.availability.isAvailable {
                            Text(reason).font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(1)
                                .help(reason)
                        } else {
                            Text("ready").font(SSTypography.caption()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var systemPanel: some View {
        let hardware = HardwareProfile.current()
        return panel("This machine", symbol: "desktopcomputer") {
            row("Chip", hardware.metalDeviceName ?? (hardware.isAppleSilicon ? "Apple silicon" : "Intel"))
            row("Memory", "\(hardware.memoryGB) GB unified")
            row("Cores", "\(hardware.coreCount)")
            Divider()
            Button { workstation.select(.audit, app: app) } label: {
                HStack {
                    Text("Audit record").font(SSTypography.body())
                    Spacer()
                    Text(auditEvents.map { "\($0) events" } ?? (app.auditChain == nil ? "off" : "…"))
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Pieces

    private func panel<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            Label(title, systemImage: symbol).font(SSTypography.headline())
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .ssPanel()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(SSTypography.body()).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(SSTypography.body()).lineLimit(1)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(SSTypography.caption()).foregroundStyle(.secondary)
    }

    // MARK: Actions

    private func ask() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        workstation.select(.agent, app: app)
        Task { await app.chatSession?.send(text) }
    }

    private func load() async {
        if let session = app.chatSession { conversations = await session.conversations() }
        let map = await app.modelRegistry.availabilityMap()
        providers = map.map { (id: $0.key, availability: $0.value) }.sorted { $0.id < $1.id }
        if let chain = app.auditChain { auditEvents = try? await chain.summary().events }
    }
}
