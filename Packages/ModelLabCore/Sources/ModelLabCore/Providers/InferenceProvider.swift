import Foundation

public struct ChatTurn: Identifiable, Sendable {
    public struct Call: Sendable {
        public let id: String
        public let name: String
        public let arguments: String
        public init(id: String, name: String, arguments: String) {
            self.id = id; self.name = name; self.arguments = arguments
        }
    }
    public let id = UUID()
    public let role: String
    public var text: String
    public var toolCallID: String?
    public var calls: [Call]

    public init(role: String, text: String, toolCallID: String? = nil, calls: [Call] = []) {
        self.role = role
        self.text = text
        self.toolCallID = toolCallID
        self.calls = calls
    }
}

public enum InferenceError: LocalizedError {
    case unavailable(reason: String)
    case modelNotFound
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .modelNotFound: "Model file not found."
        case .invalidInput(let detail): "Invalid input: \(detail)"
        }
    }
}

/// Unifies chat-style text generation (Playground) across whichever local
/// backends are actually usable. Every provider must answer `capability()`
/// truthfully; the UI disables the corresponding Playground tab and shows
/// the reason when it isn't `.available`.
public protocol InferenceProvider: Sendable {
    var name: String { get }
    func capability() -> CapabilityStatus
    func streamRespond(prompt: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error>
}
