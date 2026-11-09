import AVFoundation
import Foundation
@preconcurrency import Speech

/// Text to an audio file through the system voices (AVSpeechSynthesizer.write), so the result can be kept, shown and checked.
@MainActor
public final class SpeechFileSynthesizer {
    private let synthesizer = AVSpeechSynthesizer()
    public init() {}

    public struct Result: Sendable { public let duration: Double; public let voiceName: String }

    public static func voices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    /// `rate` is AVSpeechUtterance's scale (0…1, default 0.5).
    public func synthesize(_ text: String, voiceID: String? = nil, rate: Float? = nil, to url: URL) async throws -> Result {
        let chunks = SpokenText.chunks(SpokenText.clean(text))
        guard !chunks.isEmpty else { throw MediaError.emptyText }
        let voice = voiceID.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? VoiceController.bestVoice()
        let sink = FileSink(url: url)
        for chunk in chunks {
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = voice
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate ?? AVSpeechUtteranceDefaultSpeechRate))
            try await write(utterance, into: sink)
        }
        guard sink.frames > 0, let sampleRate = sink.sampleRate else {
            try? FileManager.default.removeItem(at: url)
            throw MediaError.synthesisFailed("the voice produced no audio")
        }
        sink.close()
        return Result(duration: Double(sink.frames) / sampleRate, voiceName: voice?.name ?? "default")
    }

    private func write(_ utterance: AVSpeechUtterance, into sink: FileSink) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceBox(continuation)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { once.finish(nil); return }
                do { try sink.append(pcm) } catch { once.finish(error) }
            }
            // A voice that never reports its end must not hang the agent.
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) { once.finish(MediaError.synthesisFailed("timed out")) }
        }
    }

    /// Plays the text aloud through the speakers, without keeping a file.
    public func speakAloud(_ text: String, voiceID: String? = nil, rate: Float? = nil) throws {
        let chunks = SpokenText.chunks(SpokenText.clean(text))
        guard !chunks.isEmpty else { throw MediaError.emptyText }
        let voice = voiceID.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? VoiceController.bestVoice()
        for chunk in chunks {
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = voice
            utterance.rate = rate ?? AVSpeechUtteranceDefaultSpeechRate
            synthesizer.speak(utterance)
        }
    }

    public func stop() { synthesizer.stopSpeaking(at: .immediate) }
    public var isSpeaking: Bool { synthesizer.isSpeaking }
}

private final class FileSink: @unchecked Sendable {
    let url: URL
    private var file: AVAudioFile?
    private let lock = NSLock()
    private(set) var frames: AVAudioFramePosition = 0
    private(set) var sampleRate: Double?
    init(url: URL) { self.url = url }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        if file == nil {
            file = try AVAudioFile(forWriting: url, settings: buffer.format.settings, commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
            sampleRate = buffer.format.sampleRate
        }
        try file?.write(from: buffer)
        frames += AVAudioFramePosition(buffer.frameLength)
    }

    func close() { lock.lock(); file = nil; lock.unlock() }
}

private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}

// MARK: - Speech to text from a file

extension AudioTranscriber {
    /// Transcribes an audio (or video-with-audio) file. Asks for Speech Recognition permission the first time; the user answers
    /// in the system dialog. Throws a `MediaError` that says what went wrong rather than returning empty text.
    public static func transcribe(fileAt url: URL, timeout: TimeInterval = 300) async throws -> String {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
        }
        guard status == .authorized else { throw MediaError.speechNotAuthorised }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw MediaError.recogniserUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false
        let text: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let once = TextOnce(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.finish(.success(result.bestTranscription.formattedString))
                } else if let error {
                    let message = error.localizedDescription.lowercased()
                    once.finish(message.contains("no speech") ? .success("") : .failure(MediaError.synthesisFailed("recognition failed: \(error.localizedDescription)")))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.finish(.failure(MediaError.synthesisFailed("recognition timed out")))
                task.cancel()
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MediaError.noSpeechFound }
        return trimmed
    }
}

private final class TextOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
    func finish(_ result: Result<String, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
