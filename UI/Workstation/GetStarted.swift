import SwiftUI

/// The first-run checklist on Home. Every step is derived from real state, never from a flag the user ticks, so it
/// cannot claim something works that does not. It disappears once the first supervised task has run, or on dismissal.
enum GetStarted {
    enum Step: String, CaseIterable, Identifiable {
        case model, project, firstTask
        var id: String { rawValue }

        var title: String {
            switch self {
            case .model: "Connect a model"
            case .project: "Choose a project folder"
            case .firstTask: "Run a first supervised task"
            }
        }
        var detail: String {
            switch self {
            case .model: "Add a provider key in Settings, or start Ollama for a model that runs on this Mac."
            case .project: "The agent works inside one folder. Anything it wants to do elsewhere waits for your approval."
            case .firstTask: "Ask it to explain the project. Reading is quick, and you will see how approvals look when it wants to change something."
            }
        }
        var symbol: String {
            switch self {
            case .model: "cpu"
            case .project: "folder"
            case .firstTask: "checkmark.shield"
            }
        }
    }

    struct State: Equatable {
        var providerReady: Bool
        var hasProject: Bool
        var hasConversation: Bool
    }

    static func isDone(_ step: Step, _ state: State) -> Bool {
        switch step {
        case .model: state.providerReady
        case .project: state.hasProject
        case .firstTask: state.hasConversation
        }
    }

    /// The step to do next: the first one not yet done, in order. Nil when everything is done.
    static func next(_ state: State) -> Step? { Step.allCases.first { !isDone($0, state) } }

    static func shows(_ state: State, dismissed: Bool) -> Bool { !dismissed && next(state) != nil }
}

struct GetStartedCard: View {
    let state: GetStarted.State
    let chooseProject: () -> Void
    let openSettings: () -> Void
    let runFirstTask: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.m) {
            HStack {
                Label("Get started", systemImage: "flame").font(SSTypography.headline())
                Spacer()
                Button("Dismiss", action: dismiss).buttonStyle(.borderless).font(SSTypography.caption())
                    .help("Hide this checklist")
            }
            ForEach(GetStarted.Step.allCases) { step in
                let done = GetStarted.isDone(step, state)
                let isNext = GetStarted.next(state) == step
                HStack(alignment: .top, spacing: SSSpacing.s) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? SSColor.success : Color.secondary)
                        .accessibilityLabel(done ? "Done" : "Not done")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(SSTypography.body()).fontWeight(isNext ? .semibold : .regular)
                        if isNext { Text(step.detail).font(SSTypography.caption()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer()
                    if isNext {
                        Button(action(for: step).label, action: action(for: step).run).buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .ssPanel(padding: SSSpacing.m)
        .accessibilityElement(children: .contain)
    }

    private func action(for step: GetStarted.Step) -> (label: String, run: () -> Void) {
        switch step {
        case .model: ("Open Settings", openSettings)
        case .project: ("Choose folder…", chooseProject)
        case .firstTask: ("Explain this project", runFirstTask)
        }
    }
}
