import Foundation
import FoundationModels

/// Wraps Apple's on-device Foundation Models (Apple Intelligence). Every
/// call re-checks `SystemLanguageModel.default.availability` live rather
/// than caching a boolean at launch, since it can change while the app is
/// running (the user can enable Apple Intelligence, or the asset can finish
/// downloading, without relaunching Model Lab).
public struct FoundationModelsInferenceProvider: InferenceProvider {
    public let name = "Apple Intelligence (on-device)"

    public init() {}

    public func capability() -> CapabilityStatus {
        guard #available(macOS 26.0, *) else {
            return .unavailable(reason: "Requires macOS 26 or later.")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "This Mac is not eligible for Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Apple Intelligence is turned off. Enable it in System Settings → Apple Intelligence & Siri.")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "The on-device model is still downloading.")
        case .unavailable:
            return .unavailable(reason: "Apple Intelligence is unavailable for an unrecognized reason.")
        }
    }

    public func streamRespond(prompt: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard #available(macOS 26.0, *) else {
                continuation.finish(throwing: InferenceError.unavailable(reason: "Requires macOS 26 or later."))
                return
            }
            guard case .available = capability() else {
                continuation.finish(throwing: InferenceError.unavailable(reason: capability().reason ?? "Unavailable."))
                return
            }
            let task = Task {
                do {
                    let session = LanguageModelSession(model: .default)
                    var previous = ""
                    let stream = session.streamResponse(to: prompt)
                    for try await snapshot in stream {
                        let full = snapshot.content
                        let delta = String(full.dropFirst(previous.count))
                        if !delta.isEmpty {
                            continuation.yield(delta)
                        }
                        previous = full
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
