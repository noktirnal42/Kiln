import Testing
import WebKit
@testable import Kiln

struct MediaCapturePolicyTests {
    @Test func theMicrophoneIsAskedAboutAndNamesTheSite() {
        guard case .ask(let question) = MediaCapturePolicy.decide(type: .microphone, host: "voice.example.com") else { Issue.record("expected ask"); return }
        #expect(question.contains("voice.example.com") && question.contains("microphone"))
    }
    @Test func theCameraIsRefusedBecauseKilnDoesNotDeclareIt() {
        for type in [WKMediaCaptureType.camera, .cameraAndMicrophone] {
            guard case .deny = MediaCapturePolicy.decide(type: type, host: "x.example") else { Issue.record("expected deny"); return }
        }
    }
    @Test func aMissingHostStillReadsSensibly() {
        guard case .ask(let q) = MediaCapturePolicy.decide(type: .microphone, host: "") else { Issue.record("expected ask"); return }
        #expect(q.hasPrefix("Allow This page"))
    }
}
