import SwiftUI

struct ModelPickerView: View {
    @Bindable var session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var models: [ModelDescriptor] = []
    @State private var recents: [String] = []
    @State private var search = ""
    @State private var availability: [String: ProviderAvailability] = [:]
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Models").font(SSTypography.title())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(SSSpacing.m)

            TextField("Search models…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, SSSpacing.m)

            if let loadError {
                Text(loadError)
                    .font(SSTypography.caption())
                    .foregroundStyle(SSColor.warning)
                    .padding(.horizontal, SSSpacing.m)
                    .padding(.vertical, SSSpacing.xs)
            }

            List {
                if !recents.isEmpty {
                    Section("Recents") {
                        ForEach(recents, id: \.self) { modelID in
                            row(for: modelID, descriptor: models.first { $0.id == modelID })
                        }
                    }
                }
                ForEach(grouped.sorted(by: { $0.key < $1.key }), id: \.key) { providerID, group in
                    Section {
                        ForEach(group) { model in
                            row(for: model.id, descriptor: model)
                        }
                    } header: {
                        HStack(spacing: SSSpacing.xs) {
                            Text(group.first?.providerType.displayName ?? providerID)
                            if let availability = availability[providerID], !availability.isAvailable, let reason = availability.reason {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(SSColor.warning)
                                    .help(reason)
                            }
                        }
                    }
                }
                if grouped.isEmpty && !search.isEmpty {
                    Text("No models match '\(search)'").foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)

            ReasoningPanelView(reasoning: $session.reasoning)
        }
        .frame(minWidth: 560, minHeight: 620)
        .task {
            await loadModels()
        }
    }

    private var grouped: [String: [ModelDescriptor]] {
        let filtered = models.filter { model in
            search.isEmpty || model.name.localizedCaseInsensitiveContains(search) || model.id.localizedCaseInsensitiveContains(search)
        }
        return Dictionary(grouping: filtered, by: \.providerID)
    }

    private func loadModels() async {
        let allModels = await session.registry.allModels(forceRefresh: false)
        if !allModels.isEmpty {
            models = allModels
            loadError = nil
        } else {
            loadError = "No models available yet. Check provider availability (keys, running local servers, Apple Intelligence)."
        }
        availability = await session.registry.availabilityMap()
        recents = session.recentModelIDs
    }

    @ViewBuilder
    private func row(for modelID: String, descriptor: ModelDescriptor?) -> some View {
        Button {
            session.selectedModelID = modelID
            session.recordRecent(modelID: modelID)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor?.name ?? modelID)
                        .font(SSTypography.body())
                    if let descriptor {
                        Text(tagLine(descriptor))
                            .font(SSTypography.caption())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if session.selectedModelID == modelID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(SSColor.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func tagLine(_ model: ModelDescriptor) -> String {
        var tags: [String] = []
        if model.isOnDevice { tags.append("on-device") }
        if model.supportsReasoning { tags.append("reasoning") }
        if model.supportsTools { tags.append("tools") }
        if model.supportsVision { tags.append("vision") }
        tags.append("\(model.contextWindow) ctx")
        return tags.joined(separator: " · ")
    }
}

struct ReasoningPanelView: View {
    @Binding var reasoning: ReasoningConfig
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: SSSpacing.s) {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: SSSpacing.s) {
                    Toggle("Reasoning enabled", isOn: $reasoning.enabled)

                    Picker("Budget", selection: $reasoning.budget) {
                        ForEach(ReasoningBudget.allCases, id: \.self) { budget in
                            Text(budget.rawValue).tag(budget)
                        }
                    }

                    Picker("Depth", selection: $reasoning.depth) {
                        ForEach(ReasoningDepth.allCases, id: \.self) { depth in
                            Text(depth.displayName).tag(depth)
                        }
                    }

                    LabeledContent("Temperature", value: String(format: "%.2f", reasoning.temperature))
                    Slider(value: $reasoning.temperature, in: 0...2, step: 0.05)

                    LabeledContent("Top P", value: String(format: "%.2f", reasoning.topP))
                    Slider(value: $reasoning.topP, in: 0...1, step: 0.05)

                    Stepper("Max tokens: \(reasoning.maxTokens)", value: $reasoning.maxTokens, in: 256...131072, step: 256)

                    TextField("Stop sequences (comma separated)", text: stopBinding)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.vertical, SSSpacing.s)
            } label: {
                Text("Reasoning Controls").font(SSTypography.headline())
            }
        }
        .padding(.horizontal, SSSpacing.m)
        .padding(.vertical, SSSpacing.s)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var stopBinding: Binding<String> {
        Binding(
            get: { reasoning.stopSequences.joined(separator: ", ") },
            set: { newValue in
                let parsed = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                reasoning.stopSequences = parsed
            }
        )
    }
}

extension ReasoningDepth {
    var displayName: String {
        switch self {
        case .minimal: return "Minimal (1-2 steps)"
        case .balanced: return "Balanced (3-5 steps)"
        case .deep: return "Deep (6-10 steps)"
        case .exhaustive: return "Exhaustive (10+ steps)"
        }
    }
}
