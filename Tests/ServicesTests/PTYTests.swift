import Foundation
import Testing
@testable import Kiln

struct PTYTests {
    private func tempDirectory() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-pty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func shellDetectionFindsShells() {
        let shells = ShellDetection.availableShells()
        #expect(!shells.isEmpty)
        #expect(FileManager.default.isExecutableFile(atPath: ShellDetection.detectShell()))
    }

    @Test func sessionEchoesInputAndTerminatesOnClose() async throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let manager = PTYManager(historyBaseDirectory: URL(fileURLWithPath: tempDirectory()))
        let info = try await manager.createSession(shell: "/bin/cat", workspaceRoot: root)
        let session = try #require(await manager.session(info.id))

        let received = BoundedDataCollector()
        session.onData { data in
            received.append(data)
        }
        session.write(Data("hello pty\n".utf8))
        try await waitUntil(timeout: .seconds(5)) {
            received.text().contains("hello pty")
        }
        #expect(received.text().contains("hello pty"))

        try session.resize(rows: 40, columns: 120)

        let terminatedFlag = TerminatedFlag()
        session.onTermination { _ in terminatedFlag.mark() }
        await manager.closeSession(info.id)
        try await waitUntil(timeout: .seconds(5)) { terminatedFlag.value }
        #expect(terminatedFlag.value)
        #expect(await manager.allSessions().isEmpty)
    }

    @Test func invalidWorkspaceRootIsRejectedWithSpecificReason() async {
        let manager = PTYManager()
        let missingRoot = "/nonexistent/\(UUID().uuidString)"
        do {
            _ = try await manager.createSession(workspaceRoot: missingRoot)
            Issue.record("expected failure")
        } catch let error as TerminalError {
            guard case .workspaceRootInvalid(let path) = error else {
                Issue.record("unexpected error kind")
                return
            }
            #expect(path == missingRoot)
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test func invalidShellIsRejected() async {
        let manager = PTYManager()
        do {
            _ = try await manager.createSession(shell: "/nonexistent/shell-\(UUID().uuidString)", workspaceRoot: "/tmp")
            Issue.record("expected failure")
        } catch let error as TerminalError {
            guard case .shellNotFound = error else {
                Issue.record("unexpected error kind")
                return
            }
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test func commandHistoryPersistsPerWorkspace() async throws {
        let historyBase = URL(fileURLWithPath: tempDirectory())
        defer { try? FileManager.default.removeItem(at: historyBase) }
        let root = tempDirectory()
        let manager = PTYManager(historyBaseDirectory: historyBase)
        await manager.recordInput("git status", workspaceRoot: root)
        await manager.recordInput("swift build", workspaceRoot: root)
        await manager.recordInput("   ", workspaceRoot: root)

        let history = await manager.history(workspaceRoot: root)
        #expect(history.map(\.line) == ["git status", "swift build"])

        let reloaded = PTYManager(historyBaseDirectory: historyBase)
        let persisted = await reloaded.history(workspaceRoot: root)
        #expect(persisted.map(\.line) == ["git status", "swift build"])

        await reloaded.recordInput("third command", workspaceRoot: root)
        let updated = await reloaded.history(workspaceRoot: root)
        #expect(updated.count == 3)

        let other = await reloaded.history(workspaceRoot: tempDirectory())
        #expect(other.isEmpty)
    }
}

func waitUntil(timeout: Duration, _ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

final class TerminatedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }
    func mark() {
        lock.lock()
        terminated = true
        lock.unlock()
    }
}

final class BoundedDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > 1 << 20 {
            data.removeFirst(data.count - (1 << 20))
        }
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
