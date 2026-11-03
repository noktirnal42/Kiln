import Foundation
import KilnRemoteKit
import XCTest
@testable import KilnWatch

@MainActor
final class SpySpeaker: Speaking {
    private(set) var spoken: [String] = []
    private(set) var stopped = 0
    var finishImmediately = true
    func speak(_ text: String, onFinish: @escaping @MainActor () -> Void) {
        spoken.append(text)
        if finishImmediately { onFinish() }
    }
    func stop() { stopped += 1 }
}

@MainActor
final class SpyHaptics: Haptics {
    private(set) var played: [HapticKind] = []
    func play(_ kind: HapticKind) { played.append(kind) }
}

@MainActor
struct StubTranscriber: SpeechTranscribing {
    var text: String?
    func transcribe() async -> String? { text }
}

@MainActor
final class SpyDictation: SpeechTranscribing {
    private(set) var calls = 0
    func transcribe() async -> String? { calls += 1; return "typed instead" }
}

@MainActor
final class StubRecorder: VoiceRecording_ {
    var recording: VoiceRecording?
    private(set) var started = 0
    private(set) var finished = 0
    init(_ recording: VoiceRecording?) { self.recording = recording }
    func record() async -> VoiceRecording? { started += 1; return recording }
    func finish() { finished += 1 }
}

@MainActor
func waitUntil(timeout: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
