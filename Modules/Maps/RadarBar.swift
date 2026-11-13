import Combine
import SwiftUI

/// Controls for the radar layer: play, a scrubber over the service's frames, opacity, a legend, and the frame's age and source.
struct RadarBar: View {
    @Bindable var state: MapsState
    private let tick = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()

    private var ageText: String {
        guard let frame = state.radarFrame else { return "No frame" }
        let minutes = max(0, Int(Date().timeIntervalSince(frame) / 60))
        let time = frame.formatted(date: .omitted, time: .shortened)
        return "\(time) · \(minutes) min ago"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.radarOn, state.radarFrames.count > 1 {
                HStack(spacing: 10) {
                    Button { state.radarPlaying.toggle() } label: { Image(systemName: state.radarPlaying ? "pause.fill" : "play.fill") }
                        .accessibilityLabel(state.radarPlaying ? "Pause radar" : "Play radar loop")
                    Slider(value: Binding(get: { Double(state.radarIndex) }, set: { state.radarPlaying = false; state.selectRadarFrame(Int($0.rounded())) }),
                           in: 0...Double(state.radarFrames.count - 1)).accessibilityLabel("Radar time")
                    Text(ageText).monospacedDigit().frame(minWidth: 130, alignment: .trailing)
                }
                HStack(spacing: 10) {
                    Text("Opacity")
                    Slider(value: $state.radarOpacity, in: 0.2...1).frame(width: 120).accessibilityLabel("Radar opacity")
                    Button("Newest") { state.radarPlaying = false; state.selectRadarFrame(state.radarFrames.count - 1) }
                    Button("Refresh") { Task { await state.setRadar(true) } }
                    Spacer(minLength: 8)
                    legend
                }
            }
            HStack(spacing: 6) {
                if let message = state.radarMessage { Text(message) }
                Spacer(minLength: 0)
                if state.radarOn { Text("Radar: \(RadarWMS.source). Shows rain already falling, not a forecast; official warnings decide safety.").lineLimit(2) }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .onReceive(tick) { _ in
            guard state.radarPlaying, state.radarFrames.count > 1 else { return }
            state.selectRadarFrame((state.radarIndex + 1) % state.radarFrames.count)
        }
    }

    /// Approximate reflectivity colours (dBZ). The service decides the real colours; this is a guide, not a calibration.
    private var legend: some View {
        HStack(spacing: 4) {
            Text("light").fixedSize()
            LinearGradient(colors: [.cyan, .green, .yellow, .orange, .red, .purple], startPoint: .leading, endPoint: .trailing)
                .frame(width: 110, height: 8).clipShape(Capsule())
                .accessibilityLabel("Radar colour scale from light to heavy precipitation")
            Text("heavy").fixedSize()
        }
    }
}
