import SwiftUI

/// Suggested first messages, chosen by where you are and whether there is a project. They are what makes the one
/// agent the way into every tool: the same conversation, with a different thing to ask about.
enum StarterPrompts {
    typealias Prompt = StarterPrompt

    /// Prompts for a place, from the registry: each module declares its own.
    static func prompts(for activity: Activity, hasProject: Bool) -> [Prompt] {
        activity.descriptor.starterPrompts(hasProject)
    }

    // Shared prompts the activities draw on.

    static func project(_ hasProject: Bool) -> [Prompt] {
        hasProject ? [
            Prompt(title: "Explain this project", symbol: "doc.text.magnifyingglass",
                   text: "Look through this project and explain what it does and how it is organised."),
            Prompt(title: "Fix the failing tests", symbol: "checkmark.seal",
                   text: "Run the tests in this project. If any fail, find the cause, fix it, and run them again to confirm."),
            Prompt(title: "Review recent changes", symbol: "arrow.triangle.branch",
                   text: "Check the git status and diff, then review the changes for bugs and unfinished work."),
        ] : []
    }

    static let binary = Prompt(title: "Analyze a binary", symbol: "magnifyingglass.circle",
                               text: "Use the reverse engineering tools to import the binary at the path I give you, then summarise its format, architectures, interesting strings and any crypto constants. Path: ")
    static let hardware = Prompt(title: "What can my Mac run?", symbol: "cpu",
                                 text: "Check this Mac's hardware and tell me which models I can comfortably run and fine-tune here.")
    static let datasets = Prompt(title: "Review my datasets", symbol: "tablecells",
                                 text: "List my Model Lab datasets and experiments and tell me what is worth doing next.")
}

/// The starter prompts as buttons that fill the message box (they never send on their own).
struct StarterPromptList: View {
    let session: ChatSession
    let activity: Activity
    var compact = false

    var body: some View {
        let prompts = StarterPrompts.prompts(for: activity, hasProject: session.workspaceRoot != nil)
        VStack(spacing: compact ? 4 : SSSpacing.xs) {
            ForEach(prompts.prefix(compact ? 3 : 5)) { prompt in
                Button { session.draft = prompt.text } label: {
                    HStack(spacing: SSSpacing.s) {
                        Image(systemName: prompt.symbol).frame(width: 18).foregroundStyle(SSColor.accent)
                        Text(prompt.title).font(.system(size: compact ? 12 : 13))
                        Spacer()
                    }
                    .padding(.horizontal, SSSpacing.m).padding(.vertical, compact ? 6 : 8)
                    .frame(maxWidth: compact ? .infinity : 360)
                    .background(SSColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
