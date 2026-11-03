import Foundation
import Speech

/// Turns a short recording (from the Apple Watch) into text, on this Mac when the recogniser supports it.
public enum AudioTranscriber {
    public static let maxBytes = 1_000_000

    public static func transcribe(_ audio: Data, format: String) async -> String? {
        guard audio.count > 0, audio.count <= maxBytes else { return nil }
        let allowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status == .authorized) }
        }
        guard allowed, let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(), recognizer.isAvailable else { return nil }
        let ext = format.filter { $0.isLetter || $0.isNumber }.prefix(5)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-remote-\(UUID().uuidString).\(ext.isEmpty ? "m4a" : String(ext))")
        guard (try? audio.write(to: url, options: .atomic)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.resume(result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if error != nil {
                    once.resume(nil)
                }
            }
            // A recognition that never finishes must not hold the remote's command queue.
            DispatchQueue.global().asyncAfter(deadline: .now() + 25) { task.cancel(); once.resume(nil) }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
    func resume(_ value: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: (value?.isEmpty ?? true) ? nil : value)
    }
}
