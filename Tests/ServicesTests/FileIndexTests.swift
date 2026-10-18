import Foundation
import Testing
@testable import SuperMetaApp

struct FileIndexServiceTests {
    private func tempDirectory() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermeta-fileindex-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func indexesAndSearchesWithFTS5() async throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sub = root + "/Sources"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/ChatSession.swift"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: sub + "/ChatSessionTests.swift"))
        try FileManager.default.createDirectory(atPath: root + "/node_modules", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/node_modules/ignored.js"))

        let service = FileIndexService()
        try await service.index(root: root)

        let indexed = await service.indexedFiles()
        #expect(indexed.count == 2)
        #expect(indexed.contains { $0.path == "ChatSession.swift" })
        #expect(indexed.contains { $0.path == "Sources/ChatSessionTests.swift" })
        #expect(await service.indexedRootPath() == root)

        let hits = await service.search("ChatSession", limit: 20, includeSpotlight: false)
        #expect(!hits.isEmpty)
        #expect(hits.contains { $0.file.name == "ChatSession.swift" })
        #expect(hits.contains { $0.file.name == "ChatSessionTests.swift" })
        #expect(hits.allSatisfy { $0.sources.contains(.fts5) })

        let empty = await service.search("", limit: 10, includeSpotlight: false)
        #expect(empty.isEmpty)
    }

    @Test func searchRanksPrefixMatchesFirst() async throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/zchatmodel.swift"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/chatmodel.swift"))

        let service = FileIndexService()
        try await service.index(root: root)
        let hits = await service.search("chatmodel", limit: 10, includeSpotlight: false)
        #expect(hits.count == 1)
        #expect(hits.first?.file.name == "chatmodel.swift")
        let wider = await service.search("chatmodel*", limit: 10, includeSpotlight: false)
        #expect(wider.count == 1)
    }

    @Test func invalidRootFailsCleanly() async {
        let service = FileIndexService()
        do {
            try await service.index(root: "/nonexistent/\(UUID().uuidString)")
            Issue.record("expected failure")
        } catch {
            // specific launchFailed reason
            #expect(String(describing: error).contains("not a directory"))
        }
    }

    @Test func fileRootIsRejected() async {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try? Data("x".utf8).write(to: URL(fileURLWithPath: root + "/only-a-file.txt"))
        let service = FileIndexService()
        do {
            try await service.index(root: root + "/only-a-file.txt")
            Issue.record("expected failure")
        } catch {
            #expect(String(describing: error).contains("not a directory"))
        }
    }
}
