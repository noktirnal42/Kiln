import Foundation

public enum ProviderRetry {
    public static let maximumAttempts = 3

    public static func shouldRetry(status: Int, attempt: Int) -> Bool {
        guard attempt < maximumAttempts - 1 else { return false }
        return status == 408 || status == 409 || status == 425 || status == 429 || (500...599).contains(status)
    }

    public static func delaySeconds(retryAfter: String?, attempt: Int) -> Double {
        if let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)) {
            return min(max(seconds, 0.5), 8)
        }
        return min(pow(2, Double(attempt + 1)), 8)
    }

    public static func wait(retryAfter: String?, attempt: Int) async throws {
        let seconds = delaySeconds(retryAfter: retryAfter, attempt: attempt)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Shared wire format for the OpenAI-compatible chat APIs used by
/// OpenRouter, NVIDIA NIM, Ollama Cloud, and custom endpoints.
/// Streams emit DELTAS only, never cumulative snapshots.
public enum OpenAICompatibleTransport {
    /// The `tools` array both the OpenAI-style and Ollama chat APIs accept.
    public static func toolsJSON(_ tools: [ProviderTool]) -> ProviderJSON {
        ProviderJSON(tools.map { tool in
            ProviderJSON([
                "type": ProviderJSON("function"),
                "function": ProviderJSON([
                    "name": ProviderJSON(tool.name),
                    "description": ProviderJSON(tool.description),
                    "parameters": ProviderJSON([
                        "type": ProviderJSON("object"),
                        "properties": ProviderJSON(tool.parameters.mapValues { ProviderJSON($0.value) }),
                        "required": ProviderJSON(tool.required.map { ProviderJSON($0) }),
                    ]),
                ]),
            ])
        })
    }

    public static func body(
        for request: ChatRequest,
        reasoning: ReasoningConfig? = nil,
        extraFields: [String: ProviderJSON] = [:],
        useCompletionTokens: Bool = false
    ) throws -> Data {
        var payload: [String: ProviderJSON] = [
            "model": ProviderJSON(request.model),
            "stream": ProviderJSON(true),
            "messages": ProviderJSON(request.messages.map { message -> ProviderJSON in
                var value: [String: ProviderJSON] = [
                    "role": ProviderJSON(message.role.rawValue),
                    "content": ProviderJSON(message.content),
                ]
                if !message.toolCalls.isEmpty {
                    value["tool_calls"] = ProviderJSON(message.toolCalls.map { call in
                        ProviderJSON([
                            "id": ProviderJSON(call.id),
                            "type": ProviderJSON("function"),
                            "function": ProviderJSON([
                                "name": ProviderJSON(call.name),
                                "arguments": ProviderJSON(call.arguments),
                            ]),
                        ])
                    })
                }
                if let toolCallID = message.metadata["tool_call_id"] {
                    value["tool_call_id"] = ProviderJSON(toolCallID)
                }
                return ProviderJSON(value)
            }),
        ]
        if useCompletionTokens {
            payload["max_completion_tokens"] = ProviderJSON(request.maxTokens)
        } else {
            payload["temperature"] = ProviderJSON(request.temperature)
            payload["top_p"] = ProviderJSON(request.topP)
            payload["max_tokens"] = ProviderJSON(request.maxTokens)
        }
        if !request.tools.isEmpty {
            payload["tools"] = toolsJSON(request.tools)
        }
        if let reasoning, reasoning.enabled {
            payload["reasoning"] = ProviderJSON(reasoning.openAIRReasoningFields)
        }
        for (key, value) in extraFields {
            payload[key] = value
        }
        return try JSONEncoder().encode(payload)
    }

    public static func decodeEvent(_ data: Data) throws -> ChatChunk? {
        let event = try JSONDecoder().decode(Event.self, from: data)
        if let error = event.error {
            throw ProviderError.invalidResponse(error.message)
        }
        guard let choice = event.choices?.first else { return nil }
        let finish: ChatChunk.FinishReason?
        switch choice.finishReason {
        case "tool_calls": finish = .toolCalls
        case "length": finish = .length
        case "content_filter": finish = .contentFilter
        case .some: finish = .stop
        case .none: finish = nil
        }
        return ChatChunk(
            delta: ChatMessage(role: .assistant, content: choice.delta?.content ?? ""),
            finishReason: finish,
            toolCalls: choice.delta?.toolCalls?.map {
                ToolCall(id: $0.id ?? "", name: $0.function?.name ?? "", arguments: $0.function?.arguments ?? "", index: $0.index)
            } ?? [],
            reasoning: choice.delta?.reasoning
        )
    }

    public static func stream(
        url: URL,
        apiKey: String,
        request: ChatRequest,
        reasoning: ReasoningConfig? = nil,
        session: URLSession = ProviderSessions.shared,
        headers: [String: String] = [:],
        extraFields: [String: ProviderJSON] = [:],
        useCompletionTokens: Bool = false,
        firstChunkTimeout: TimeInterval = 90
    ) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let gotFirstChunk = FirstChunkFlag()
            let task = Task {
                do {
                    var wire = URLRequest(url: url)
                    wire.httpMethod = "POST"
                    wire.timeoutInterval = 120
                    wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    wire.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if !apiKey.isEmpty {
                        wire.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    for (name, value) in headers {
                        wire.setValue(value, forHTTPHeaderField: name)
                    }
                    wire.httpBody = try body(for: request, reasoning: reasoning, extraFields: extraFields, useCompletionTokens: useCompletionTokens)

                    var attempt = 0
                    let bytes: URLSession.AsyncBytes
                    while true {
                        let (stream, response) = try await session.bytes(for: wire)
                        guard let http = response as? HTTPURLResponse else {
                            throw ProviderError.invalidResponse("missing HTTP response")
                        }
                        if ProviderRetry.shouldRetry(status: http.statusCode, attempt: attempt) {
                            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                            try await ProviderRetry.wait(retryAfter: retryAfter, attempt: attempt)
                            attempt += 1
                            continue
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            let bodyData = try await Self.boundedBody(from: stream, limit: 64 * 1024)
                            throw Self.providerError(status: http.statusCode, body: bodyData)
                        }
                        bytes = stream
                        break
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard !payload.isEmpty else { continue }
                        if let chunk = try decodeEvent(Data(payload.utf8)) {
                            gotFirstChunk.set()
                            continuation.yield(chunk)
                            if chunk.finishReason != nil { break }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Some hosted models queue a request for a minute or more without sending a byte. Say so instead of
            // leaving the UI on "Working" until the 180 s transport timeout.
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: UInt64(firstChunkTimeout * 1_000_000_000))
                guard !Task.isCancelled, !gotFirstChunk.isSet else { return }
                continuation.finish(throwing: ProviderError.invalidResponse(
                    "No response after \(Int(firstChunkTimeout)) s. The provider may be queueing requests; try again or pick another model."))
                task.cancel()
            }
            continuation.onTermination = { _ in task.cancel(); watchdog.cancel() }
        }
    }

    static func boundedBody(from bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count >= limit { break }
        }
        return body
    }

    static func providerError(status: Int, body: Data) -> ProviderError {
        var detail = ""
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let nested = object["error"] as? [String: Any],
           let message = nested["message"] as? String, !message.isEmpty {
            detail = message
        } else if let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            detail = text
        }
        switch status {
        case 401: return .authenticationFailed
        case 402: return .paymentRequired(detail)
        case 429: return .rateLimited
        case 500...599: return .serviceUnavailable(detail)
        default:
            return detail.isEmpty
                ? .invalidResponse("endpoint returned HTTP \(status)")
                : .invalidResponse(detail)
        }
    }
    private struct Event: Decodable {
        let choices: [Choice]?
        let error: APIError?
    }

    private struct APIError: Decodable {
        let message: String
    }

    private struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?
        enum CodingKeys: String, CodingKey { case delta; case finishReason = "finish_reason" }
    }

    private struct Delta: Decodable {
        let content: String?
        let toolCalls: [Call]?
        let reasoningContent: String?
        let reasoningAlt: String?
        var reasoning: String? { reasoningContent ?? reasoningAlt }
        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
            case reasoningContent = "reasoning_content"
            case reasoningAlt = "reasoning"
        }
    }

    private struct Call: Decodable {
        let index: Int?
        let id: String?
        let function: Function?
    }

    private struct Function: Decodable {
        let name: String?
        let arguments: String?
    }
}

public enum ProviderSessions {
    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        return URLSession(configuration: configuration)
    }()

    public static func stubbed() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class MockURLProtocol: URLProtocol {
    struct Response: Sendable {
        let status: Int
        let data: Data
        let headers: [String: String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: @Sendable (URLRequest) -> Response] = [:]
    nonisolated(unsafe) private static var requests: [(String, Data?)] = []

    static func route(_ pathContains: String, handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.lock()
        routes[pathContains] = handler
        lock.unlock()
    }

    static func route(_ pathContains: String, status: Int = 200, json: String) {
        route(pathContains) { _ in Response(status: status, data: Data(json.utf8), headers: ["Content-Type": "application/json"]) }
    }

    static func route(_ pathContains: String, status: Int = 200, sseEvents: [String]) {
        let body = sseEvents.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
        route(pathContains) { _ in Response(status: status, data: Data(body.utf8), headers: ["Content-Type": "text/event-stream"]) }
    }

    static func recordedRequests() -> [(String, Data?)] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func reset() {
        lock.lock()
        routes.removeAll()
        requests.removeAll()
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let target = request.url?.absoluteString ?? ""
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 16 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        Self.lock.lock()
        Self.requests.append((target, body))
        let handler = Self.routes.first { target.contains($0.key) }?.value
        Self.lock.unlock()

        let response = handler?(request) ?? Response(status: 404, data: Data("no route".utf8), headers: [:])
        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://stub.local")!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class FirstChunkFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
