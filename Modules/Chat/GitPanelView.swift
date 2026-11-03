import SwiftUI

@MainActor
@Observable
public final class GitPanelModel {
    public private(set) var repositoryPath: String?
    public private(set) var statuses: [GitFileStatus] = []
    public private(set) var diffText = ""
    public private(set) var log: [GitCommitInfo] = []
    public private(set) var currentBranch = ""
    public var selectedTab = "status"
    public private(set) var errorText: String?
    public var commitMessage = ""

    private let service: GitService

    public init(service: GitService) {
        self.service = service
    }

    /// `quiet` is for opening the project folder automatically: a project that is not a repository is not an error.
    public func openRepository(at path: String, quiet: Bool = false) async {
        guard await service.isRepository(path) else {
            if !quiet { errorText = "'\(path)' is not a Git repository." }
            return
        }
        repositoryPath = path
        errorText = nil
        await refresh()
    }

    public func refresh() async {
        guard let repositoryPath else { return }
        do {
            statuses = try await service.status(repositoryPath)
            diffText = try await service.diff(repositoryPath, staged: false)
            log = try await service.log(repositoryPath)
            currentBranch = (try await service.branches(repositoryPath)).current
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }

    public func stage(_ paths: [String]) async {
        guard let repositoryPath else { return }
        do {
            try await service.stage(repositoryPath, paths: paths)
            await refresh()
        } catch {
            errorText = String(describing: error)
        }
    }

    public func commit() async {
        guard let repositoryPath else { return }
        do {
            _ = try await service.commit(repositoryPath, message: commitMessage)
            commitMessage = ""
            await refresh()
        } catch {
            errorText = String(describing: error)
        }
    }
}

struct GitPanelView: View {
    @Bindable var model: GitPanelModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Git").font(SSTypography.title())
                    if let path = model.repositoryPath {
                        Text("\(path) · \(model.currentBranch)")
                            .font(SSTypography.caption())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                Button("Open Repo…") { openRepo() }
            }
            .padding(SSSpacing.m)
            Divider()
            if let error = model.errorText {
                Text(error).font(SSTypography.caption()).foregroundStyle(SSColor.danger).padding(SSSpacing.s)
                Divider()
            }
            Picker("", selection: Binding(get: { model.selectedTab }, set: { model.selectedTab = $0 })) {
                Text("Status (\(model.statuses.count))").tag("status")
                Text("Diff").tag("diff")
                Text("History (\(model.log.count))").tag("log")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, SSSpacing.m)
            .padding(.vertical, SSSpacing.s)
            switch model.selectedTab {
            case "diff":
                ScrollView {
                    Text(model.diffText.isEmpty ? "No unstaged changes." : model.diffText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SSSpacing.m)
                }
            case "log":
                List(model.log) { commit in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(commit.hash).font(SSTypography.mono(11)).foregroundStyle(SSColor.accent)
                            Text(commit.author).font(SSTypography.caption()).foregroundStyle(.secondary)
                            Spacer()
                            if let date = commit.date {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(SSTypography.caption())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text(commit.subject).font(SSTypography.body())
                    }
                }
            default:
                statusList
            }
            Divider()
            commitBox
        }
        .frame(minWidth: 720, minHeight: 520)
        .task { await model.refresh() }
    }

    @Environment(\.dismiss) private var dismiss

    private var statusList: some View {
        List(model.statuses) { entry in
            HStack {
                Text(entry.statusCode)
                    .font(SSTypography.mono(11))
                    .foregroundStyle(entry.staged ? SSColor.success : SSColor.warning)
                    .frame(width: 24)
                Text(entry.path).font(SSTypography.mono(12))
                Spacer()
                Text(entry.label).font(SSTypography.caption()).foregroundStyle(.secondary)
                Button("Stage") {
                    Task { await model.stage([entry.path]) }
                }
                .controlSize(.small)
            }
        }
    }

    private var commitBox: some View {
        HStack(alignment: .bottom, spacing: SSSpacing.s) {
            TextField("Commit message", text: $model.commitMessage)
                .textFieldStyle(.roundedBorder)
            Button("Commit") {
                Task { await model.commit() }
            }
            .disabled(model.commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(SSSpacing.m)
    }

    private func openRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.openRepository(at: url.path) }
    }
}

/// Inline git diff attachment for chat messages (read-only rendering of a
/// unified diff with +/- coloring).
struct DiffPreviewView: View {
    let diff: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.split(separator: "\n").prefix(200).enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(color(for: String(line)))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(SSSpacing.s)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: SSCornerRadius.small).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") { return SSColor.success }
        if line.hasPrefix("-") { return SSColor.danger }
        if line.hasPrefix("@@") { return SSColor.accent }
        return .primary
    }
}
