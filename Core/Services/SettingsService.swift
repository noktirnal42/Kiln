import Foundation

public enum SettingsLayer: String, Sendable, CaseIterable {
    case environment
    case user
    case workspace
    case defaults
}

public enum SettingsError: Error, Equatable, Sendable {
    case readOnlyLayer(SettingsLayer)
    case persistenceFailed(String)
}

public actor SettingsService {
    private struct StoreFile: Codable {
        var values: [String: Data] = [:]
    }

    private let environment: [String: String]
    private let environmentPrefix: String
    private let userConfigURL: URL?
    private let workspaceConfigURL: URL?
    private var userValues: [String: Data] = [:]
    private var workspaceValues: [String: Data] = [:]
    private var defaultValues: [String: Data] = [:]
    private var observers: [String: [UUID: AsyncStream<String>.Continuation]] = [:]

    public init(
        userConfigURL: URL?,
        workspaceConfigURL: URL? = nil,
        environmentPrefix: String = "SUPERMETA_",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
        self.environmentPrefix = environmentPrefix
        self.userConfigURL = userConfigURL
        self.workspaceConfigURL = workspaceConfigURL
        if let url = userConfigURL, let data = try? Data(contentsOf: url) {
            userValues = (try? JSONDecoder().decode(StoreFile.self, from: data))?.values ?? [:]
        }
        if let url = workspaceConfigURL, let data = try? Data(contentsOf: url) {
            workspaceValues = (try? JSONDecoder().decode(StoreFile.self, from: data))?.values ?? [:]
        }
    }

    public func registerDefault<T: Codable & Sendable>(_ key: String, _ value: T) {
        defaultValues[key] = try? JSONEncoder().encode(value)
    }

    public func get<T: Codable & Sendable>(_ key: String, as type: T.Type = T.self, fallback: T) -> T {
        if let value = environmentValue(key, as: T.self) { return value }
        if let data = userValues[key], let value = try? JSONDecoder().decode(T.self, from: data) { return value }
        if let data = workspaceValues[key], let value = try? JSONDecoder().decode(T.self, from: data) { return value }
        if let data = defaultValues[key], let value = try? JSONDecoder().decode(T.self, from: data) { return value }
        return fallback
    }

    public func set<T: Codable & Sendable>(_ value: T, forKey key: String, layer: SettingsLayer = .user) throws {
        guard layer == .user || layer == .workspace else {
            throw SettingsError.readOnlyLayer(layer)
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw SettingsError.persistenceFailed("encoding failed: \(error)")
        }
        switch layer {
        case .user:
            userValues[key] = data
            persist(userValues, to: userConfigURL)
        case .workspace:
            workspaceValues[key] = data
            persist(workspaceValues, to: workspaceConfigURL)
        case .environment, .defaults:
            break
        }
        notify(key)
    }

    public func removeValue(forKey key: String, layer: SettingsLayer) throws {
        guard layer == .user || layer == .workspace else {
            throw SettingsError.readOnlyLayer(layer)
        }
        switch layer {
        case .user:
            userValues.removeValue(forKey: key)
            persist(userValues, to: userConfigURL)
        case .workspace:
            workspaceValues.removeValue(forKey: key)
            persist(workspaceValues, to: workspaceConfigURL)
        case .environment, .defaults:
            break
        }
        notify(key)
    }

    public func observe(_ key: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let token = UUID()
            observers[key, default: [:]][token] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeObserver(key: key, token: token) }
            }
        }
    }

    private func removeObserver(key: String, token: UUID) {
        observers[key]?.removeValue(forKey: token)
        if observers[key]?.isEmpty == true {
            observers.removeValue(forKey: key)
        }
    }

    private func notify(_ key: String) {
        guard let continuations = observers[key] else { return }
        for continuation in continuations.values {
            continuation.yield(key)
        }
    }

    private func environmentKey(_ key: String) -> String {
        let normalized = key.uppercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        return environmentPrefix + String(normalized)
    }

    private func environmentValue<T: Codable & Sendable>(_ key: String, as type: T.Type) -> T? {
        guard let raw = environment[environmentKey(key)], !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8), let value = try? JSONDecoder().decode(T.self, from: data) {
            return value
        }
        if T.self == String.self, let value = raw as Any as? T {
            return value
        }
        return nil
    }

    private func persist(_ values: [String: Data], to url: URL?) {
        guard let url else { return }
        let file = StoreFile(values: values)
        do {
            let data = try JSONEncoder().encode(file)
            let directory = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            ModuleLogger(moduleIdentifier: "com.supermeta.kernel")
                .error("settings persist failed: \(String(describing: error))")
        }
    }
}
