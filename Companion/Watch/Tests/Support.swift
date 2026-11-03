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
func waitUntil(timeout: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
