import Foundation
import KilnRemoteKit
import Observation

/// Tap-to-talk, spoken replies and the hands-free conversation loop (listen, send, wait for the reply, read it,
/// listen again). While hands-free, an approval request is read out and answered by saying "allow" or "deny".
@MainActor
@Observable
final class VoiceController {
    enum State: Equatable { case idle, listening, thinking, speaking }

    private(set) var state: State = .idle
    private(set) var transcript = ""
    private(set) var handsFree = false
    private(set) var errorMessage: String?
    var readRepliesAloud: Bool {
        didSet { UserDefaults.standard.set(readRepliesAloud, forKey: "readRepliesAloud"); if !readRepliesAloud { speaker.stop() } }
    }

    @ObservationIgnored private let session: RemoteSession
    @ObservationIgnored private let listener = SpeechListener()
    @ObservationIgnored private let speaker = SpeechSpeaker()
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var awaitingApproval: RemoteApproval?
    @ObservationIgnored private var awaitingReply = false

    init(session: RemoteSession) {
        self.session = session
        readRepliesAloud = UserDefaults.standard.bool(forKey: "readRepliesAloud")
        session.onAssistantMessage = { [weak self] message in self?.assistantReplied(message) }
        session.onApprovalRequested = { [weak self] approval in self?.approvalRequested(approval) }
    }

    var isActive: Bool { state != .idle }

    // MARK: tap to talk

    /// One utterance, sent as soon as the recognizer settles or the button is tapped again.
    func toggleDictation() {
        if state == .listening { finishListening(); return }
        guard state == .idle else { stopEverything(); return }
        beginListening()
    }

    func startHandsFree() {
        handsFree = true
        beginListening()
    }

    func stopEverything() {
        handsFree = false
        awaitingReply = false
        awaitingApproval = nil
        silenceTask?.cancel()
        listener.stop()
        speaker.stop()
        state = .idle
        transcript = ""
    }

    // MARK: listening

    private func beginListening() {
        errorMessage = nil
        speaker.stop()
        Task {
            do {
                try await SpeechListener.authorize()
                transcript = ""
                try listener.start(
                    update: { [weak self] text, isFinal in self?.heard(text, isFinal: isFinal) },
                    failed: { [weak self] error in self?.fail(error) })
                state = .listening
            } catch { fail(error) }
        }
    }

    private func heard(_ text: String, isFinal: Bool) {
        transcript = text
        silenceTask?.cancel()
        if isFinal { deliver(); return }
        // A pause after speech ends the utterance, which is what makes hands-free work without touching the phone.
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.finishListening()
        }
    }

    private func finishListening() {
        silenceTask?.cancel()
        listener.finish()
        // The recognizer delivers the final result next; if it never does, send what we have.
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.deliver()
        }
    }

    private func deliver() {
        silenceTask?.cancel()
        guard state == .listening || listener.isListening || !transcript.isEmpty else { return }
        listener.stop()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        guard !text.isEmpty else {
            state = .idle
            if handsFree { beginListening() }   // nothing heard: keep the conversation open
            return
        }
        if let approval = awaitingApproval {
            answerApproval(approval, with: text)
            return
        }
        awaitingReply = true
        state = .thinking
        session.send(text, spoken: true)
    }

    // MARK: replies and approvals

    private func assistantReplied(_ message: RemoteMessage) {
        guard readRepliesAloud || handsFree, awaitingReply || handsFree else { return }
        awaitingReply = false
        state = .speaking
        speaker.speak(markdown: message.text) { [weak self] in
            guard let self else { return }
            self.state = .idle
            if self.handsFree { self.beginListening() }
        }
    }

    private func approvalRequested(_ approval: RemoteApproval) {
        guard handsFree else { return }
        awaitingApproval = approval
        speaker.speak(markdown: "Kiln wants to use \(approval.tool). \(approval.preview). Say allow or deny.") { [weak self] in
            guard let self else { return }
            self.state = .idle
            self.beginListening()
        }
        state = .speaking
    }

    private func answerApproval(_ approval: RemoteApproval, with text: String) {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let allow: Set = ["allow", "yes", "approve", "okay", "ok"]
        let deny: Set = ["deny", "no", "stop", "reject", "cancel"]
        if words.contains(where: deny.contains) {
            session.decide(approval, .deny)
        } else if words.count <= 3, words.contains(where: allow.contains) {
            session.decide(approval, .allowOnce)   // short phrases only: a sentence that merely mentions "yes" is not consent
        } else {
            speaker.speak(markdown: "I didn't catch that. Say allow or deny.") { [weak self] in self?.beginListening() }
            state = .speaking
            return
        }
        awaitingApproval = nil
        awaitingReply = true
        state = .thinking
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        listener.stop()
        handsFree = false
        state = .idle
    }
}
