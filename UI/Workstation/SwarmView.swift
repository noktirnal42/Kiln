import SwiftUI
import Observation

/// Drives one swarm run: plan the goal, run the tasks, and keep what the UI shows.
@MainActor
@Observable
final class SwarmModel {
    var goal = ""
    private(set) var graph: SwarmGraph?
    private(set) var usedFallback = false
    private(set) var isRunning = false
    private(set) var feed: [CoordinationMessage] = []
    private(set) var note: String?
    private var task: Task<Void, Never>?

    func start(app: AppModel) {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, let base = app.orchestrator, let session = app.chatSession else { return }
        guard !session.selectedModelID.isEmpty else { note = "Pick a model first (Agent activity → model picker)."; return }
        let modelID = session.selectedModelID
        let registry = app.modelRegistry
        let root = session.workspaceRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let recorder = app.auditChain.map { AgentAuditRecorder(chain: $0, health: app.auditHealth) }
        isRunning = true; graph = nil; feed = []; note = nil
        task = Task { [weak self] in
            let bus = CoordinationBus(audit: recorder)
            let observer = Task { [weak self] in
                for await message in await bus.observe() { self?.feed.append(message) }
            }
            let planned = await SwarmPlanner.plan(goal: text) { system, goal in
                try await registry.completeSilently(ChatRequest(
                    messages: [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: goal)],
                    model: modelID, temperature: 0, maxTokens: 1200))
            }
            let swarm = SwarmOrchestrator(bus: bus, worker: SwarmWorkers.agent(
                base: base, modelID: modelID, workspaceRoot: root,
                chat: { request in try await registry.streamChat(request, reasoning: nil) }))
            for await event in swarm.run(goal: text, graph: planned.graph, usedFallback: planned.usedFallback) {
                self?.apply(event)
            }
            observer.cancel()
            await recorder?.finish()
            self?.isRunning = false
        }
    }

    func stop() { task?.cancel(); task = nil; isRunning = false; note = "Stopped." }

    func apply(_ event: SwarmEvent) {
        switch event {
        case .planned(let planned, let fallback): graph = planned; usedFallback = fallback
        case .taskStarted(let id): graph?.update(id) { $0.status = .running }
        case .taskFinished(let id, let summary): graph?.update(id) { $0.status = .done; $0.result = summary }
        case .taskBlocked(let id, let reason): graph?.update(id) { $0.status = .blocked; $0.result = reason }
        case .finished(let final): graph = final
        }
    }
}

struct SwarmView: View {
    @Environment(AppModel.self) private var app
    @State private var model = SwarmModel()

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.m) {
            VStack(alignment: .leading, spacing: SSSpacing.xs) {
                Text("Swarm").font(SSTypography.title())
                Text("Give the team a goal. Kiln splits it into tasks, runs independent ones in parallel, and stops at anything that needs you. Writes, commands and network calls still ask for approval.")
                    .font(SSTypography.caption()).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: SSSpacing.s) {
                TextField("Goal, e.g. “Find where the app stores API keys and list any that are not in the Keychain”",
                          text: $model.goal, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder)
                    .onSubmit { model.start(app: app) }
                if model.isRunning {
                    Button("Stop") { model.stop() }
                } else {
                    Button("Run") { model.start(app: app) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let note = model.note { Text(note).font(SSTypography.caption()).foregroundStyle(SSColor.warning) }
            if let graph = model.graph {
                if model.usedFallback {
                    Text("The model did not return a usable plan, so a standard research → implement → review plan is being used.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                }
                HSplitView {
                    taskList(graph).frame(minWidth: 320)
                    feed.frame(minWidth: 280)
                }
            } else if !model.isRunning {
                SSEmptyState(symbol: "person.3.sequence", title: "No swarm running",
                             message: "Describe what you want done. Researchers read, implementers change things, reviewers check.")
            } else {
                ProgressView("Planning…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(SSSpacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func taskList(_ graph: SwarmGraph) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SSSpacing.s) {
                ForEach(graph.tasks) { task in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: SSSpacing.xs) {
                            SSStatusDot(color: color(task.status), pulsing: task.status == .running)
                            Text(task.title).font(SSTypography.headline())
                            SSBadge(text: task.role.rawValue)
                            Spacer()
                            Text(task.status.rawValue).font(SSTypography.caption()).foregroundStyle(color(task.status))
                        }
                        if !task.dependsOn.isEmpty {
                            Text("after \(task.dependsOn.joined(separator: ", "))").font(SSTypography.caption()).foregroundStyle(.tertiary)
                        }
                        if let result = task.result {
                            Text(String(result.prefix(400))).font(SSTypography.caption()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(SSSpacing.s).frame(maxWidth: .infinity, alignment: .leading).ssPanel()
                }
            }
        }
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                SSSectionLabel("Team channel")
                if model.feed.isEmpty { Text("Nothing posted yet.").font(SSTypography.caption()).foregroundStyle(.tertiary) }
                ForEach(model.feed.suffix(80)) { message in
                    HStack(alignment: .firstTextBaseline, spacing: SSSpacing.xs) {
                        Text(message.from).font(.system(size: 11, weight: .medium, design: .monospaced))
                        Text(message.body).font(SSTypography.caption())
                            .foregroundStyle(message.type == .blocker ? SSColor.danger : .secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(_ status: SwarmTaskStatus) -> Color {
        switch status {
        case .done: SSColor.success
        case .running: SSColor.accent
        case .blocked: SSColor.danger
        case .pending, .skipped: .secondary
        }
    }
}
