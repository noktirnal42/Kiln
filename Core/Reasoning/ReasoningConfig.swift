import Foundation

public struct ReasoningConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var budget: ReasoningBudget
    public var depth: ReasoningDepth
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int
    public var stopSequences: [String]
    public var systemPrompt: String?

    public init(
        enabled: Bool = true,
        budget: ReasoningBudget = .medium,
        depth: ReasoningDepth = .balanced,
        temperature: Double = 0.7,
        topP: Double = 0.95,
        maxTokens: Int = 4096,
        stopSequences: [String] = [],
        systemPrompt: String? = nil
    ) {
        self.enabled = enabled
        self.budget = budget
        self.depth = depth
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
        self.systemPrompt = systemPrompt
    }

    public static let `default` = ReasoningConfig()

    public static let minimal = ReasoningConfig(
        enabled: true, budget: .low, depth: .minimal,
        temperature: 0.3, topP: 0.9, maxTokens: 1024
    )

    public static let thorough = ReasoningConfig(
        enabled: true, budget: .high, depth: .deep,
        temperature: 0.5, topP: 0.95, maxTokens: 8192
    )
}

public enum ReasoningBudget: String, CaseIterable, Codable, Sendable {
    case low = "512"
    case medium = "2048"
    case high = "8192"
    case unlimited = "unlimited"

    public var tokenLimit: Int? {
        switch self {
        case .low: return 512
        case .medium: return 2048
        case .high: return 8192
        case .unlimited: return nil
        }
    }
}

public enum ReasoningDepth: String, CaseIterable, Codable, Sendable {
    case minimal = "1-2"
    case balanced = "3-5"
    case deep = "6-10"
    case exhaustive = "10+"

    public var stepRange: ClosedRange<Int> {
        switch self {
        case .minimal: return 1...2
        case .balanced: return 3...5
        case .deep: return 6...10
        case .exhaustive: return 10...Int.max
        }
    }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case low, medium, high
}

public struct OllamaOptions: Codable, Equatable, Sendable {
    public var num_predict: Int?
    public var temperature: Double?
    public var top_p: Double?
    public var stop: [String]?

    public init(num_predict: Int? = nil, temperature: Double? = nil, top_p: Double? = nil, stop: [String]? = nil) {
        self.num_predict = num_predict
        self.temperature = temperature
        self.top_p = top_p
        self.stop = stop
    }
}

public extension ReasoningConfig {
    func toOllamaOptions() -> OllamaOptions {
        OllamaOptions(
            num_predict: budget == .unlimited ? -1 : (budget.tokenLimit ?? maxTokens),
            temperature: temperature,
            top_p: topP,
            stop: stopSequences.isEmpty ? nil : stopSequences
        )
    }

    func toNIMEffort() -> ReasoningEffort {
        switch depth {
        case .minimal: return .low
        case .balanced: return .medium
        case .deep, .exhaustive: return .high
        }
    }

    func toAppleEffort() -> ReasoningEffort {
        switch depth {
        case .minimal: return .low
        case .balanced: return .medium
        case .deep, .exhaustive: return .high
        }
    }

    func toOpenAIEffort() -> ReasoningEffort {
        switch depth {
        case .minimal: return .low
        case .balanced: return .medium
        case .deep, .exhaustive: return .high
        }
    }

    var openAIRReasoningFields: [String: ProviderJSON] {
        var fields: [String: ProviderJSON] = [:]
        if let limit = budget.tokenLimit {
            fields["max_tokens"] = ProviderJSON(limit)
        } else {
            fields["effort"] = ProviderJSON(toOpenAIEffort().rawValue)
        }
        return fields
    }
}
