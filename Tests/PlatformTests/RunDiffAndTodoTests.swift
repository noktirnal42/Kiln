import Foundation
import Testing
@testable import Kiln

@Suite("Run diff")
struct RunDiffTests {
    @Test func linesShowChangesWithContextAndCollapseTheRest() {
        let old = (1...20).map { "line \($0)" }
        var new = old
        new[9] = "line 10 changed"
        new.insert("inserted", at: 15)
        let lines = UnifiedDiff.lines(old: old, new: new, context: 2)
        #expect(lines.filter { $0.kind == .added }.map(\.text) == ["line 10 changed", "inserted"])
        #expect(lines.filter { $0.kind == .removed }.map(\.text) == ["line 10"])
        #expect(lines.contains { $0.kind == .gap }, "far-apart changes are separated by a gap, not 20 lines of nothing")
        #expect(lines.first?.kind == .context && lines.first?.text == "line 8")
        #expect(!lines.contains { $0.text == "line 1" })
        #expect(lines.first { $0.text == "line 10 changed" }?.newNumber == 10)
        #expect(lines.first { $0.text == "line 10" }?.oldNumber == 10)
    }

    @Test func identicalTextHasNoLines() {
        #expect(UnifiedDiff.lines(old: ["a", "b"], new: ["a", "b"]).isEmpty)
    }

    private func project(_ tag: String) throws -> (root: URL, store: CheckpointStore) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-rundiff-\(tag)-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, CheckpointStore(directory: base.appendingPathComponent("checkpoints", isDirectory: true)))
    }

    private func edit(_ recorder: CheckpointRecorder, tool: String, path: String, call: String = UUID().uuidString, apply: () throws -> Void) rethrows {
        recorder.beforeTool(name: tool, argumentsJSON: "{\"path\":\"\(path)\"}", callID: call)
        try apply()
        recorder.afterTool(callID: call)
    }

    @Test func aRunsEditsCreationsAndDeletionsAreReadBackAndReverted() throws {
        let (root, store) = try project("full")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let keep = root.appendingPathComponent("keep.txt"), gone = root.appendingPathComponent("gone.txt"), made = root.appendingPathComponent("made.txt")
        try "one\ntwo\nthree\n".write(to: keep, atomically: true, encoding: .utf8)
        try "bye\n".write(to: gone, atomically: true, encoding: .utf8)

        let recorder = CheckpointRecorder(store: store, conversationID: UUID(), messageID: UUID(), workspaceRoot: root)
        try edit(recorder, tool: "edit_file", path: "keep.txt") { try "one\nTWO\nthree\nfour\n".write(to: keep, atomically: true, encoding: .utf8) }
        try edit(recorder, tool: "write_file", path: "made.txt") { try "new file\n".write(to: made, atomically: true, encoding: .utf8) }
        try edit(recorder, tool: "delete_file", path: "gone.txt") { try FileManager.default.removeItem(at: gone) }
        let manifest = try #require(recorder.finish())

        let files = RunDiff.files(manifest: manifest, store: store, workspaceRoot: root)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        #expect(byPath["keep.txt"]?.change == .modified)
        #expect(byPath["keep.txt"]?.additions == 2 && byPath["keep.txt"]?.deletions == 1)
        #expect(byPath["made.txt"]?.change == .added && byPath["made.txt"]?.additions == 1)
        #expect(byPath["gone.txt"]?.change == .deleted && byPath["gone.txt"]?.deletions == 1)
        #expect(files.allSatisfy { $0.canRevert })

        #expect(store.revert(file: "keep.txt", in: manifest, workspaceRoot: root) == "Restored keep.txt.")
        #expect(try String(contentsOf: keep, encoding: .utf8) == "one\ntwo\nthree\n")
        #expect(store.revert(file: "gone.txt", in: manifest, workspaceRoot: root) == "Restored gone.txt.")
        #expect(FileManager.default.fileExists(atPath: gone.path))
        #expect(store.revert(file: "made.txt", in: manifest, workspaceRoot: root) == "Moved made.txt to the Trash.")
        #expect(!FileManager.default.fileExists(atPath: made.path))
        #expect(RunDiff.files(manifest: manifest, store: store, workspaceRoot: root).isEmpty, "everything reverted: nothing left to show")
    }

    @Test func aFileChangedAfterTheRunIsNotRevertedOver() throws {
        let (root, store) = try project("late")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent("a.txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        let recorder = CheckpointRecorder(store: store, conversationID: UUID(), messageID: UUID(), workspaceRoot: root)
        try edit(recorder, tool: "write_file", path: "a.txt") { try "agent\n".write(to: file, atomically: true, encoding: .utf8) }
        let manifest = try #require(recorder.finish())
        try "someone else\n".write(to: file, atomically: true, encoding: .utf8)

        let shown = try #require(RunDiff.files(manifest: manifest, store: store, workspaceRoot: root).first)
        #expect(!shown.canRevert)
        #expect(store.revert(file: "a.txt", in: manifest, workspaceRoot: root).contains("changed after the run"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "someone else\n")
    }

    @Test func deletionAfterRunIsNotUndone() throws {
        let (root, store) = try project("deleted-later")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent("a.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)
        let conversation = UUID(), message = UUID()
        let recorder = CheckpointRecorder(store: store, conversationID: conversation, messageID: message, workspaceRoot: root)
        try edit(recorder, tool: "write_file", path: "a.txt") { try "agent".write(to: file, atomically: true, encoding: .utf8) }
        let manifest = try #require(recorder.finish())
        try FileManager.default.removeItem(at: file)
        #expect(try #require(RunDiff.files(manifest: manifest, store: store, workspaceRoot: root).first).canRevert == false)
        #expect(store.revert(file: "a.txt", in: manifest, workspaceRoot: root).contains("changed after the run"))
        let report = store.rewind(conversationID: conversation, messages: [message], from: message, workspaceRoot: root)
        #expect(report.skipped.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func recreatedFileAfterRunDeletionIsNotOverwritten() throws {
        let (root, store) = try project("recreated")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent("a.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)
        let recorder = CheckpointRecorder(store: store, conversationID: UUID(), messageID: UUID(), workspaceRoot: root)
        try edit(recorder, tool: "write_file", path: "a.txt") { try "agent".write(to: file, atomically: true, encoding: .utf8) }
        try edit(recorder, tool: "delete_file", path: "a.txt") { try FileManager.default.removeItem(at: file) }
        let manifest = try #require(recorder.finish())
        try "new work".write(to: file, atomically: true, encoding: .utf8)
        #expect(store.revert(file: "a.txt", in: manifest, workspaceRoot: root).contains("changed after the run"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "new work")
    }

    @Test func binaryFilesAreSummarisedNotDiffed() throws {
        let (root, store) = try project("bin")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent("b.bin")
        try Data([0, 1, 2]).write(to: file)
        let recorder = CheckpointRecorder(store: store, conversationID: UUID(), messageID: UUID(), workspaceRoot: root)
        try edit(recorder, tool: "write_file", path: "b.bin") { try Data([0, 9, 9]).write(to: file) }
        let manifest = try #require(recorder.finish())
        let shown = try #require(RunDiff.files(manifest: manifest, store: store, workspaceRoot: root).first)
        #expect(shown.summaryOnly && shown.lines.isEmpty)
    }
}

@Suite("Todo list")
struct TodoTests {
    private func context(_ id: UUID) -> ToolExecutionContext { ToolExecutionContext(workspaceRoot: nil, conversationID: id) }

    @Test func theToolStoresTheWholeListPerConversation() async throws {
        let board = TodoBoard.shared
        let a = UUID(), b = UUID()
        defer { board.clear(a); board.clear(b) }
        let out = try await TodoWriteTool().execute(
            argumentsJSON: #"{"todos":[{"content":"Read the code","status":"completed"},{"content":"Write the test","status":"in_progress"},{"content":"Run it"}]}"#, context: context(a))
        #expect(out == "Task list updated: 1 of 3 done · now: Write the test.")
        #expect(board.items(for: a).map(\.status) == [.completed, .in_progress, .pending])
        #expect(board.items(for: b).isEmpty)

        _ = try await TodoWriteTool().execute(argumentsJSON: #"{"todos":["just a string"]}"#, context: context(a))
        #expect(board.items(for: a).map(\.content) == ["just a string"], "each write replaces the list; bare strings are pending items")
        #expect(board.items(for: a).first?.status == .pending)

        let cleared = try await TodoWriteTool().execute(argumentsJSON: #"{"todos":[]}"#, context: context(a))
        #expect(cleared == "Task list cleared.")
        #expect(board.items(for: a).isEmpty)
    }

    @Test func unknownStatusesBecomePendingAndLongListsAreCapped() async throws {
        let id = UUID()
        defer { TodoBoard.shared.clear(id) }
        let many = (1...60).map { "{\"content\":\"step \($0)\",\"status\":\"weird\"}" }.joined(separator: ",")
        _ = try await TodoWriteTool().execute(argumentsJSON: "{\"todos\":[\(many)]}", context: context(id))
        let items = TodoBoard.shared.items(for: id)
        #expect(items.count == 40)
        #expect(items.allSatisfy { $0.status == .pending })
    }

    @Test func observersHearAboutChanges() async throws {
        let board = TodoBoard()
        let id = UUID()
        final class Box: @unchecked Sendable { var ids: [UUID] = [] }
        let box = Box()
        board.observe { box.ids.append($0) }
        board.set([TodoItem(id: 1, content: "x", status: .pending)], for: id)
        board.clear(id)
        #expect(box.ids == [id, id])
    }

    @Test func theToolIsAPlatformToolWithAReadPermission() {
        #expect(PlatformTools.all.contains { $0.spec.name == "kiln_todo_write" })
        #expect(TodoWriteTool().spec.permission == .read)
    }
}
