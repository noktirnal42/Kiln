import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @State private var showApprovals = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            ModuleHostView()
        }
        .frame(minWidth: 960, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showApprovals = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield")
                        let pending = app.approvalCenter.pending.count
                        if pending > 0 {
                            Text("\(pending)")
                                .font(SSTypography.caption())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(SSColor.accent, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .help(pendingHelp)
            }
        }
        .sheet(isPresented: approvalsBinding) {
            ApprovalQueueView(center: app.approvalCenter)
        }
    }

    private var pendingHelp: String {
        let pending = app.approvalCenter.pending.count
        return pending > 0
            ? "\(pending) tool call(s) waiting for approval"
            : "Approval queue and standing grants"
    }

    /// Opens the sheet when the user asks for it AND whenever an approval
    /// lands — a request awaiting a human is the one thing that should
    /// interrupt, not wait to be discovered.
    private var approvalsBinding: Binding<Bool> {
        Binding(
            get: { showApprovals || !app.approvalCenter.pending.isEmpty },
            set: { showApprovals = $0 }
        )
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: String?

    var body: some View {
        @Bindable var app = app
        List(selection: $selection) {
            Section("Modules") {
                ForEach(app.records) { record in
                    ModuleRow(record: record)
                        .tag(record.id)
                }
            }
            Section("Event Bus") {
                if app.busEntries.isEmpty {
                    Text("No events yet").font(SSTypography.caption()).foregroundStyle(.secondary)
                }
                ForEach(app.busEntries.suffix(30).reversed()) { entry in
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
