import Foundation

// The swarm's coordination bus (roadmap 4.4): the ONLY channel agents have to each other.
//
// Design rules, each enforced here rather than left to callers:
// - Readable. Messages are text plus optional structured data, never opaque bytes, and every message
//   stays in the history an operator can read. Direct messages are delivered to one agent but are
//   still in the operator's view.
// - Attributable. A sender is a registered `BusEndpoint` that stamps its own id. The raw publish is
//   file-private, so holding the bus is not enough to speak as someone else.
// - Redacted. Secret-shaped values are removed from bodies, data and memory before anyone sees them,
//   so a leaked key does not propagate from one agent to the others or onto the dashboard.
// - Bounded. Body, data, memory and history sizes are capped; the count of what fell off is exposed.
// - Non-blocking. Delivery goes to bounded mailboxes. A slow subscriber loses its OLDEST queued
//   messages (counted and audited); it never stalls the publisher or other subscribers.
// - Shared memory is versioned. Writes are compare-and-set, and every write also appears as a message
//   on the "memory" topic, so cross-agent state changes are as visible as conversation.

public struct BusDeliveryStat: Sendable, Equatable {
    /// nil is an operator observer.
    public let agent: String?
    public let delivered: Int
    public let dropped: Int
}

public actor CoordinationBus {
    public static let memoryTopic = "memory"

    private static let reservedPrefixes = ["operator", "orchestrator", "system"]
    private static let agentPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9._-]{0,63}$")
    private static let topicPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9._/-]{0,95}$")
    private static let keyPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9._:/-]{0,127}$")

    private struct Subscription {
        let agent: String?
        let topics: Set<String>?
        let continuation: AsyncStream<CoordinationMessage>.Continuation
        var delivered = 0
        var dropped = 0
    }

    private let limits: CoordinationLimits
    private let audit: AgentAuditRecorder?
    private let clock: @Sendable () -> Date

    private var registered: Set<String> = []
    private var nextSeq = 1
    private var history: [CoordinationMessage] = []
    private var subscriptions: [UUID: Subscription] = [:]
    private var memory: [String: SharedValue] = [:]
    private var closed = false

    /// Messages that fell off the end of the history because of `historyLimit`.
    public private(set) var historyDropped = 0

    /// - Parameter audit: records every message, conflict and dropped delivery into the audit chain.
    public init(limits: CoordinationLimits = CoordinationLimits(), audit: AgentAuditRecorder? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.limits = limits
        self.audit = audit
        self.clock = clock
    }

    // MARK: Registration

    /// Registers an agent and returns the endpoint it speaks through.
    public func register(agent id: String) throws -> BusEndpoint {
        guard Self.matches(Self.agentPattern, id) else { throw CoordinationError.invalidAgentID(id) }
        guard !Self.isReserved(id) else { throw CoordinationError.reservedAgentID(id) }
        return try add(id)
    }

    /// Registers an orchestrator-side participant (`orchestrator…` or `system…`). Agents cannot take these ids.
    public func registerSystem(_ id: String) throws -> BusEndpoint {
        guard Self.matches(Self.agentPattern, id) else { throw CoordinationError.invalidAgentID(id) }
        guard Self.isReserved(id), !id.hasPrefix("operator") else { throw CoordinationError.invalidAgentID(id) }
        return try add(id)
    }

    private func add(_ id: String) throws -> BusEndpoint {
        guard !closed else { throw CoordinationError.closed }
        guard registered.insert(id).inserted else { throw CoordinationError.duplicateAgent(id) }
        return BusEndpoint(agentID: id, bus: self)
    }

    /// Removes an agent (its run ended). Its streams finish; messages to it are refused afterward.
    public func unregister(agent id: String) {
        registered.remove(id)
        for (key, subscription) in subscriptions where subscription.agent == id {
            subscription.continuation.finish()
            subscriptions.removeValue(forKey: key)
        }
    }

    public var registeredAgents: [String] { registered.sorted() }

    private static func isReserved(_ id: String) -> Bool {
        reservedPrefixes.contains { prefix in
            id == prefix || [".", "-", "_"].contains { separator in id.hasPrefix(prefix + separator) }
        }
    }

    // MARK: Publishing

    fileprivate func publish(from sender: String, topic: String, type: CoordinationMessageType, body: String,
                             data: [String: AuditValue], to recipient: String?, replyTo: UUID?) throws -> CoordinationMessage {
        guard !closed else { throw CoordinationError.closed }
        guard Self.matches(Self.topicPattern, topic) else { throw CoordinationError.invalidTopic(topic) }
        guard body.count <= limits.maxBodyCharacters else { throw CoordinationError.bodyTooLarge(limits.maxBodyCharacters) }
        let dataValue = AuditValue.object(data)
        guard dataValue.canonical.count <= limits.maxDataCharacters else {
            throw CoordinationError.dataTooLarge(limits.maxDataCharacters)
        }
        if let recipient, recipient != "operator", !registered.contains(recipient) {
            throw CoordinationError.unknownRecipient(recipient)
        }

        let (cleanBody, bodyRedactions) = SecretRedactor.redact(body)
        let (cleanData, dataRedactions) = Self.redact(dataValue)
        guard case .object(let cleanObject) = cleanData else { throw CoordinationError.dataTooLarge(limits.maxDataCharacters) }

        let message = CoordinationMessage(
            id: UUID(), seq: nextSeq, topic: topic, from: sender, to: recipient, type: type,
            body: cleanBody, data: cleanObject, timestamp: clock(), replyTo: replyTo,
            redactions: bodyRedactions + dataRedactions
        )
        nextSeq += 1
        history.append(message)
        if history.count > limits.historyLimit {
            let overflow = history.count - limits.historyLimit
            history.removeFirst(overflow)
            historyDropped += overflow
        }
        deliver(message)
        audit?.record("bus.message", [
            "id": .string(message.id.uuidString),
            "seq": .int(message.seq),
            "topic": .string(topic),
            "from": .string(sender),
            "to": recipient.map(AuditValue.string) ?? .null,
            "type": .string(type.rawValue),
            "body_characters": .int(message.body.count),
            "body": .string(AgentAuditRecorder.clip(message.body)),
            "redactions": .int(message.redactions),
        ])
        return message
    }

    /// The operator (the human) speaking on the bus. Distinct from any agent id.
    @discardableResult
    public func operatorPublish(topic: String, type: CoordinationMessageType = .sync, body: String,
                                data: [String: AuditValue] = [:], to recipient: String? = nil) throws -> CoordinationMessage {
        try publish(from: "operator", topic: topic, type: type, body: body, data: data, to: recipient, replyTo: nil)
    }

    private func deliver(_ message: CoordinationMessage) {
        for (id, subscription) in subscriptions {
            let wanted: Bool
            if subscription.agent == nil {
                wanted = true                                   // operator observers see everything
            } else if subscription.agent == message.from {
                wanted = false                                  // no echo to the sender
            } else if let recipient = message.to {
                wanted = subscription.agent == recipient        // direct
            } else {
                wanted = subscription.topics?.contains(message.topic) ?? false
            }
            guard wanted else { continue }

            switch subscription.continuation.yield(message) {
            case .enqueued:
                subscriptions[id]?.delivered += 1
            case .dropped:
                // The newest message was queued and the OLDEST was discarded to make room.
                subscriptions[id]?.delivered += 1
                subscriptions[id]?.dropped += 1
                audit?.record("bus.delivery.dropped", [
                    "agent": subscription.agent.map(AuditValue.string) ?? .null,
                    "dropped_total": .int((subscriptions[id]?.dropped) ?? 0),
                ])
            case .terminated:
                subscriptions.removeValue(forKey: id)
            @unknown default:
                break
            }
        }
    }

    // MARK: Subscribing

    fileprivate func subscribe(agent: String, topics: Set<String>) throws -> AsyncStream<CoordinationMessage> {
        guard !closed else { throw CoordinationError.closed }
        guard registered.contains(agent) else { throw CoordinationError.unknownRecipient(agent) }
        for topic in topics where !Self.matches(Self.topicPattern, topic) { throw CoordinationError.invalidTopic(topic) }
        return makeStream(agent: agent, topics: topics)
    }

    /// Every message, including direct ones, in order. For the dashboard and the operator.
    public func observe() -> AsyncStream<CoordinationMessage> {
        closed ? AsyncStream { $0.finish() } : makeStream(agent: nil, topics: nil)
    }

    private func makeStream(agent: String?, topics: Set<String>?) -> AsyncStream<CoordinationMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: CoordinationMessage.self,
                                                            bufferingPolicy: .bufferingNewest(limits.mailboxLimit))
        let id = UUID()
        subscriptions[id] = Subscription(agent: agent, topics: topics, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscription(id) }
        }
        return stream
    }

    private func removeSubscription(_ id: UUID) {
        subscriptions.removeValue(forKey: id)
    }

    public func deliveryStats() -> [BusDeliveryStat] {
        subscriptions.values.map { BusDeliveryStat(agent: $0.agent, delivered: $0.delivered, dropped: $0.dropped) }
    }

    // MARK: History

    /// Everything the operator may read, newest `limit` messages, oldest first.
    public func history(topic: String? = nil, from sender: String? = nil, sinceSeq: Int? = nil, limit: Int = 100) -> [CoordinationMessage] {
        Array(history.filter { message in
            (topic == nil || message.topic == topic) && (sender == nil || message.from == sender)
                && (sinceSeq == nil || message.seq > sinceSeq!)
        }.suffix(max(0, limit)))
    }

    fileprivate func history(for agent: String, topic: String?, sinceSeq: Int?, limit: Int) -> [CoordinationMessage] {
        // An agent reads the broadcast log and its own direct traffic, not other agents' direct messages.
        Array(history.filter { message in
            (message.to == nil || message.to == agent || message.from == agent)
                && (topic == nil || message.topic == topic) && (sinceSeq == nil || message.seq > sinceSeq!)
        }.suffix(max(0, limit)))
    }

    public var messageCount: Int { nextSeq - 1 }

    // MARK: Shared memory

    public func memoryRead(_ key: String) -> SharedValue? { memory[key] }

    /// Every key with its current value, for the dashboard.
    public func memorySnapshot() -> [String: SharedValue] { memory }

    /// Compare-and-set. `expectedVersion` nil overwrites; 0 means "must not exist yet"; n means "must
    /// still be at version n". A mismatch throws with the current version so the caller can re-read.
    fileprivate func memoryWrite(by agent: String, key: String, value: AuditValue, expectedVersion: Int?) throws -> SharedValue {
        try checkMemory(key: key, value: value)
        let current = memory[key]?.version ?? 0
        if let expectedVersion, expectedVersion != current {
            audit?.record("bus.memory.conflict", [
                "key": .string(key), "by": .string(agent),
                "expected": .int(expectedVersion), "current": .int(current),
            ])
            throw CoordinationError.versionConflict(key: key, expected: expectedVersion, current: current)
        }
        return try commitMemory(by: agent, key: key, value: value, version: current + 1)
    }

    /// Atomic read-modify-write. The transform is synchronous on purpose: awaiting inside an actor lets
    /// other callers interleave, which would break atomicity.
    fileprivate func memoryUpdate(by agent: String, key: String,
                                  transform: (SharedValue?) throws -> AuditValue) throws -> SharedValue {
        let existing = memory[key]
        let value = try transform(existing)
        try checkMemory(key: key, value: value)
        return try commitMemory(by: agent, key: key, value: value, version: (existing?.version ?? 0) + 1)
    }

    private func checkMemory(key: String, value: AuditValue) throws {
        guard Self.matches(Self.keyPattern, key) else { throw CoordinationError.invalidKey(key) }
        guard value.canonical.count <= limits.maxMemoryValueCharacters else {
            throw CoordinationError.valueTooLarge(limits.maxMemoryValueCharacters)
        }
        if memory[key] == nil, memory.count >= limits.maxMemoryKeys {
            throw CoordinationError.tooManyKeys(limits.maxMemoryKeys)
        }
    }

    private func commitMemory(by agent: String, key: String, value: AuditValue, version: Int) throws -> SharedValue {
        guard !closed else { throw CoordinationError.closed }
        let (clean, _) = Self.redact(value)
        let stored = SharedValue(value: clean, version: version, updatedBy: agent, updatedAt: clock())
        memory[key] = stored
        // The write is also a message, so shared state changes are as visible as conversation.
        _ = try publish(from: agent, topic: Self.memoryTopic, type: .sync, body: "wrote \(key) (version \(version))",
                        data: ["key": .string(key), "version": .int(version), "characters": .int(clean.canonical.count)],
                        to: nil, replyTo: nil)
        return stored
    }

    // MARK: Lifecycle

    /// Finishes every stream and refuses further traffic. History and memory stay readable.
    public func close() {
        closed = true
        for subscription in subscriptions.values { subscription.continuation.finish() }
        subscriptions.removeAll()
    }

    // MARK: Helpers

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Redacts every string inside a value, returning the cleaned value and how many were removed.
    static func redact(_ value: AuditValue) -> (AuditValue, Int) {
        switch value {
        case .string(let text):
            let (clean, count) = SecretRedactor.redact(text)
            return (.string(clean), count)
        case .array(let items):
            var count = 0
            let cleaned = items.map { item -> AuditValue in
                let (clean, n) = redact(item)
                count += n
                return clean
            }
            return (.array(cleaned), count)
        case .object(let pairs):
            var count = 0
            var cleaned: [String: AuditValue] = [:]
            for (key, item) in pairs {
                let (clean, n) = redact(item)
                cleaned[key] = clean
                count += n
            }
            return (.object(cleaned), count)
        default:
            return (value, 0)
        }
    }
}

/// An agent's handle on the bus. Everything it sends is stamped with its own id; it can read the
/// broadcast log and its own direct traffic, and read and write shared memory.
public struct BusEndpoint: Sendable {
    public let agentID: String
    let bus: CoordinationBus

    fileprivate init(agentID: String, bus: CoordinationBus) {
        self.agentID = agentID
        self.bus = bus
    }

    @discardableResult
    public func publish(topic: String, type: CoordinationMessageType, body: String,
                        data: [String: AuditValue] = [:], to recipient: String? = nil,
                        replyTo: UUID? = nil) async throws -> CoordinationMessage {
        try await bus.publish(from: agentID, topic: topic, type: type, body: body, data: data,
                              to: recipient, replyTo: replyTo)
    }

    /// Messages on `topics` plus anything addressed to this agent. Not echoed back to its own sends.
    public func subscribe(to topics: Set<String>) async throws -> AsyncStream<CoordinationMessage> {
        try await bus.subscribe(agent: agentID, topics: topics)
    }

    public func history(topic: String? = nil, sinceSeq: Int? = nil, limit: Int = 100) async -> [CoordinationMessage] {
        await bus.history(for: agentID, topic: topic, sinceSeq: sinceSeq, limit: limit)
    }

    public func readMemory(_ key: String) async -> SharedValue? { await bus.memoryRead(key) }

    @discardableResult
    public func writeMemory(_ key: String, _ value: AuditValue, expectedVersion: Int? = nil) async throws -> SharedValue {
        try await bus.memoryWrite(by: agentID, key: key, value: value, expectedVersion: expectedVersion)
    }

    @discardableResult
    public func updateMemory(_ key: String,
                             _ transform: @Sendable (SharedValue?) throws -> AuditValue) async throws -> SharedValue {
        try await bus.memoryUpdate(by: agentID, key: key, transform: transform)
    }
}
