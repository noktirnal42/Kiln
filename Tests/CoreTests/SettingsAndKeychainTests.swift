import Foundation
import Testing
@testable import Kiln

struct SettingsServiceTests {
    private func makeTempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-settings-\(UUID().uuidString).json")
        return url
    }

    @Test func fallsBackToDefault() async {
        let service = SettingsService(userConfigURL: nil, environment: [:])
        await service.registerDefault("greeting", "hi")
        let value = await service.get("greeting", as: String.self, fallback: "fallback")
        #expect(value == "hi")
    }

    @Test func fallsBackToFallbackWhenNothingRegistered() async {
        let service = SettingsService(userConfigURL: nil, environment: [:])
        let value = await service.get("missing.key", as: Int.self, fallback: 7)
        #expect(value == 7)
    }

    @Test func environmentOverridesDefaults() async {
        let service = SettingsService(userConfigURL: nil, environment: ["KILN_GREETING": "\"env\""])
        await service.registerDefault("greeting", "hi")
        let value = await service.get("greeting", as: String.self, fallback: "fallback")
        #expect(value == "env")
    }

    @Test func environmentAcceptsRawStringForStringType() async {
        let service = SettingsService(userConfigURL: nil, environment: ["KILN_APP_NAME": "Kiln"])
        let value = await service.get("app.name", as: String.self, fallback: "")
        #expect(value == "Kiln")
    }

    @Test func environmentParsesJSONTypes() async {
        let service = SettingsService(userConfigURL: nil, environment: [
            "KILN_LEVEL": "3",
            "KILN_FLAG": "true",
        ])
        let level = await service.get("level", as: Int.self, fallback: 0)
        let flag = await service.get("flag", as: Bool.self, fallback: false)
        #expect(level == 3)
        #expect(flag == true)
    }

    @Test func userLayerOverridesWorkspaceAndDefaults() async throws {
        let userFile = try makeTempFile()
        let workspaceFile = try makeTempFile()
        defer {
            try? FileManager.default.removeItem(at: userFile)
            try? FileManager.default.removeItem(at: workspaceFile)
        }
        let service = SettingsService(userConfigURL: userFile, workspaceConfigURL: workspaceFile, environment: [:])
        await service.registerDefault("theme", "light")
        try await service.set("dark", forKey: "theme", layer: .workspace)
        try await service.set("mono", forKey: "theme", layer: .user)
        let value = await service.get("theme", as: String.self, fallback: "light")
        #expect(value == "mono")
    }

    @Test func userLayerPersistsAcrossInstances() async throws {
        let userFile = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: userFile) }
        let first = SettingsService(userConfigURL: userFile, environment: [:])
        try await first.set(42, forKey: "answer", layer: .user)

        let second = SettingsService(userConfigURL: userFile, environment: [:])
        let value = await second.get("answer", as: Int.self, fallback: 0)
        #expect(value == 42)
    }

    @Test func removeValueClearsLayer() async throws {
        let userFile = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: userFile) }
        let service = SettingsService(userConfigURL: userFile, environment: [:])
        try await service.set("x", forKey: "key", layer: .user)
        try await service.removeValue(forKey: "key", layer: .user)
        #expect(await service.get("key", as: String.self, fallback: "fallback") == "fallback")
    }

    @Test func environmentAndDefaultsLayersAreReadOnly() async {
        let service = SettingsService(userConfigURL: nil, environment: [:])
        await #expect(throws: SettingsError.readOnlyLayer(.environment)) {
            try await service.set("x", forKey: "key", layer: .environment)
        }
        await #expect(throws: SettingsError.readOnlyLayer(.defaults)) {
            try await service.set("x", forKey: "key", layer: .defaults)
        }
    }

    @Test func observeYieldsOnSet() async {
        let service = SettingsService(userConfigURL: nil, environment: [:])
        let stream = await service.observe("watched")
        let counter = Counter()
        let task = Task {
            for await key in stream {
                await counter.add(key)
                break
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        try? await service.set("v", forKey: "watched", layer: .user)
        _ = await task.result
        #expect(await counter.snapshot() == ["watched"])
    }
}

struct KeychainServiceTests {
    private let uniqueKey = "test-\(UUID().uuidString)"
    private let moduleName = "com.test.keychain"

    @Test func setGetRoundTrip() throws {
        let keychain = KeychainService()
        defer { try? keychain.delete(module: moduleName, key: uniqueKey) }
        try keychain.set("secret-value", module: moduleName, key: uniqueKey)
        #expect(keychain.get(module: moduleName, key: uniqueKey) == "secret-value")
    }

    @Test func setOverwritesExistingValue() throws {
        let keychain = KeychainService()
        defer { try? keychain.delete(module: moduleName, key: uniqueKey) }
        try keychain.set("first", module: moduleName, key: uniqueKey)
        try keychain.set("second", module: moduleName, key: uniqueKey)
        #expect(keychain.get(module: moduleName, key: uniqueKey) == "second")
    }

    @Test func deleteRemovesValue() throws {
        let keychain = KeychainService()
        try keychain.set("value", module: moduleName, key: uniqueKey)
        try keychain.delete(module: moduleName, key: uniqueKey)
        #expect(keychain.get(module: moduleName, key: uniqueKey) == nil)
        try keychain.delete(module: moduleName, key: uniqueKey)
    }

    @Test func fingerprintIsSHA256HexAndNotTheSecret() {
        let fingerprint = KeychainService.fingerprint(of: "hunter2")
        #expect(fingerprint.count == 64)
        #expect(!fingerprint.contains("hunter2"))
        #expect(fingerprint == KeychainService.fingerprint(of: "hunter2"))
        #expect(fingerprint != KeychainService.fingerprint(of: "hunter3"))
    }

    @Test func fingerprintOfStoredSecret() throws {
        let keychain = KeychainService()
        defer { try? keychain.delete(module: moduleName, key: uniqueKey) }
        try keychain.set("fingerprintable", module: moduleName, key: uniqueKey)
        #expect(keychain.fingerprint(module: moduleName, key: uniqueKey) == KeychainService.fingerprint(of: "fingerprintable"))
    }
}
