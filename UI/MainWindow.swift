import SwiftUI

/// The workstation shell: activity rail, the active activity, the agent dock, a status bar, and a
/// command palette over everything.
struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @State private var workstation = WorkstationModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ActivityRail(workstation: workstation)
                Divider()
                activityContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SSColor.canvas)
                if workstation.dockShown, let session = app.chatSession {
                    Divider()
                    AgentDockView(session: session, context: workstation.selected, workstation: workstation)
                }
            }
            StatusBar(workstation: workstation)
        }
        .frame(minWidth: 1020, minHeight: 640)
        .background(SSColor.canvas)
        .tint(SSColor.accent)
        .navigationTitle("Kiln — \(workstation.selected.title)")
        .overlay { paletteOverlay }
        .background { shortcuts }
        .sheet(isPresented: approvalsBinding) {
            ApprovalQueueView(center: app.approvalCenter)
        }
        .sheet(isPresented: $workstation.showModules) {
            VStack(spacing: 0) {
                HStack {
                    Text("Modules").font(SSTypography.headline())
                    Spacer()
                    Button("Done") { workstation.showModules = false }.keyboardShortcut(.cancelAction)
                }
                .padding(SSSpacing.m)
                Divider()
                SidebarView().frame(minWidth: 380, minHeight: 480)
            }
        }
    }

    @ViewBuilder
    private var activityContent: some View {
        switch workstation.selected {
        case .home: HomeView(workstation: workstation)
        case .swarm: SwarmView()
        case .develop: DevelopView()
        case .audit: AuditActivityView()
        case .agent, .analyze, .lab:
            if let identifier = workstation.selected.moduleIdentifier {
                ModuleActivityView(identifier: identifier)
            }
        }
    }

    @ViewBuilder
    private var paletteOverlay: some View {
        if workstation.showPalette {
            ZStack(alignment: .top) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { workstation.showPalette = false }
                CommandPaletteView(commands: workstation.commands(app: app)) { workstation.showPalette = false }
                    .padding(.top, 90)
            }
            .transition(.opacity)
        }
    }

    /// Window-wide shortcuts that have no visible button of their own.
    private var shortcuts: some View {
        Group {
            Button("Command Palette") { workstation.showPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Toggle Agent Dock") { workstation.toggleDock() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("New Conversation") { Task { await app.chatSession?.newConversation() } }
                .keyboardShortcut("n", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Opens the sheet when asked AND whenever an approval lands: a request awaiting a human is the
    /// one thing that should interrupt, not wait to be discovered.
    private var approvalsBinding: Binding<Bool> {
        Binding(
            get: { workstation.showApprovals || !app.approvalCenter.pending.isEmpty },
            set: { workstation.showApprovals = $0 }
        )
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: String?
    /// Lifecycle events fire on every module transition and drown out real activity, so they are hidden by default.
    @State private var showLifecycle = false

    /// Filters the feed. `module.lifecycle` is the only noisy type today; add others here if they need hiding.
    static func visibleBusEntries(_ entries: [BusEntry], showLifecycle: Bool) -> [BusEntry] {
        showLifecycle ? entries : entries.filter { $0.eventType != "module.lifecycle" }
    }

    var body: some View {
        @Bindable var app = app
        List(selection: $selection) {
            Section("Modules") {
                ForEach(app.records) { record in
                    ModuleRow(record: record)
                        .tag(record.id)
                }
            }
            Section {
                let entries = Self.visibleBusEntries(app.busEntries, showLifecycle: showLifecycle)
                if entries.isEmpty {
                    Text("No events yet").font(SSTypography.caption()).foregroundStyle(.secondary)
                }
                ForEach(entries.suffix(30).reversed()) { entry in
                    HStack(alignment: .top, spacing: SSSpacing.s) {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(SSColor.accent)
                            .font(SSTypography.caption())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.eventType)
                                .font(SSTypography.body())
                            Text("\(entry.sourceModule) · \(entry.timestamp.formatted(date: .omitted, time: .standard))")
                                .font(SSTypography.caption())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Event Bus")
                    Spacer()
                    Toggle("Lifecycle", isOn: $showLifecycle)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(SSTypography.caption())
                        .help("Show module lifecycle events, which are hidden by default")
                }
            }
        }
        .navigationTitle("Kiln")
        .safeAreaInset(edge: .top, spacing: 0) {
            BrandHeader()
        }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { return }
            Task { await app.activateModule(newValue) }
        }
    }
}

/// Sidebar masthead: the Kiln mark and wordmark.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: SSSpacing.s) {
            Image("KilnMark")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("Kiln")
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.vertical, SSSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

struct ModuleRow: View {
    let record: ModuleRecord

    var body: some View {
        HStack(spacing: SSSpacing.s) {
            Image(systemName: record.manifest.icon ?? "puzzlepiece.extension")
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.manifest.displayName)
                    .font(SSTypography.body())
                Text(record.phase.label)
                    .font(SSTypography.caption())
                    .foregroundStyle(phaseColor)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var phaseColor: Color {
        switch record.phase {
        case .activated: return SSColor.success
        case .initialized: return SSColor.accent
        case .failed: return SSColor.danger
        case .discovered, .validated: return .secondary
        }
    }
}

struct ModuleHostView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let error = app.bootstrapError {
            ContentUnavailableView {
                Label("Store Unavailable", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(error)
            }
        } else if let ui = app.activeModuleUI {
            VStack(spacing: 0) {
                header
                Divider()
                ui.makeRootView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView {
                Label("No Module Selected", systemImage: "square.grid.2x2")
            } description: {
                Text("Select a module in the sidebar to activate it.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: SSSpacing.s) {
            if let record = app.activeRecord {
                Image(systemName: record.manifest.icon ?? "puzzlepiece.extension")
                Text(record.manifest.displayName).font(SSTypography.headline())
                Text("v\(record.manifest.version)").font(SSTypography.caption()).foregroundStyle(.secondary)
                Text(record.phase.label).font(SSTypography.caption()).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.vertical, SSSpacing.s)
    }
}
