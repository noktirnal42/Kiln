import SwiftUI

/// The project's `.kiln/hooks/hooks.json`, with what each hook does. A hook can only block or annotate; it never grants.
struct HooksPaneView: View {
    @Bindable var session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var message: String?

    private var root: URL? { session.workspaceRoot.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    private var hooks: [HookDefinition] { HookRunner.load(workspaceRoot: root, home: session.memoryHome) }

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            HStack { Text("Hooks").font(SSTypography.headline()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Scripts run before and after tool calls, when you send a message and when a run stops. They receive the event as JSON on stdin. Exit 2 (or {\"decision\":\"deny\"}) blocks; {\"decision\":\"annotate\"} adds a note. A hook can never skip an approval. Every decision is in the audit log.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            if hooks.isEmpty { Text("No hooks configured.").foregroundStyle(.secondary) }
            ForEach(hooks) { hook in
                Text("\(hook.scope ?? "project") · \(hook.event.rawValue)\(hook.match.map { " [\($0)]" } ?? "") → \(hook.command)")
                    .font(.system(size: 11, design: .monospaced))
            }
            Text(".kiln/hooks/hooks.json").font(SSTypography.caption()).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
            HStack {
                if let message { Text(message).font(SSTypography.caption()).foregroundStyle(.secondary) }
                Spacer()
                Button("Save") { Task { do { try await session.saveHooksFile(text); message = "Saved" } catch { message = "Not saved: \(error)" } } }
                    .keyboardShortcut("s", modifiers: .command).disabled(root == nil)
            }
        }
        .padding(SSSpacing.m).frame(width: 680, height: 480)
        .onAppear {
            if let root, let existing = try? String(contentsOf: root.appendingPathComponent(".kiln/hooks/hooks.json"), encoding: .utf8) { text = existing }
            else { text = "{\n  \"hooks\": [\n    {\"event\": \"pre_tool\", \"match\": \"run_command\", \"command\": \".kiln/hooks/check.sh\", \"timeout\": 10}\n  ]\n}\n" }
        }
    }
}
