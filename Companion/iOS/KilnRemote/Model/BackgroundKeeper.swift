import AVFoundation
import Foundation
import Observation

/// Keeps the app running while the iPhone is locked so its link to the Mac stays up, and so approvals can raise a
/// notification (which mirrors to the Apple Watch) and the watch can still be bridged. iOS suspends an app within seconds of
/// locking unless it is playing audio, so this plays an inaudible, silent loop. It costs some battery, and Apple's App Store
/// review does not allow it, which is why it is a switch you turn on yourself for a personally installed app.
@MainActor
@Observable
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    private static let defaultsKey = "stayConnectedWhenLocked"

    /// On by default: without it the iPhone drops the Mac as soon as it locks.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            if newValue { startIfWanted() } else { stop() }
        }
    }
    private(set) var isRunning = false
    /// Whether anything needs the link right now (a pairing exists); set by the app.
    var wanted = false { didSet { startIfWanted() } }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func startIfWanted() {
        guard isEnabled, wanted else { if !wanted || !isEnabled { stop() }; return }
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // Mix with whatever the person is listening to and never duck it: this must be unnoticeable.
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000) else { return }
        silence.frameLength = silence.frameCapacity   // zero-filled: silence
        player.scheduleBuffer(silence, at: nil, options: .loops)
        engine.mainMixerNode.outputVolume = 0
        do { try engine.start() } catch { return }
        player.play()
        self.engine = engine
        isRunning = true
        observe()
    }

    func stop() {
        engine?.stop()
        engine = nil
        isRunning = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    /// A call, Siri or another app can interrupt audio; start again when it ends.
    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in self?.restart() }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        })
    }

    private func restart() {
        let wasRunning = isRunning
        stop()
        if wasRunning { startIfWanted() }
    }
}
