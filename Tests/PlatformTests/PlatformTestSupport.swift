import Foundation
import SwiftData
import Testing
@testable import Kiln

enum PlatformTestSupport {
    static func tempDir(_ name: String = "platform") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func auditChain() throws -> AuditChain {
        AuditChain(directory: try tempDir("audit"))
    }
}
