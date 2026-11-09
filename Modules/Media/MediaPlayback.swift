import AVFoundation
import AVKit
import Observation
import SwiftUI

/// One AVPlayer with the controls both the video and audio viewers share: play/pause, scrub, speed.
@MainActor
@Observable
final class MediaPlayback {
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    let player = AVPlayer()
    private(set) var duration: Double = 0
    private(set) var time: Double = 0
    private(set) var isPlaying = false
    var speed: Float = 1 { didSet { applySpeed() } }
    private(set) var loadError: String?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                self.isPlaying = self.player.timeControlStatus != .paused
            }
        }
    }

    func load(_ url: URL) {
        loadError = nil; time = 0; duration = 0; isPlaying = false
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            let asset = item.asset
            do {
                let d = try await asset.load(.duration)
                let playable = try await asset.load(.isPlayable)
                guard !Task.isCancelled else { return }
                self?.duration = d.seconds.isFinite ? d.seconds : 0
                if !playable { self?.loadError = "This file can't be played by macOS (unsupported format or codec)." }
            } catch {
                self?.loadError = error.localizedDescription
            }
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusTask?.cancel()
    }

    func togglePlay() {
        if isPlaying { player.pause(); isPlaying = false; return }
        if duration > 0, time >= duration - 0.05 { player.seek(to: .zero) }
        player.defaultRate = speed
        player.playImmediately(atRate: speed)
        isPlaying = true
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        time = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ delta: Double) { seek(to: time + delta) }

    private func applySpeed() {
        player.defaultRate = speed
        if isPlaying { player.rate = speed }
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// AVKit's player surface without its own controls, so the transport bar below is the single set of controls.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}

struct TransportBar: View {
    @Bindable var playback: MediaPlayback
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        HStack(spacing: SSSpacing.s) {
            Button { playback.skip(-10) } label: { Image(systemName: "gobackward.10") }
                .accessibilityLabel("Back 10 seconds")
            Button { playback.togglePlay() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Button { playback.skip(10) } label: { Image(systemName: "goforward.10") }
                .accessibilityLabel("Forward 10 seconds")
            Text(MediaPlayback.clock(scrubbing ? scrubValue : playback.time)).monospacedDigit().font(SSTypography.caption())
            Slider(value: Binding(get: { scrubbing ? scrubValue : playback.time }, set: { scrubValue = $0 }),
                   in: 0...max(playback.duration, 0.1)) { editing in
                scrubbing = editing
                if !editing { playback.seek(to: scrubValue) }
            }
            .accessibilityLabel("Position")
            Text(MediaPlayback.clock(playback.duration)).monospacedDigit().font(SSTypography.caption()).foregroundStyle(.secondary)
            Picker("Speed", selection: $playback.speed) {
                ForEach(MediaPlayback.speeds, id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
            .labelsHidden().frame(width: 76)
            .accessibilityLabel("Playback speed")
        }
        .buttonStyle(.borderless)
        .padding(SSSpacing.s)
    }
}
