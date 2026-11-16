import Foundation

public enum ProviderType: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case openCode = "opencode"
    case ollama = "ollama"
    case ollamaCloud = "ollama_cloud"
    case openRouter = "openrouter"
    case nvidiaNIM = "nim"
    case customEndpoint = "custom"
    case appleFoundation = "apple_foundation"
    case applePCC = "apple_pcc"
    case mlx = "mlx"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openCode: return "OpenCode (Local)"
        case .ollama: return "Ollama (Local)"
        case .ollamaCloud: return "Ollama Cloud"
        case .openRouter: return "OpenRouter"
        case .nvidiaNIM: return "NVIDIA NIM"
        case .customEndpoint: return "Custom Endpoint"
        case .appleFoundation: return "Apple Foundation Models"
        case .applePCC: return "Apple Private Cloud Compute"
        case .mlx: return "MLX (Local)"
        }
    }
}

public struct ProviderCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let streaming = ProviderCapabilities(rawValue: 1 << 0)
    public static let reasoning = ProviderCapabilities(rawValue: 1 << 1)
    public static let tools = ProviderCapabilities(rawValue: 1 << 2)
    public static let vision = ProviderCapabilities(rawValue: 1 << 3)
    public static let onDevice = ProviderCapabilities(rawValue: 1 << 4)
    public static let privateCloud = ProviderCapabilities(rawValue: 1 << 5)
    public static let removableStore = ProviderCapabilities(rawValue: 1 << 6)
    public static let metalAcceleration = ProviderCapabilities(rawValue: 1 << 7)

    public static let all: ProviderCapabilities = [.streaming, .reasoning, .tools, .vision, .onDevice, .privateCloud, .removableStore, .metalAcceleration]
}

public struct ProviderAvailability: Equatable, Sendable {
    public let isAvailable: Bool
    public let reason: String?

    public static func available() -> ProviderAvailability {
        ProviderAvailability(isAvailable: true, reason: nil)
    }

    public static func unavailable(_ reason: String) -> ProviderAvailability {
        ProviderAvailability(isAvailable: false, reason: reason)
    }
}

public struct ProviderJSON: Codable, Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([ProviderJSON])
        case object([String: ProviderJSON])
    }

    public var value: Value

    public init(_ value: Value) { self.value = value }

    public init(_ literal: some BinaryInteger) { value = .int(Int(literal)) }
    public init(_ literal: some BinaryFloatingPoint) { value = .double(Double(literal)) }
    public init(_ literal: String) { value = .string(literal) }
    public init(_ literal: Bool) { value = .bool(literal) }
    public init(_ literal: [ProviderJSON]) { value = .array(literal) }
    public init(_ literal: [String: ProviderJSON]) { value = .object(literal) }

    public static let null = ProviderJSON(.null)

    public var objectValue: [String: ProviderJSON]? {
        if case .object(let object) = value { return object }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = value { return string }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = .null
        } else if let bool = try? container.decode(Bool.self) {
            value = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            value = .int(int)
        } else if let double = try? container.decode(Double.self) {
            value = .double(double)
        } else if let string = try? container.decode(String.self) {
            value = .string(string)
        } else if let array = try? container.decode([ProviderJSON].self) {
            value = .array(array)
        } else if let object = try? container.decode([String: ProviderJSON].self) {
            value = .object(object)
        } else {
            value = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .int(let int): try container.encode(int)
        case .double(let double): try container.encode(double)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

/// An image explicitly supplied with a message. Pixel data is kept separate from text and tool arguments.
public struct ChatImage: Codable, Equatable, Sendable {
    public var data: Data
    public var mimeType: String
    public init(data: Data, mimeType: String) { self.data = data; self.mimeType = mimeType }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Equatable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String
    public var metadata: [String: String]
    public var toolCalls: [ToolCall]
    public var images: [ChatImage]

    public init(role: Role, content: String, metadata: [String: String] = [:], toolCalls: [ToolCall] = [], images: [ChatImage] = []) {
        self.role = role
        self.content = content
        self.metadata = metadata
        self.toolCalls = toolCalls
        self.images = images
    }

    private enum CodingKeys: String, CodingKey { case role, content, metadata, toolCalls, images }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        role = try values.decode(Role.self, forKey: .role)
        content = try values.decode(String.self, forKey: .content)
        metadata = try values.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        toolCalls = try values.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        images = try values.decodeIfPresent([ChatImage].self, forKey: .images) ?? []
    }
}

public struct ToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String
    public var index: Int?

    public init(id: String = "", name: String = "", arguments: String = "", index: Int? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.index = index
    }
}

public struct ProviderTool: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: [String: ProviderJSON]
    public var required: [String]

    public init(name: String, description: String = "", parameters: [String: ProviderJSON] = [:], required: [String] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.required = required
    }
}

public struct ChatRequest: Codable, Equatable, Sendable {
    public var messages: [ChatMessage]
    public var model: String
    public var temperature: Double
    public var maxTokens: Int
    public var topP: Double
    public var stream: Bool
    public var tools: [ProviderTool]

    public init(
        messages: [ChatMessage],
        model: String,
        temperature: Double = 0.7,
        maxTokens: Int = 4096,
        topP: Double = 1.0,
        stream: Bool = true,
        tools: [ProviderTool] = []
    ) {
        self.messages = messages
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.stream = stream
        self.tools = tools
    }
}

public struct ChatChunk: Codable, Equatable, Sendable {
    public enum FinishReason: String, Codable, Equatable, Sendable {
        case stop, length, toolCalls, contentFilter, error
    }

    public struct Usage: Codable, Equatable, Sendable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var totalTokens: Int

        public init(promptTokens: Int = 0, completionTokens: Int = 0, totalTokens: Int = 0) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
        }
    }

    public var id: String
    public var delta: ChatMessage?
    public var finishReason: FinishReason?
    public var usage: Usage?
    public var toolCalls: [ToolCall]
    /// Reasoning/thinking text some models stream before (or beside) the answer.
    public var reasoning: String?

    public init(
        id: String = UUID().uuidString,
        delta: ChatMessage? = nil,
        finishReason: FinishReason? = nil,
        usage: Usage? = nil,
        toolCalls: [ToolCall] = [],
        reasoning: String? = nil
    ) {
        self.reasoning = reasoning
        self.id = id
        self.delta = delta
        self.finishReason = finishReason
        self.usage = usage
        self.toolCalls = toolCalls
    }
}

public struct ModelDescriptor: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var providerID: String
    public var providerType: ProviderType
    /// What a hosted catalog that does not publish a window is assumed to have. Kept well above 4096 so the
    /// context meter and compaction are not driven by a placeholder: nearly every hosted chat model has at least this.
    public static let unknownHostedWindow = 32_768
    public var contextWindow: Int
    public var supportsReasoning: Bool
    public var supportsTools: Bool
    public var supportsVision: Bool
    public var isOnDevice: Bool
    public var tags: [String]

    public init(
        id: String,
        name: String,
        providerID: String,
        providerType: ProviderType,
        contextWindow: Int = 4096,
        supportsReasoning: Bool = false,
        supportsTools: Bool = false,
        supportsVision: Bool = false,
        isOnDevice: Bool = false,
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.providerType = providerType
        self.contextWindow = contextWindow
        self.supportsReasoning = supportsReasoning
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.isOnDevice = isOnDevice
        self.tags = tags
    }

    public var displayName: String { "\(name) (\(providerType.displayName))" }
}

public enum ProviderError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound(String)
    case missingConfiguration(String)
    case authenticationFailed
    case paymentRequired(String)
    case rateLimited
    case serviceUnavailable(String)
    case invalidResponse(String)
    case engineUnavailable(String)
    case network(String)

    public var description: String {
        switch self {
        case .notFound(let id):
            return "Provider '\(id)' is not registered"
        case .missingConfiguration(let reason):
            return "Provider misconfigured: \(reason)"
        case .authenticationFailed:
            return "Authentication failed: the API key was rejected by the provider"
        case .paymentRequired(let detail):
            return detail.isEmpty ? "This provider requires an active billing plan for the selected model." : "Payment required: \(detail)"
        case .rateLimited:
            return "Rate limited by the provider; retry after a short delay"
        case .serviceUnavailable(let detail):
            return detail.isEmpty ? "Provider service temporarily unavailable" : "Provider service temporarily unavailable: \(detail)"
        case .invalidResponse(let detail):
            return "Provider returned an invalid response: \(detail)"
        case .engineUnavailable(let reason):
            return reason
        case .network(let detail):
            return "Network error: \(detail)"
        }
    }
}
