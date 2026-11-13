import SwiftUI

/// Forecast and alerts for the map's center, from the US National Weather Service. Shows where it came from and how old it is.
struct WeatherSheet: View {
    let latitude: Double
    let longitude: Double
    let onClose: () -> Void
    @State private var report: WeatherReport?
    @State private var failure: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(report.map { "Weather: \($0.place)" } ?? "Weather").font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Reload") { Task { await load() } }.disabled(loading)
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(SSColor.danger) }
            if let report {
                Text("Source: \(WeatherReport.source). Issued \(report.issued.formatted(.relative(presentation: .named)))\(report.isStale() ? ". This forecast is stale." : ".") Official warnings decide safety, not this summary.")
                    .font(.caption).foregroundStyle(report.isStale() ? SSColor.warning : .secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !report.alerts.isEmpty {
                            Text("Active alerts").font(.subheadline.weight(.semibold))
                            ForEach(Array(report.alerts.enumerated()), id: \.offset) { _, alert in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(alert.event) (\(alert.severity))").fontWeight(.semibold).foregroundStyle(SSColor.warning)
                                    Text(alert.headline).font(.caption)
                                    Text("Issued by \(alert.sender)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                        }
                        Text("Next days").font(.subheadline.weight(.semibold))
                        ForEach(Array(report.periods.prefix(8).enumerated()), id: \.offset) { _, period in
                            HStack(alignment: .top) {
                                Text(period.name).frame(width: 110, alignment: .leading).fontWeight(.medium)
                                Text("\(period.temperature)°\(period.unit)").frame(width: 50, alignment: .leading).monospacedDigit()
                                Text(period.shortForecast + (period.precipitationChance.map { " · \($0)%" } ?? "")).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !loading, failure == nil {
                Text("No forecast.").foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(width: 520, height: 420)
        .task { await load() }
    }

    private func load() async {
        loading = true; failure = nil
        do { report = try await WeatherService().report(latitude: latitude, longitude: longitude, hours: 0) }
        catch { report = nil; failure = error.localizedDescription }
        loading = false
    }
}
