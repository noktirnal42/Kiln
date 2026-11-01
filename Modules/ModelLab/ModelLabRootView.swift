import SwiftUI
import SwiftData
import ModelLabCore

struct ModelLabRootView: View {
    @Bindable var module: ModelLabModule

    var body: some View {
        Group {
            if let container = module.container {
                TabView {
                    ModelLabOverviewView(module: module)
                        .tabItem { Label("Overview", systemImage: "gauge") }
                    ModelLabExperimentsView(module: module)
                        .tabItem { Label("Experiments", systemImage: "flask") }
                        .modelContainer(container)
                    ModelLabDatasetsView(module: module)
                        .tabItem { Label("Datasets", systemImage: "tablecells") }
                        .modelContainer(container)
                    ModelLabModelsView(module: module)
                        .tabItem { Label("Models", systemImage: "cube") }
                        .modelContainer(container)
                    ModelLabPlaygroundView(module: module)
                        .tabItem { Label("Playground", systemImage: "bubble") }
                    ModelLabEvaluationView(module: module)
                        .tabItem { Label("Evaluation", systemImage: "chart.bar") }
                    ModelLabRedTeamView(module: module)
                        .tabItem { Label("Red Team", systemImage: "shield.lefthalf.filled") }
                }
            } else {
                ContentUnavailableView {
                    Label("Model Lab store unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(module.bootstrapError ?? "The Model Lab SwiftData store could not be opened. Training and the library are disabled; everything else you see reports this same reason rather than pretending to work.")
                }
            }
        }
        .frame(minWidth: 600, minHeight: 480)
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
            Section("Capabilities (checked live)") {
                ForEach(module.capabilityReports) { report in
                    HStack {
                        Image(systemName: report.status.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(report.status.isAvailable ? .green : .red)
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
            }
            Section("MLX status is environment-sensitive") {
                Label(
                    "Per AILab CAPABILITIES.md: MLX generation and LoRA training completed in GUI context on the reference machine, but the underlying scheduler issue is upstream and intermittent — this panel reflects a live probe, never a cached 'working' claim.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Model Lab")
    }
}
