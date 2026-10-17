import Testing
@testable import SuperMetaApp

struct ModuleCapabilitiesTests {
    @Test func parsesKnownNames() {
        let (known, unknown) = ModuleCapabilities.parse(["fileSystem.read", "process.spawn", "systemInfo"])
        #expect(known.contains(.fileSystemRead))
        #expect(known.contains(.processSpawn))
        #expect(known.contains(.systemInfo))
        #expect(unknown.isEmpty)
    }

    @Test func reportsUnknownNames() {
        let (known, unknown) = ModuleCapabilities.parse(["fileSystem.read", "not.a.capability", "alsoUnknown"])
        #expect(known == .fileSystemRead)
        #expect(unknown == ["not.a.capability", "alsoUnknown"])
    }

    @Test func compoundNameExpandsToReadAndWrite() {
        let (known, unknown) = ModuleCapabilities.parse(["fileSystem.readWrite"])
        #expect(known == [.fileSystemRead, .fileSystemWrite])
        #expect(unknown.isEmpty)
    }

    @Test func namesRoundTrip() {
        let caps: ModuleCapabilities = [.fileSystemRead, .networkClient, .metalCompute, .systemInfo]
        let parsed = ModuleCapabilities.parse(caps.names)
        #expect(parsed.known == caps)
        #expect(parsed.unknown.isEmpty)
    }

    @Test func subtractionComputesMissing() {
        let granted: ModuleCapabilities = [.fileSystemRead]
        let required: ModuleCapabilities = [.fileSystemRead, .fileSystemWrite, .processSpawn]
        let missing = required.subtracting(granted)
        #expect(missing == [.fileSystemWrite, .processSpawn])
        #expect(missing.names == ["fileSystem.write", "process.spawn"])
    }
}

struct SemVerTests {
    @Test func parsesVersions() {
        #expect(SemVer(parsing: "1.2.3") == SemVer(major: 1, minor: 2, patch: 3))
        #expect(SemVer(parsing: "2.0") == SemVer(major: 2, minor: 0, patch: 0))
        #expect(SemVer(parsing: "5") == SemVer(major: 5, minor: 0, patch: 0))
        #expect(SemVer(parsing: "abc") == nil)
        #expect(SemVer(parsing: "1.x.3") == nil)
    }

    @Test func comparison() {
        #expect(SemVer(parsing: "1.9.9")! < SemVer(parsing: "1.10.0")!)
        #expect(SemVer(parsing: "2.0.0")! > SemVer(parsing: "1.99.99")!)
    }
}
