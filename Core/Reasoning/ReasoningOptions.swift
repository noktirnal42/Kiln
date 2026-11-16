import Foundation

/// One named reasoning level a model offers, such as "low" or "max". `id` is what the provider's API expects.
public struct ReasoningLevel: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public init(_ id: String, title: String? = nil) { self.id = id; self.title = title ?? id.prefix(1).uppercased() + id.dropFirst() }
}

/// What a model lets the person control about its reasoning. It comes from what the provider and model actually accept, never from a
/// fixed Low/Medium/High: a model that offers nothing is `.unavailable`, and the control says why instead of pretending.
public enum ReasoningControl: Equatable, Sendable {
    /// The model offers no reasoning setting Kiln can drive (it may still think on its own). The text says why.
    case unavailable(String)
    /// Thinking can be turned on or off.
    case toggle
    /// Named levels, in order from least to most.
    case levels([ReasoningLevel])

    public var isAvailable: Bool { if case .unavailable = self { return false }; return true }

    /// A sentence for a tooltip.
    public var explanation: String {
        switch self {
        case .unavailable(let why): why
        case .toggle: "Turn the model's thinking on or off."
        case .levels(let levels): "This model offers \(levels.map(\.title).joined(separator: ", ")) reasoning."
        }
    }
}

/// The person's choice for one model.
public enum ReasoningSelection: Hashable, Sendable {
    case off, on
    case level(String)

    public var storage: String {
        switch self { case .off: "off"; case .on: "on"; case .level(let id): "level:\(id)" }
    }

    public init?(storage: String) {
        switch storage {
        case "off": self = .off
        case "on": self = .on
        default:
            guard storage.hasPrefix("level:"), storage.count > 6 else { return nil }
            self = .level(String(storage.dropFirst(6)))
        }
    }
}

public enum ReasoningCapability {
    public static let low = ReasoningLevel("low"), medium = ReasoningLevel("medium"), high = ReasoningLevel("high"), max = ReasoningLevel("max")

    /// What this model offers. The rules, and where each comes from:
    /// - Ollama (local and cloud): the catalog's `thinking` capability decides whether a model reasons at all. `gpt-oss` takes the named
    ///   levels low, medium and high through `think`; every other thinking model takes `think` true or false.
    /// - OpenRouter: models that list the `reasoning` parameter take `reasoning.effort` (low, medium, high).
    /// - NVIDIA NIM: GLM 5.3 takes `reasoning_effort` low, high or max (the request Kiln already sends). Other NIM models publish no control.
    /// - Custom endpoints, Apple Foundation Models, Private Cloud Compute and MLX report none.
    public static func control(for model: ModelDescriptor) -> ReasoningControl {
        switch model.providerType {
        case .appleFoundation, .applePCC, .mlx:
            return .unavailable("On-device models run without a reasoning setting.")
        case .customEndpoint:
            return .unavailable("Custom endpoints do not report reasoning options.")
        default: break
        }
        guard model.supportsReasoning else { return .unavailable("\(model.name) does not offer reasoning options.") }
        switch model.providerType {
        case .ollama, .ollamaCloud, .openCode:
            return model.name.lowercased().contains("gpt-oss") ? .levels([low, medium, high]) : .toggle
        case .openRouter:
            return .levels([low, medium, high])
        case .nvidiaNIM:
            return model.id.lowercased().contains("z-ai/glm-5.3") ? .levels([low, high, max]) : .unavailable("NVIDIA does not publish reasoning options for this model.")
        default:
            return .unavailable("\(model.name) does not offer reasoning options.")
        }
    }

    /// The choice a model starts with: thinking on, or the middle level.
    public static func defaultSelection(for control: ReasoningControl) -> ReasoningSelection? {
        switch control {
        case .unavailable: nil
        case .toggle: .on
        case .levels(let levels): levels.isEmpty ? nil : .level(levels[levels.count / 2].id)
        }
    }

    /// A stored choice checked against what the model offers now; a level the model no longer has falls back to the default.
    public static func normalized(_ selection: ReasoningSelection?, for control: ReasoningControl) -> ReasoningSelection? {
        switch control {
        case .unavailable: return nil
        case .toggle: if selection == .off || selection == .on { return selection }
        case .levels(let levels): if case .level(let id) = selection, levels.contains(where: { $0.id == id }) { return selection }
        }
        return defaultSelection(for: control)
    }
}

/// The choice per model, remembered between launches. With no defaults (tests) it only remembers within the session.
public struct ReasoningChoiceStore: @unchecked Sendable {
    public static let key = "chat.reasoning.choices.v1"
    private let defaults: UserDefaults?
    private let memory = Memory()

    final class Memory: @unchecked Sendable {
        private let lock = NSLock(); private var table: [String: String] = [:]
        func get() -> [String: String] { lock.lock(); defer { lock.unlock() }; return table }
        func set(_ value: [String: String]) { lock.lock(); table = value; lock.unlock() }
    }

    public init(defaults: UserDefaults? = .standard) { self.defaults = defaults }

    private var table: [String: String] { defaults.map { $0.dictionary(forKey: Self.key) as? [String: String] ?? [:] } ?? memory.get() }

    public func selection(forModel id: String) -> ReasoningSelection? { table[id].flatMap(ReasoningSelection.init(storage:)) }

    public func set(_ selection: ReasoningSelection?, forModel id: String) {
        var all = table
        all[id] = selection?.storage
        if let defaults { defaults.set(all, forKey: Self.key) } else { memory.set(all) }
    }
}

public extension ReasoningConfig {
    /// This config with the person's choice for a model applied. The provider code reads `enabled`, `level` and `chosenOff`.
    func applying(_ selection: ReasoningSelection?, control: ReasoningControl) -> ReasoningConfig {
        var config = self
        config.level = nil
        config.chosenOff = false
        switch ReasoningCapability.normalized(selection, for: control) {
        case .none:
            config.enabled = false
        case .some(.off):
            config.enabled = false; config.chosenOff = true
        case .some(.on):
            config.enabled = true
        case .some(.level(let id)):
            config.enabled = true; config.level = id
        }
        return config
    }
}
