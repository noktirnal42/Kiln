import SwiftUI
import SwiftData
import ModelLabCore

struct ModelLabRootView: View {
    @Bindable var module: ModelLabModule
    @State private var section: Section = .overview

    private enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", experiments = "Experiments", datasets = "Datasets"
        case models = "Models", playground = "Playground", evaluation = "Evaluation", redTeam = "Red Team"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .overview: "gauge.with.dots.needle.33percent"
            case .experiments: "flask"
            case .datasets: "tablecells"
            case .models: "cube.box"
            case .playground: "text.bubble"
            case .evaluation: "checkmark.seal"
            case .redTeam: "shield.lefthalf.filled"
            }
        }
    }

    var body: some View {
        Group {
            if let container = module.container {
                VStack(spacing: 0) {
                    SSActivityHeader(title: "Lab", symbol: "brain.head.profile", tabs: {
                        SSTabStrip(tabs: Section.allCases, selection: $section, title: { $0.rawValue }, symbol: { $0.symbol })
                    })
                    Group {
                        switch section {
                        case .overview: ModelLabOverviewView(module: module)
                        case .experiments: ModelLabExperimentsView(module: module)
                        case .datasets: ModelLabDatasetsView(module: module)
                        case .models: ModelLabModelsView(module: module)
                        case .playground: ModelLabPlaygroundView(module: module)
                        case .evaluation: ModelLabEvaluationView(module: module)
                        case .redTeam: ModelLabRedTeamView(module: module)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .modelContainer(container)
            } else {
                ContentUnavailableView {
                    Label("Model Lab store unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(module.bootstrapError ?? "The Model Lab SwiftData store could not be opened. Training and the library are disabled; everything else you see reports this same reason rather than pretending to work.")
                }
            }
        }
        .background(SSColor.canvas)
    }
}

// MARK: - Overview: live capability rows + hardware profile

struct ModelLabOverviewView: View {
    @Bindable var module: ModelLabModule

    var body: some View {
        List {
            Section("Hardware") {
                HStack {
                    Image(systemName: module.hardware.isAppleSilicon ? "cpu" : "cpu.fill")
                    VStack(alignment: .leading) {
                        Text(module.hardware.metalDeviceName ?? "No Metal device")
                        Text("\(module.hardware.memoryGB) GB unified memory · \(module.hardware.coreCount) cores · recommended single-workload limit \(Int(Double(module.hardware.memoryGB) * 0.7)) GB")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Capabilities") {
                ForEach(module.capabilityReports) { report in
                    HStack {
                        Image(systemName: report.status == .notChecked ? "questionmark.circle" : (report.status.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill"))
                            .foregroundStyle(report.status == .notChecked ? Color.secondary : (report.status.isAvailable ? Color.green : Color.red))
                        VStack(alignment: .leading) {
                            Text(report.name)
                            if let reason = report.status.reason {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            } else if !report.detail.isEmpty {
                                Text(report.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button("Re-check now") { module.refreshCapabilities() }
                Button(module.checkingMLX ? "Testing MLX…" : "Test MLX with an installed model") {
                    Task { await module.testMLX() }
                }.disabled(module.checkingMLX)
            }
            Section("MLX status is environment-sensitive") {
                Label(
                    "The MLX test uses the smallest installed language model estimated to fit. It loads the model and checks for generated text; vision, tools and training need separate tests.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
