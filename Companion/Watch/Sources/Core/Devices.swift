import AVFoundation
import Foundation
import WatchKit

/// Turns speech into text. Dictation through the system sheet is the first source; a source that records audio and
/// hands it to the paired iPhone to transcribe can conform to the same protocol (see docs in Companion/Watch/README.md).
@MainActor
protocol SpeechTranscribing {
    /// The dictated text, or nil if the person cancelled.
    func transcribe() async -> String?
}

/// watchOS has no Speech framework: the system text input sheet offers dictation (and Scribble).
@MainActor
struct DictationTranscriber: SpeechTranscribing {
    func transcribe() async -> String? {
        await withCheckedContinuation { continuation in
            guard let controller = WKApplication.shared().visibleInterfaceController else {
                continuation.resume(returning: nil)
                return
            }
            controller.presentTextInputController(withSuggestions: ["Yes", "Go ahead", "Stop"], allowedInputMode: .plain) { results in
                let text = (results?.first as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (text?.isEmpty ?? true) ? nil : text)
            }
        }
    }
}

@MainActor
protocol Speaking: AnyObject {
    func speak(_ text: String, onFinish: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class SystemSpeaker: NSObject, Speaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var pending = 0
    private var onFinish: (@MainActor () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, onFinish: @escaping @MainActor () -> Void) {
        stop()
        let chunks = SpokenText.chunks(SpokenText.clean(text))
        guard !chunks.isEmpty else { onFinish(); return }
        self.onFinish = onFinish
        pending = chunks.count
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        for chunk in chunks { synthesizer.speak(AVSpeechUtterance(string: chunk)) }
    }

    func stop() {
        let callback = onFinish
        onFinish = nil
        pending = 0
        synthesizer.stopSpeaking(at: .immediate)
        callback?()
    }

    private func utteranceEnded() {
        pending -= 1
        guard pending <= 0, let callback = onFinish else { return }
        onFinish = nil
        callback()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }
}

enum HapticKind { case approval, success, failure }

@MainActor
protocol Haptics {
    func play(_ kind: HapticKind)
}

@MainActor
struct WatchHaptics: Haptics {
    func play(_ kind: HapticKind) {
        switch kind {
        case .approval: WKInterfaceDevice.current().play(.notification)
        case .success: WKInterfaceDevice.current().play(.success)
        case .failure: WKInterfaceDevice.current().play(.failure)
        }
    }
}
