import SwiftUI

/// Gate B's human surface: every tool call the policy paused for a human.
///
/// Each request shows the tool, its permission tier, the exact call as a
/// preview, and the consequences spelled out — not just the tool's name —
/// so the answer is an informed one. Standing "always allow" grants are
/// listed and revocable here too.
struct ApprovalQueueView: View {
    @MainActor
    @ObservedObject var center: ApprovalCenter

    @State private var showGrants = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if center.pending.isEmpty {
                emptyState
            } else {
                pendingList
            }
            Divider()
            // With nothing waiting, the open grants list gets the sheet; with requests waiting it stays a short strip under them.
            grantsSection
                .frame(maxHeight: showGrants ? (center.pending.isEmpty ? .infinity : 220) : nil)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 520)
        .background(SSColor.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: SSSpacing.s) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(SSColor.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Approvals and Permissions")
                    .font(SSTypography.headline())
                Text(center.pending.isEmpty
                     ? "Nothing is waiting on you"
                     : "\(center.pending.count) tool call(s) waiting on you")
                    .font(SSTypography.caption())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(SSSpacing.m)
    }

    // MARK: Pending

    private var pendingList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SSSpacing.m) {
                ForEach(center.pending) { request in
                    ApprovalRequestRow(center: center, request: request)
                }
            }
            .padding(SSSpacing.m)
        }
    }

    private var emptyState: some View {
        VStack(spacing: SSSpacing.s) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 28))
                .foregroundStyle(SSColor.success)
            Text("No approvals waiting")
                .font(SSTypography.body())
            Text("When an agent's tool call needs a human, it appears here and holds until you answer.")
                .font(SSTypography.caption())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: showGrants ? 130 : .infinity)
        .padding(SSSpacing.m)
        .accessibilityElement(children: .combine)
    }

    // MARK: Grants

    private var grantsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showGrants.toggle()
            } label: {
                HStack(spacing: SSSpacing.s) {
                    Image(systemName: showGrants ? "chevron.down" : "chevron.right")
                        .font(SSTypography.caption())
                        .foregroundStyle(.secondary)
                    Text("Standing grants")
                        .font(SSTypography.body())
                    Spacer()
                    Text("\(center.grants.all().count)")
                        .font(SSTypography.caption())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, SSSpacing.m)
            .padding(.vertical, SSSpacing.s)
            .help("What you answered “Always Allow” to. Each one can be revoked.")
            .accessibilityLabel("Standing grants, \(center.grants.all().count)")
            .accessibilityHint(showGrants ? "Collapses the list" : "Expands the list")

            if showGrants {
                ScrollView { GrantList(center: center) }
            }
        }
    }
}

// MARK: - One request

private struct ApprovalRequestRow: View {
    @MainActor
    let center: ApprovalCenter
    let request: ApprovalRequest

    @State private var showFullPreview = false
    @Environment(AppModel.self) private var app

    /// A held read or write outside the workspace can be allowed and the folder added as a project in one step.
    private var folderToOffer: URL? {
        guard request.isMonitorReview else { return nil }
        let root = app.chatSession?.workspaceRoot.map { URL(fileURLWithPath: $0) }
        return Tripwires.folderToOffer(tool: request.toolName, argumentsJSON: request.argumentsJSON, workspaceRoot: root)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            HStack(spacing: SSSpacing.s) {
                Image(systemName: request.isMonitorReview ? "exclamationmark.shield.fill" : request.permission.symbolName)
                    .foregroundStyle(request.isMonitorReview ? SSColor.danger
                                     : (request.permission == .read ? SSColor.success : SSColor.accent))
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.toolName)
                        .font(SSTypography.headline())
                    Text(request.isMonitorReview && !["computer_use", "mcp_call_tool"].contains(request.toolName)
                         ? "Held by the behavior monitor · \(request.toolSummary)"
                         : "\(request.permission.displayName) access · \(request.toolSummary)")
                        .font(SSTypography.caption())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if request.isDestructive {
                    Label("Destructive", systemImage: "exclamationmark.triangle.fill")
                        .font(SSTypography.caption())
                        .foregroundStyle(SSColor.danger)
                }
            }

            if !request.consequences.isEmpty {
                Text(request.consequences)
                    .font(SSTypography.caption())
                    .foregroundStyle(request.isDestructive ? SSColor.danger : .primary)
                    .padding(SSSpacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (request.isDestructive ? SSColor.danger : SSColor.accent).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
            }

            if !request.preview.isEmpty {
                ScrollView {
                    Text(showFullPreview ? request.preview : String(request.preview.prefix(600)))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: showFullPreview ? 260 : 90)
                .padding(SSSpacing.xs)
                .background(SSColor.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            }

            if request.preview.count > 600 {
                Button(showFullPreview ? "Show less" : "Show more") {
                    showFullPreview.toggle()
                }
                .font(SSTypography.caption())
                .buttonStyle(.borderless)
            }

            HStack(spacing: SSSpacing.s) {
                Button(role: .destructive) {
                    center.resolve(request.id, decision: .deny)
                } label: {
                    Text("Deny")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Button {
                    center.resolve(request.id, decision: .approveOnce)
                } label: {
                    Text(request.isMonitorReview ? "Allow This Call" : "Approve Once")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                // A monitor review asks about one specific call and can never become a standing permission.
                if !request.isMonitorReview {
                    Button {
                        center.resolve(request.id, decision: .alwaysAllow)
                    } label: {
                        Text("Always Allow")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .help(request.grantValue.map { "Remember this for '\($0)' — revocable under Standing Grants" }
                          ?? "Remember this tool — revocable under Standing Grants")
                }
            }
            .buttonStyle(.bordered)

            if let folder = folderToOffer {
                Button {
                    app.chatSession?.setWorkspace(folder)
                    center.resolve(request.id, decision: .approveOnce)
                } label: {
                    Text("Allow and add \(folder.lastPathComponent) as a project").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .help("Allows this call once, then makes \(folder.path) the project folder so later calls there are inside the workspace")
            }
        }
        .padding(SSSpacing.m)
        .background(SSColor.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(request.isDestructive ? SSColor.danger.opacity(0.5) : SSColor.accent.opacity(0.25))
        )
    }
}

// MARK: - Grants management

private struct GrantList: View {
    @MainActor
    let center: ApprovalCenter
    @State private var confirmRevokeAll = false

    var body: some View {
        let grants = center.grants.all().sorted { $0.createdAt < $1.createdAt }
        Group {
            if grants.isEmpty {
                Text("No standing grants. \"Always Allow\" answers appear here and stay revocable.")
                    .font(SSTypography.caption())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, SSSpacing.m)
                    .padding(.bottom, SSSpacing.s)
            } else {
                VStack(spacing: 0) {
                    ForEach(grants) { grant in
                        GrantRow(center: center, grant: grant)
                        Divider().padding(.leading, SSSpacing.m)
                    }
                    Button("Revoke All…", role: .destructive) { confirmRevokeAll = true }
                    .confirmationDialog("Revoke all \(grants.count) standing grants?", isPresented: $confirmRevokeAll) {
                        Button("Revoke All", role: .destructive) { center.grants.revokeAll() }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("The agent will ask again before using these tools, commands and hosts.") }
                    .font(SSTypography.caption())
                    .buttonStyle(.borderless)
                    .padding(.horizontal, SSSpacing.m)
                    .padding(.vertical, SSSpacing.s)
                }
            }
        }
    }
}

private struct GrantRow: View {
    @MainActor
    let center: ApprovalCenter
    let grant: AgentGrant

    var body: some View {
        HStack(spacing: SSSpacing.s) {
            Image(systemName: kindSymbol)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(grant.value)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(kindLabel) · since \(grant.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(SSTypography.caption())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive) {
                center.grants.revoke(id: grant.id)
            }
            .font(SSTypography.caption())
            .buttonStyle(.borderless)
            .accessibilityLabel("Revoke \(kindLabel) \(grant.value)")
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.vertical, SSSpacing.s)
        .help(grant.value)
    }

    private var kindSymbol: String {
        switch grant.kind {
        case .tool: return "wrench.and.screwdriver"
        case .egressHost: return "network"
        case .shellCommand: return "terminal"
        }
    }

    private var kindLabel: String {
        switch grant.kind {
        case .tool: return "tool"
        case .egressHost: return "host"
        case .shellCommand: return "command"
        }
    }
}
