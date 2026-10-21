import SwiftUI
import AxiomCore

/// Analyst annotations for one function: rename, comment and bookmark, plus
/// project-wide undo/redo. Every change goes through `REModule` with the
/// project's current revision, so a stale view is refused by the engine rather
/// than overwriting an edit made elsewhere.
struct REAnnotationControls: View {
    let module: REModule
    let projectID: String
    let analysis: Analysis
    let function: FunctionRecord

    @State private var name = ""
    @State private var comment = ""
    @State private var status: String?
    @State private var isBusy = false

    private var isBookmarked: Bool {
        (analysis.bookmarks ?? []).contains { $0.lowercased() == function.address.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                TextField("Comment", text: $comment)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            HStack {
                Button("Save") { Task { await save() } }
                    .disabled(isBusy || !hasChanges)
                Toggle("Bookmark", isOn: Binding(
                    get: { isBookmarked },
                    set: { _ in Task { await toggleBookmark() } }
                ))
                .toggleStyle(.checkbox)
                .disabled(isBusy)
                Spacer()
                Button { Task { await undo() } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(isBusy || (analysis.edits ?? []).isEmpty)
                Button { Task { await redo() } } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(isBusy || (analysis.undone ?? []).isEmpty)
            }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.hasPrefix("Saved") || status.hasPrefix("Done") ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }
        }
        .onAppear(perform: resetFields)
        .onChange(of: function.address) { _, _ in resetFields() }
        .onChange(of: function.name) { _, _ in resetFields() }
        .onChange(of: function.comment) { _, _ in resetFields() }
    }

    private var hasChanges: Bool {
        name.trimmingCharacters(in: .whitespaces) != function.name
            || comment != function.comment
    }

    private func resetFields() {
        name = function.name
        comment = function.comment
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            status = "A function needs a name."
            return
        }
        await perform("Saved") {
            try await module.editProject(
                projectID: projectID,
                expectedRevision: analysis.revision,
                operations: [.function(
                    address: function.address,
                    name: trimmed == function.name ? nil : trimmed,
                    comment: comment == function.comment ? nil : comment,
                    signature: nil
                )]
            )
        }
    }

    private func toggleBookmark() async {
        await perform("Done") {
            try await module.toggleBookmark(projectID: projectID, expectedRevision: analysis.revision,
                                            address: function.address)
        }
    }

    private func undo() async {
        await perform("Undone") {
            try await module.undo(projectID: projectID, expectedRevision: analysis.revision)
        }
    }

    private func redo() async {
        await perform("Redone") {
            try await module.redo(projectID: projectID, expectedRevision: analysis.revision)
        }
    }

    private func perform(_ success: String, _ work: () async throws -> Analysis) async {
        isBusy = true
        status = nil
        defer { isBusy = false }
        do {
            _ = try await work()
            status = success
        } catch {
            // Stale-revision refusals arrive here too; the view re-renders from the stored project.
            status = error.localizedDescription
        }
    }
}
