import Foundation

public actor ServiceRegistry {
    private struct Key: Hashable {
        let typeID: ObjectIdentifier
        let name: String?
    }

    private var services: [Key: Any] = [:]

    public init() {}

    public func register<T: Sendable>(_ service: T, for type: T.Type, name: String? = nil) {
        services[Key(typeID: ObjectIdentifier(type), name: name)] = service
    }

    public func resolve<T: Sendable>(_ type: T.Type, name: String? = nil) -> T? {
        services[Key(typeID: ObjectIdentifier(type), name: name)] as? T
    }

    public func unregister<T: Sendable>(_ type: T.Type, name: String? = nil) {
        services.removeValue(forKey: Key(typeID: ObjectIdentifier(type), name: name))
    }

    public func registeredCount() async -> Int {
        services.count
    }
}
