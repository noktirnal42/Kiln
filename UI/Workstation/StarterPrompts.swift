import SwiftUI

/// Suggested first messages, chosen by where you are and whether there is a project. They are what makes the one
/// agent the way into every tool: the same conversation, with a different thing to ask about.
enum StarterPrompts {
    struct Prompt: Identifiable, Equatable {
        let title: String
        let symbol: String
        let text: String
        var id: String { title }
    }

    static func prompts(for activity: Activity, hasProject: Bool) -> [Prompt] {
        let project: [Prompt] = hasProject ? [
            Prompt(title: "Explain this project", symbol: "doc.text.magnifyingglass",
                   text: "Look through this project and explain what it does and how it is organised."),
            Prompt(title: "Fix the failing tests", symbol: "checkmark.seal",
                   text: "Run the tests in this project. If any fail, find the cause, fix it, and run them again to confirm."),
            Prompt(title: "Review recent changes", symbol: "arrow.triangle.branch",
                   text: "Check the git status and diff, then review the changes for bugs and unfinished work."),
        ] : []
        let binary = Prompt(title: "Analyze a binary", symbol: "magnifyingglass.circle",
                            text: "Use the reverse engineering tools to import the binary at the path I give you, then summarise its format, architectures, interesting strings and any crypto constants. Path: ")
        let hardware = Prompt(title: "What can my Mac run?", symbol: "cpu",
                              text: "Check this Mac's hardware and tell me which models I can comfortably run and fine-tune here.")
        let datasets = Prompt(title: "Review my datasets", symbol: "tablecells",
                              text: "List my Model Lab datasets and experiments and tell me what is worth doing next.")

        switch activity {
        case .analyze:
            return [binary,
                    Prompt(title: "Find crypto and secrets", symbol: "key",
                           text: "In the binary I have open, scan for crypto constants and embedded keys or tokens and report what you find."),
                    Prompt(title: "Explain the main logic", symbol: "function",
                           text: "Explain what the open binary does at a high level, using its strings and functions as evidence.")]
        case .lab:
            return [hardware, datasets,
                    Prompt(title: "Find a small model", symbol: "magnifyingglass",
                           text: "Search Hugging Face for a small instruction-tuned model that fits this Mac, and compare two good candidates.")]
        case .develop:
            return project.isEmpty ? [hardware] : [project[2], project[1],
                    Prompt(title: "Find TODOs", symbol: "list.bullet",
                           text: "Search this project for TODO and FIXME comments and summarise what is outstanding.")]
        case .swarm:
            return [Prompt(title: "Just ask the agent", symbol: "sparkles",
                           text: "Break this job into steps and do it: ")] + project.prefix(2)
        case .audit:
            return [Prompt(title: "What did agents do?", symbol: "checkmark.shield",
                           text: "Read my recent agent activity and tell me anything that looks risky or surprising.")]
        case .agent, .home:
            return project + [binary, hardware]
        }
    }
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
