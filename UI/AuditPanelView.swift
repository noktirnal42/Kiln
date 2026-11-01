import SwiftUI
import UniformTypeIdentifiers

/// Audit & Monitor: the tamper-evident record of what agents did, whether it is intact, whether
/// any entries were lost, and how the behavior monitor is configured. All logic is in
/// `AuditPanelModel`; this view renders it.
struct AuditPanelView: View {
    @State private var model: AuditPanelModel
    @Environment(\.dismiss) private var dismiss
    /// True when shown as an activity rather than a sheet: no Done button, no fixed minimum size.
    private let embedded: Bool

    init(model: AuditPanelModel, embedded: Bool = false) {
        _model = State(initialValue: model)
        self.embedded = embedded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.m) {
            HStack {
                Text("Audit & Monitor").font(SSTypography.headline())
                Spacer()
                if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: SSSpacing.m) {
                    chainCard
                    droppedCard
                    monitorCard
                    eventsCard
                }
            }
        }
        .padding(SSSpacing.m)
        .frame(minWidth: embedded ? 0 : 640, minHeight: embedded ? 0 : 600)
        .task { await model.refresh() }
    }

    // MARK: Cards

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            Text(title).font(SSTypography.headline())
            content()
        }
        .padding(SSSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SSColor.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SSColor.accent.opacity(0.2)))
    }

    private var chainCard: some View {
        card("Audit chain") {
            statusRow
            if let summary = model.summary {
                HStack(spacing: SSSpacing.m) {
                    fact("Events", "\(summary.events)")
                    fact("Head", String(summary.headHash.prefix(12)))
                    if let verifiedAt = model.verifiedAt {
                        fact("Verified", verifiedAt.formatted(date: .omitted, time: .standard))
                    }
                }
            }
            HStack {
                Button("Verify now") { Task { await model.verify() } }
                    .disabled(model.isBusy || !model.hasChain)
                Button("Export…") { chooseExportLocation() }
                    .disabled(model.isBusy || !model.hasChain)
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.isBusy)
            }
            if let status = model.exportStatus {
                Text(status).font(SSTypography.caption()).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).font(SSTypography.caption()).foregroundStyle(SSColor.danger).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        let status = describe(model.chainStatus)
        HStack(alignment: .top, spacing: SSSpacing.s) {
            Image(systemName: status.symbol).foregroundStyle(status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title).font(SSTypography.body()).foregroundStyle(status.color)
                if let detail = status.detail {
                    Text(detail).font(SSTypography.caption()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var droppedCard: some View {
        card("Entries that could not be written") {
            if model.droppedEntries > 0 {
                HStack(alignment: .top, spacing: SSSpacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SSColor.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.droppedEntries) audit entries were lost this session. The trail has gaps.")
                            .font(SSTypography.body()).foregroundStyle(SSColor.danger)
                        if let last = model.lastFailure {
                            Text(last).font(SSTypography.caption()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text("Runs continue when the log cannot be written; verification only covers entries that were.")
                            .font(SSTypography.caption()).foregroundStyle(.secondary)
                    }
                }
            } else {
                Label("None this session", systemImage: "checkmark.circle").font(SSTypography.body())
                    .foregroundStyle(SSColor.success)
            }
        }
    }

    private var monitorCard: some View {
        card("Behavior monitor") {
            Label("Tripwires are on. A tool call that trips one at severity \(model.pauseAtSeverity) or above is held for your review.",
                  systemImage: "shield.lefthalf.filled")
                .font(SSTypography.body())
            Divider()
            Text("Model-based monitoring").font(SSTypography.body())
            HStack {
                TextField("Monitor model (empty = off)", text: $model.rubricModel).textFieldStyle(.roundedBorder)
                TextField("Fallback model (optional)", text: $model.rubricFallbackModel).textFieldStyle(.roundedBorder)
                Button("Save") { Task { await model.saveRubricSettings() } }
            }
            Text("Off by default. When set, a redacted summary of each round is sent to this model: what the agent said and which tools it called, with path, command or URL arguments. File contents, tool results and your prompt are never sent.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            if let status = model.settingsStatus {
                Text(status).font(SSTypography.caption()).foregroundStyle(.secondary)
            }
        }
    }

    private var eventsCard: some View {
        card("Recent events") {
            if model.recentEvents.isEmpty {
                Text("No agent activity recorded yet.").font(SSTypography.caption()).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.recentEvents) { row in
                        HStack(alignment: .firstTextBaseline, spacing: SSSpacing.s) {
                            Text(row.timestamp?.formatted(date: .omitted, time: .standard) ?? "—")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text(row.type)
                                .font(.system(size: 11, weight: row.needsAttention ? .bold : .regular, design: .monospaced))
                                .foregroundStyle(row.needsAttention ? SSColor.danger : .primary)
                                .frame(width: 150, alignment: .leading)
                            Text(row.detail)
                                .font(SSTypography.caption()).foregroundStyle(.secondary)
                                .lineLimit(2).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(SSTypography.caption()).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        }
    }

    // MARK: Status text

    private struct StatusText {
        let symbol: String
        let color: Color
        let title: String
        let detail: String?
    }

    private func describe(_ status: AuditPanelModel.ChainStatus) -> StatusText {
        switch status {
        case .noChain:
            StatusText(symbol: "slash.circle", color: .secondary, title: "No audit log", detail: "Agent runs are not being recorded.")
        case .notVerified:
            StatusText(symbol: "questionmark.circle", color: .secondary, title: "Not verified yet",
                       detail: "Verify now recomputes every hash and compares the head.")
        case .intact(let checked):
            StatusText(symbol: "checkmark.shield.fill", color: SSColor.success, title: "Intact",
                       detail: "\(checked) events verified; the recorded head matches.")
        case .tampered(let seq):
            StatusText(symbol: "xmark.shield.fill", color: SSColor.danger, title: "Tampered",
                       detail: "Event #\(seq) was changed after it was written, or the chain was cut there.")
        case .truncated(let expected):
            StatusText(symbol: "xmark.shield.fill", color: SSColor.danger, title: "Truncated",
                       detail: expected.map { "Events were removed: \($0) were recorded." } ?? "Events were removed from the log.")
        case .unreadable(let line):
            StatusText(symbol: "xmark.shield.fill", color: SSColor.danger, title: "Unreadable",
                       detail: "Line \(line) of the log is not a valid event, so no new entries can be added.")
        }
    }

    // MARK: Export

    private func chooseExportLocation() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "kiln-audit-bundle.json"
        panel.message = "Exports every audit event with its hashes so the chain can be checked elsewhere."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.export(to: url) }
    }
}
