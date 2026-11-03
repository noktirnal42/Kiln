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

/// A short voice recording, sent to the Mac to be transcribed.
struct VoiceRecording: Equatable, Sendable {
    var data: Data
    var format: String
}

/// Records from the microphone the moment it is asked to, with no system sheet in between. It ends when the person taps
/// again (`finish`), after they stop talking, or at the time limit.
@MainActor
protocol VoiceRecording_: AnyObject {
    /// The recording, or nil if nothing was said, the microphone is not allowed, or it was cancelled.
    func record() async -> VoiceRecording?
    func finish()
}

@MainActor
final class MicrophoneRecorder: VoiceRecording_ {
    private var recorder: AVAudioRecorder?
    private var meter: Task<Void, Never>?
    private var continuation: CheckedContinuation<VoiceRecording?, Never>?
    private var url: URL?

    static let maxSeconds = 25.0
    /// Quiet for this long after speech ends the recording.
    static let silenceSeconds = 1.6
    /// Give up if nothing is said for this long at the start.
    static let noSpeechSeconds = 7.0
    static let speechDecibels: Float = -42

    func record() async -> VoiceRecording? {
        guard await AVAudioApplication.requestRecordPermission() else { return nil }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [])
            try session.setActive(true)
        } catch { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: file, settings: settings) else { return nil }
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: Self.maxSeconds) else { return nil }
        self.recorder = recorder
        url = file
        WKInterfaceDevice.current().play(.start)
        meter = Task { [weak self] in await self?.watchLevels() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish() { complete(heardSpeech: true) }

    private func watchLevels() async {
        var heardSpeech = false
        var quiet = 0.0
        var elapsed = 0.0
        let step = 0.1
        while !Task.isCancelled, let recorder, recorder.isRecording {
            try? await Task.sleep(for: .seconds(step))
            elapsed += step
            recorder.updateMeters()
            if recorder.averagePower(forChannel: 0) > Self.speechDecibels { heardSpeech = true; quiet = 0 } else { quiet += step }
            if heardSpeech, quiet >= Self.silenceSeconds { complete(heardSpeech: true); return }
            if !heardSpeech, elapsed >= Self.noSpeechSeconds { complete(heardSpeech: false); return }
        }
        complete(heardSpeech: heardSpeech)
    }

    private func complete(heardSpeech: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        meter?.cancel(); meter = nil
        recorder?.stop()
        recorder = nil
        WKInterfaceDevice.current().play(.stop)
        let data = url.flatMap { try? Data(contentsOf: $0) }
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        continuation.resume(returning: heardSpeech ? data.map { VoiceRecording(data: $0, format: "m4a") } : nil)
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
