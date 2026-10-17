import Foundation

public protocol ModuleEvent: Sendable {
    var eventType: String { get }
    var sourceModule: String { get }
    var timestamp: Date { get }
}

public struct SubscriptionToken: Hashable, Sendable {
    public let id: UUID
    public let eventTypeName: String
    public let isCatchAll: Bool
}

public struct BusEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let eventType: String
    public let sourceModule: String
    public let timestamp: Date
    public let payload: Data

    public init(id: UUID = UUID(), eventType: String, sourceModule: String, timestamp: Date, payload: Data = Data()) {
        self.id = id
        self.eventType = eventType
        self.sourceModule = sourceModule
        self.timestamp = timestamp
        self.payload = payload
    }
}

public actor ModuleEventBus {
    public static let shared = ModuleEventBus()

    public static let historyLimit = 256

    private var handlers: [ObjectIdentifier: [UUID: @Sendable (any ModuleEvent) async -> Void]] = [:]
    private var catchAllHandlers: [UUID: @Sendable (BusEntry) async -> Void] = [:]
    private var tokenTypes: [UUID: ObjectIdentifier] = [:]
    private var history: [BusEntry] = []

    public init() {}

    public func publish<E: ModuleEvent & Encodable>(_ event: E) async {
        let entry = BusEntry(
            eventType: event.eventType,
            sourceModule: event.sourceModule,
            timestamp: event.timestamp,
            payload: (try? JSONEncoder().encode(event)) ?? Data()
        )
        history.append(entry)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        if let typed = handlers[ObjectIdentifier(E.self)] {
            for delivery in typed.values {
                await delivery(event)
            }
        }
        if !catchAllHandlers.isEmpty {
            for delivery in catchAllHandlers.values {
                await delivery(entry)
            }
        }
    }

    @discardableResult
    public func subscribe<E: ModuleEvent & Encodable>(
        _ type: E.Type,
        handler: @escaping @Sendable (E) async -> Void
    ) async -> SubscriptionToken {
        let token = SubscriptionToken(id: UUID(), eventTypeName: String(describing: E.self), isCatchAll: false)
        let erased: @Sendable (any ModuleEvent) async -> Void = { event in
            guard let typed = event as? E else { return }
            await handler(typed)
        }
        handlers[ObjectIdentifier(E.self), default: [:]][token.id] = erased
        tokenTypes[token.id] = ObjectIdentifier(E.self)
        return token
    }

    @discardableResult
    public func subscribeAny(
        handler: @escaping @Sendable (BusEntry) async -> Void
    ) async -> SubscriptionToken {
        let token = SubscriptionToken(id: UUID(), eventTypeName: "*", isCatchAll: true)
        catchAllHandlers[token.id] = handler
        return token
    }

    public func unsubscribe(_ token: SubscriptionToken) async {
        if token.isCatchAll {
            catchAllHandlers.removeValue(forKey: token.id)
        } else if let typeID = tokenTypes.removeValue(forKey: token.id) {
            handlers[typeID]?.removeValue(forKey: token.id)
            if handlers[typeID]?.isEmpty == true {
                handlers.removeValue(forKey: typeID)
            }
        }
    }

    public func unsubscribeAll() async {
        handlers.removeAll()
        catchAllHandlers.removeAll()
        tokenTypes.removeAll()
    }

    public func recentEvents(limit: Int = 50) async -> [BusEntry] {
        Array(history.suffix(limit))
    }

    public func subscriberCount() async -> Int {
        handlers.values.reduce(0) { $0 + $1.count } + catchAllHandlers.count
    }
}
