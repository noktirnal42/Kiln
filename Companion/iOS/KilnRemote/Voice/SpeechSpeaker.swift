import AVFoundation

/// Reads text aloud with the system voice, one chunk at a time so it can be cut off between chunks.
@MainActor
final class SpeechSpeaker: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var pending = 0
    private var onDone: (@MainActor () -> Void)?
    private(set) var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(markdown: String, whenDone: @escaping @MainActor () -> Void) {
        stop()
        let chunks = SpokenText.chunks(SpokenText.clean(markdown))
        guard !chunks.isEmpty else { whenDone(); return }
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        onDone = whenDone
        pending = chunks.count
        isSpeaking = true
        for chunk in chunks {
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
            synthesizer.speak(utterance)
        }
    }

    /// Stops speaking without calling the completion.
    func stop() {
        onDone = nil
        pending = 0
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    fileprivate func finishedOne() {
        guard pending > 0 else { return }
        pending -= 1
        if pending == 0 {
            isSpeaking = false
            let done = onDone
            onDone = nil
            done?()
        }
    }
}

extension SpeechSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedOne() }
    }
}
