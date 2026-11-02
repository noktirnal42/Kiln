import Foundation
import Testing
@testable import Kiln

struct LegacyContainerMigrationTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-home-\(UUID().uuidString)", isDirectory: true)
        let legacy = home.appendingPathComponent("Library/Containers/com.kiln.app/Data/Library/Application Support/Kiln", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "conversations".write(to: legacy.appendingPathComponent("Kiln.store"), atomically: true, encoding: .utf8)
        return home
    }

    @Test func copiesOldContainerDataOnceAndKeepsTheContainer() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let copied = LegacyContainerMigration.runIfNeeded(home: home, sandboxed: false)
        #expect(copied == ["Kiln"])
        let moved = home.appendingPathComponent("Library/Application Support/Kiln/Kiln.store")
        #expect(try String(contentsOf: moved, encoding: .utf8) == "conversations")

        try "newer".write(to: moved, atomically: true, encoding: .utf8)
        // The destination is now at least as recent as the container, so a second run changes nothing.
        #expect(LegacyContainerMigration.runIfNeeded(home: home, sandboxed: false).isEmpty)
        #expect(try String(contentsOf: moved, encoding: .utf8) == "newer")
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Containers/com.kiln.app").path))
    }

    @Test func doesNothingInsideTheSandbox() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(LegacyContainerMigration.runIfNeeded(home: home, sandboxed: true).isEmpty)
    }
}
