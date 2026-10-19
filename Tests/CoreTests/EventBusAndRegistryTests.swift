import Foundation
import Testing
@testable import Kiln

struct PingEvent: ModuleEvent, Encodable, Equatable {
    let eventType = "test.ping"
    let sourceModule: String
    let timestamp = Date()
    let message: String
}

struct OtherEvent: ModuleEvent, Encodable, Equatable {
    let eventType = "test.other"
    let sourceModule: String
    let timestamp = Date()
    let value: Int
}

@globalActor
actor TestBusActor {
    static let shared = TestBusActor()
}

actor Counter {
    private var values: [String] = []
    func add(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

struct ModuleEventBusTests {
    @Test func typedDeliveryReachesSubscriber() async {
        let bus = ModuleEventBus()
        let counter = Counter()
        _ = await bus.subscribe(PingEvent.self) { event in
            await counter.add(event.message)
        }
        await bus.publish(PingEvent(sourceModule: "test", message: "hello"))
        let received = await counter.snapshot()
        #expect(received == ["hello"])
    }

    @Test func eventsAreNotDeliveredToOtherTypes() async {
        let bus = ModuleEventBus()
        let counter = Counter()
        _ = await bus.subscribe(PingEvent.self) { _ in
            await counter.add("ping")
        }
        await bus.publish(OtherEvent(sourceModule: "test", value: 1))
        #expect(await counter.snapshot().isEmpty)
    }

    @Test func unsubscribeStopsDelivery() async {
        let bus = ModuleEventBus()
        let counter = Counter()
        let token = await bus.subscribe(PingEvent.self) { _ in
            await counter.add("ping")
        }
        await bus.publish(PingEvent(sourceModule: "test", message: "a"))
        await bus.unsubscribe(token)
        await bus.publish(PingEvent(sourceModule: "test", message: "b"))
        #expect(await counter.snapshot() == ["ping"])
    }

    @Test func catchAllObservesEveryEvent() async {
        let bus = ModuleEventBus()
        let counter = Counter()
        _ = await bus.subscribeAny { entry in
            await counter.add(entry.eventType)
        }
        await bus.publish(PingEvent(sourceModule: "test", message: "a"))
        await bus.publish(OtherEvent(sourceModule: "test", value: 2))
        let received = await counter.snapshot()
        #expect(received == ["test.ping", "test.other"])
    }

    @Test func historyIsBounded() async {
        let bus = ModuleEventBus()
        let total = ModuleEventBus.historyLimit + 10
        for index in 0..<total {
            await bus.publish(PingEvent(sourceModule: "test", message: "\(index)"))
        }
        let recent = await bus.recentEvents(limit: ModuleEventBus.historyLimit + 50)
        #expect(recent.count == ModuleEventBus.historyLimit)
        let lastMessage = String(data: recent.last?.payload ?? Data(), encoding: .utf8) ?? ""
        #expect(lastMessage.contains("\"\(total - 1)\""))
        let firstMessage = String(data: recent.first?.payload ?? Data(), encoding: .utf8) ?? ""
        #expect(firstMessage.contains("\"\(total - ModuleEventBus.historyLimit)\""))
    }

    @Test func payloadIsJSONEncoded() async throws {
        let bus = ModuleEventBus()
        _ = await bus.subscribeAny { _ in }
        await bus.publish(PingEvent(sourceModule: "test", message: "payload-check"))
        let recent = await bus.recentEvents(limit: 1)
        let payload = try #require(recent.first?.payload)
        let text = String(decoding: payload, as: UTF8.self)
        #expect(text.contains("payload-check"))
        #expect(text.contains("test.ping"))
        #expect(text.contains("test"))
    }
}

struct ServiceRegistryTests {
    protocol DemoService: Sendable {
        func value() -> Int
    }

    struct DemoServiceImpl: DemoService {
        let base: Int
        func value() -> Int { base }
    }

    struct OtherImpl: Sendable {}

    @Test func registerAndResolve() async {
        let registry = ServiceRegistry()
        await registry.register(DemoServiceImpl(base: 42), for: DemoService.self)
        let resolved = await registry.resolve(DemoService.self)
        #expect(resolved?.value() == 42)
    }

    @Test func namedResolutionIsSeparate() async {
        let registry = ServiceRegistry()
        await registry.register(DemoServiceImpl(base: 1), for: DemoService.self)
        await registry.register(DemoServiceImpl(base: 2), for: DemoService.self, name: "secondary")
        #expect(await registry.resolve(DemoService.self)?.value() == 1)
        #expect(await registry.resolve(DemoService.self, name: "secondary")?.value() == 2)
        #expect(await registry.resolve(DemoService.self, name: "missing") == nil)
    }

    @Test func wrongTypeResolvesNil() async {
        let registry = ServiceRegistry()
        await registry.register(OtherImpl(), for: OtherImpl.self)
        #expect(await registry.resolve(DemoService.self) == nil)
    }

    @Test func unregisterRemovesService() async {
        let registry = ServiceRegistry()
        await registry.register(DemoServiceImpl(base: 7), for: DemoService.self)
        #expect(await registry.registeredCount() == 1)
        await registry.unregister(DemoService.self)
        #expect(await registry.resolve(DemoService.self) == nil)
        #expect(await registry.registeredCount() == 0)
    }

    @Test func duplicateRegisterOverwrites() async {
        let registry = ServiceRegistry()
        await registry.register(DemoServiceImpl(base: 1), for: DemoService.self)
        await registry.register(DemoServiceImpl(base: 9), for: DemoService.self)
        #expect(await registry.resolve(DemoService.self)?.value() == 9)
        #expect(await registry.registeredCount() == 1)
    }
}
