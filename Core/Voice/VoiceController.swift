import AVFoundation
import Foundation
import Observation
import Speech

/// Talk to the model and hear it answer: speech-to-text through Apple's recogniser (on device when the Mac has the model),
/// text-to-speech through the system voices. Conversation mode chains them: listen, send when you pause, speak the reply, listen again.
@MainActor
@Observable
public final class VoiceController: NSObject, AVSpeechSynthesizerDelegate {
    public enum Phase: Equatable { case idle, listening, speaking }

    public private(set) var phase: Phase = .idle
    /// What has been heard so far in the current utterance.
    public private(set) var partial = ""
    public private(set) var errorText: String?
    /// Read each finished reply aloud.
    public var speakReplies = false
    /// Listen → send → speak → listen, until switched off.
    public private(set) var conversation = false
    /// Called with the final text of an utterance.
    @ObservationIgnored public var onUtterance: (String) -> Void = { _ in }
    /// How long a pause ends an utterance.
    @ObservationIgnored public var silenceTimeout: Duration = .milliseconds(1400)

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTimer: Task<Void, Never>?
    @ObservationIgnored private var pendingUtterances = 0

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: Listening

    public func toggleListening() {
        if phase == .listening { finishListening() } else { Task { await startListening() } }
    }

    public func setConversation(_ on: Bool) {
        conversation = on
        if on { speakReplies = true; if phase == .idle { Task { await startListening() } } }
        else if phase == .listening { cancelListening() }
    }

    public func startListening() async {
        errorText = nil
        stopSpeaking()
        guard await Self.authorised() else {
            errorText = "Allow Microphone and Speech Recognition for Kiln in System Settings → Privacy & Security."
            conversation = false
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            errorText = "Speech recognition is not available for this language right now."
            conversation = false
            return
        }
        cancelListening()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sink = BufferSink(request)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            errorText = "The microphone could not start: \(error.localizedDescription)"
            conversation = false
            return
        }
        self.engine = engine
        self.request = request
        partial = ""
        phase = .listening
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor in self?.heard(text, isFinal: isFinal, failure: failure) }
        }
    }

    private func heard(_ text: String?, isFinal: Bool, failure: String?) {
        guard phase == .listening else { return }
        if let text, !text.isEmpty {
            partial = text
            silenceTimer?.cancel()
            silenceTimer = Task { [weak self, timeout = silenceTimeout] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finishListening()
            }
        }
        if isFinal { finishListening() }
        else if let failure, partial.isEmpty {
            // A recogniser that heard nothing ends with an error; that is a quiet stop, not a fault worth showing.
            cancelListening()
            if conversation { errorText = "Nothing heard. \(failure)" ; conversation = false }
        }
    }

    /// Ends the utterance and hands what was heard to `onUtterance`.
    public func finishListening() {
        guard phase == .listening else { return }
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        teardownAudio()
        phase = .idle
        partial = ""
        if text.isEmpty { if conversation { Task { await startListening() } } } else { onUtterance(text) }
    }

    public func cancelListening() {
        teardownAudio()
        if phase == .listening { phase = .idle }
        partial = ""
    }

    private func teardownAudio() {
        silenceTimer?.cancel(); silenceTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop(); engine = nil
        request?.endAudio(); request = nil
        recognition?.cancel(); recognition = nil
    }

    // MARK: Speaking

    public func speak(_ markdown: String) {
        let chunks = SpokenText.chunks(SpokenText.clean(markdown))
        guard !chunks.isEmpty else { afterSpeech(); return }
        stopListeningForSpeech()
        let voice = Self.bestVoice()
        for chunk in chunks {
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            pendingUtterances += 1
            synthesizer.speak(utterance)
        }
        phase = .speaking
    }

    public func stopSpeaking() {
        guard pendingUtterances > 0 || synthesizer.isSpeaking else { return }
        pendingUtterances = 0
        synthesizer.stopSpeaking(at: .immediate)
        if phase == .speaking { phase = .idle }
    }

    /// The conversation ends when the user stops it, or when speech is cut off by pressing the mic.
    public func stopEverything() {
        conversation = false
        stopSpeaking()
        cancelListening()
    }

    private func stopListeningForSpeech() { if phase == .listening { cancelListening() } }

    private func afterSpeech() {
        if phase == .speaking { phase = .idle }
        if conversation { Task { await startListening() } }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.pendingUtterances > 0 else { return }
            self.pendingUtterances -= 1
            if self.pendingUtterances == 0 { self.afterSpeech() }
        }
    }

    // MARK: Helpers

    /// The best installed voice for the system language: premium over enhanced over default.
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
    }

    /// `nonisolated` on purpose: macOS answers the permission request on a background queue, and a closure created inside this
    /// main-actor type would be asserted to run on the main thread, which crashed the app the first time voice asked.
    nonisolated private static func authorised() async -> Bool {
        let speech: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// The audio tap runs on a real-time thread; this carries the recognition request across without touching the main actor.
private final class BufferSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
}
