import AVFoundation
import Speech

/// Wraps `SFSpeechRecognizer` for one utterance at a time, on the device when the language supports it.
@MainActor
final class SpeechListener {
    enum Failure: LocalizedError {
        case speechDenied, microphoneDenied, unavailable
        var errorDescription: String? {
            switch self {
            case .speechDenied: "Speech recognition is turned off for Kiln Remote. Turn it on in Settings."
            case .microphoneDenied: "Microphone access is turned off for Kiln Remote. Turn it on in Settings."
            case .unavailable: "Speech recognition is not available right now."
            }
        }
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var isListening = false

    var usesOnDeviceRecognition: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    static func authorize() async throws {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { throw Failure.speechDenied }
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }
    }

    /// `update` gets the running transcript; `isFinal` is true once the recognizer is done with the utterance.
    func start(update: @escaping @MainActor (_ text: String, _ isFinal: Bool) -> Void,
               failed: @escaping @MainActor (Error) -> Void) throws {
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sink = BufferSink(request)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
        engine.prepare()
        try engine.start()
        isListening = true

        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let errorCopy = error
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let text { update(text, final) }
                if final { self.stop() } else if let errorCopy { self.stop(); failed(errorCopy) }
            }
        }
    }

    /// Ends audio capture; the recognizer then delivers its final result.
    func finish() {
        guard isListening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
    }

    func stop() {
        isListening = false
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
    }
}

/// Lets the audio thread hand buffers to the request without crossing actor isolation.
private final class BufferSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
}
