import Foundation
import Testing
@testable import Kiln

struct GitServiceTests {
    private func tempDirectory() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-git-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private let service = GitService()

    @Test func initializeStatusStageCommitLog() async throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }

        #expect(await service.isRepository(root) == false)
        try await service.initializeRepository(at: root)
        #expect(await service.isRepository(root))

        try Data("v1\n".utf8).write(to: URL(fileURLWithPath: root + "/README.md"))
        var statuses = try await service.status(root)
        #expect(statuses.count == 1)
        #expect(statuses[0].statusCode == "??")
        #expect(statuses[0].staged == false)

        try await service.stage(root, paths: ["README.md"])
        statuses = try await service.status(root)
        #expect(statuses[0].statusCode == "A")
        #expect(statuses[0].staged)

        let diff = try await service.diff(root, staged: true)
        #expect(diff.contains("+v1"))

        try await service.commit(root, message: "initial commit")
        statuses = try await service.status(root)
        #expect(statuses.isEmpty)
        #expect((try await service.diff(root)).isEmpty)

        let commits = try await service.log(root)
        #expect(commits.count == 1)
        #expect(commits[0].subject == "initial commit")
        #expect(commits[0].hash.count >= 7)
    }

    @Test func nothingToCommitFailsCleanly() async throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await service.initializeRepository(at: root)
        do {
            _ = try await service.commit(root, message: "empty")
            Issue.record("expected failure")
        } catch let error as GitError {
            #expect(error == .nothingToCommit)
        }
    }

    @Test func emptyMessageIsRefused() async throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await service.initializeRepository(at: root)
        try await service.stage(root, paths: []) // no-op
        do {
            _ = try await service.commit(root, message: "   ")
            Issue.record("expected failure")
        } catch let error as GitError {
            #expect(error == .commandFailed("commit message is empty"))
        }
    }

    @Test func branchesAndCheckout() async throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await service.initializeRepository(at: root)
        try Data("x\n".utf8).write(to: URL(fileURLWithPath: root + "/a.txt"))
        try await service.stage(root, paths: ["a.txt"])
        try await service.commit(root, message: "first")

        try await service.createBranch(root, name: "feature/test")
        try await service.checkout(root, branch: "feature/test")
        let branches = try await service.branches(root)
        #expect(branches.current == "feature/test")
        #expect(branches.all.contains("main") || branches.all.contains("master"))
    }

    @Test func blameIdentifiesAuthorLines() async throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await service.initializeRepository(at: root)
        try Data("line one\nline two\n".utf8).write(to: URL(fileURLWithPath: root + "/b.txt"))
        try await service.stage(root, paths: ["b.txt"])
        try await service.commit(root, message: "add b")

        let blame = try await service.blame(root, path: "b.txt")
        #expect(blame.count == 2)
        #expect(blame[0].lineNumber == 1)
        #expect(blame[0].text == "line one")
        #expect(blame[1].text == "line two")
        #expect(!blame[0].author.isEmpty)
    }

    @Test func nonRepositoryOperationsFailCleanly() async {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        do {
            _ = try await service.status(root)
            Issue.record("expected failure")
        } catch let error as GitError {
            guard case .commandFailed = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type")
        }
    }
}
