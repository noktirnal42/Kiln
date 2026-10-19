import XCTest
@testable import AxiomCore

final class AxiomCoreTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axiom-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func sample() -> Analysis {
        Analysis(binaryPath: "/tmp/x", sha256: "00", size: 1, format: "test", engine: "test", sections: "", hex: "",
                 functions: [FunctionRecord(address: "00001000", name: "_main")], strings: [])
    }

    func testSignatureEditIsLoggedUndoableAndKeepsEngineSignature() throws {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        var analysis = sample(); analysis.functions = [FunctionRecord(address: "00001000", name: "f", signature: "int f(int param_1)")]
        try ProjectStore.create(analysis, to: path); analysis = try ProjectStore.load(path)
        var p = try ProjectStore.edit(path, expectedRevision: analysis.revision, address: "00001000", signature: "long f(long param_1)")
        XCTAssertEqual(p.functions[0].signature, "long f(long param_1)"); XCTAssertEqual(p.functions[0].engineSignature, "int f(int param_1)")
        XCTAssertEqual(p.edits?.last?.field, "signature")
        p = try ProjectStore.undo(path, expectedRevision: p.revision); XCTAssertEqual(p.functions[0].signature, "int f(int param_1)")
        p = try ProjectStore.redo(path, expectedRevision: p.revision); XCTAssertEqual(p.functions[0].signature, "long f(long param_1)")
        XCTAssertThrowsError(try ProjectStore.edit(path, expectedRevision: p.revision, address: "00001000", signature: "a\nb"))
    }

    func testAddressCommentsAndLabelsAreLoggedUndoableAndRemovable() throws {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        try ProjectStore.create(sample(), to: path)
        var p = try ProjectStore.annotate(path, expectedRevision: 0, address: "0x00001010", comment: "loop counter", label: "retry_loop")
        XCTAssertEqual(p.addressComments?["1010"], "loop counter"); XCTAssertEqual(p.addressLabels?["1010"], "retry_loop")
        XCTAssertEqual(p.edits?.map(\.field), ["addressComment", "label"]); XCTAssertEqual(p.edits?.first?.address, "1010")
        XCTAssertEqual(p.revision, 1)
        p = try ProjectStore.annotate(path, expectedRevision: 1, address: "1010", comment: "loop counter")   // unchanged: no log entry
        XCTAssertEqual(p.edits?.count, 2)
        p = try ProjectStore.undo(path, expectedRevision: p.revision)
        XCTAssertNil(p.addressLabels, "undoing the first label removes it (empty old value)"); XCTAssertEqual(p.addressComments?["1010"], "loop counter")
        p = try ProjectStore.undo(path, expectedRevision: p.revision); XCTAssertNil(p.addressComments)
        p = try ProjectStore.redo(path, expectedRevision: p.revision); XCTAssertEqual(p.addressComments?["1010"], "loop counter")
        p = try ProjectStore.annotate(path, expectedRevision: p.revision, address: "1010", comment: "")   // empty removes
        XCTAssertNil(p.addressComments); XCTAssertEqual(p.edits?.last?.new, "")
        p = try ProjectStore.undo(path, expectedRevision: p.revision); XCTAssertEqual(p.addressComments?["1010"], "loop counter", "undo of a removal restores it")
    }

    func testAddressAnnotationValidationAndConflicts() throws {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        try ProjectStore.create(sample(), to: path)
        XCTAssertThrowsError(try ProjectStore.annotate(path, expectedRevision: 0, address: "zz", comment: "x"))
        XCTAssertThrowsError(try ProjectStore.annotate(path, expectedRevision: 0, address: "", comment: "x"))
        XCTAssertThrowsError(try ProjectStore.annotate(path, expectedRevision: 0, address: "1000", comment: "a\nb"))
        XCTAssertThrowsError(try ProjectStore.annotate(path, expectedRevision: 0, address: "1000", label: "bad label"))
        XCTAssertThrowsError(try ProjectStore.annotate(path, expectedRevision: 5, address: "1000", comment: "x"), "stale revision")
        _ = try ProjectStore.annotate(path, expectedRevision: 0, address: "1000", comment: "ok")
        XCTAssertThrowsError(try ProjectStore.annotate(path, expectedRevision: 0, address: "1000", comment: "again"), "revision moved on")
    }

    func testProjectsWithoutAddressAnnotationsStillDecode() throws {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        try ProjectStore.create(sample(), to: path)
        let loaded = try ProjectStore.load(path)
        XCTAssertNil(loaded.addressComments); XCTAssertNil(loaded.addressLabels)
    }

    func testVariableChangesMergeLogUndoAndClear() throws {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        var base = sample(); base.functions = [FunctionRecord(address: "00001000", name: "f")]
        try ProjectStore.create(base, to: path)
        var p = try ProjectStore.changeVariable(path, expectedRevision: 0, address: "0x1000", id: "EDI:4", name: "count")
        p = try ProjectStore.changeVariable(path, expectedRevision: p.revision, address: "1000", id: "EDI:4", type: "long")
        XCTAssertEqual(p.variableChanges?["1000"]?["EDI:4"], VariableChange(name: "count", type: "long"), "name and type merge into one change")
        XCTAssertEqual(p.edits?.filter { $0.field == "variable" }.count, 2)
        XCTAssertEqual(p.edits?.last?.old, "EDI:4\tcount\t"); XCTAssertEqual(p.edits?.last?.new, "EDI:4\tcount\tlong")
        p = try ProjectStore.changeVariable(path, expectedRevision: p.revision, address: "1000", id: "EDI:4", name: "count")   // unchanged: no log entry
        XCTAssertEqual(p.edits?.count, 2)
        p = try ProjectStore.undo(path, expectedRevision: p.revision); XCTAssertEqual(p.variableChanges?["1000"]?["EDI:4"], VariableChange(name: "count", type: nil))
        p = try ProjectStore.undo(path, expectedRevision: p.revision); XCTAssertNil(p.variableChanges, "undoing the first change leaves nothing")
        p = try ProjectStore.redo(path, expectedRevision: p.revision); XCTAssertEqual(p.variableChanges?["1000"]?["EDI:4"]?.name, "count")
        p = try ProjectStore.changeVariable(path, expectedRevision: p.revision, address: "1000", id: "EDI:4", name: "", type: ""); XCTAssertNil(p.variableChanges, "empty strings clear both parts")
    }

    func testVariableChangeValidation() throws {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        var base = sample(); base.functions = [FunctionRecord(address: "00001000", name: "f")]
        try ProjectStore.create(base, to: path)
        XCTAssertThrowsError(try ProjectStore.changeVariable(path, expectedRevision: 0, address: "9999", id: "EDI:4", name: "x"), "unknown function")
        XCTAssertThrowsError(try ProjectStore.changeVariable(path, expectedRevision: 0, address: "1000", id: "", name: "x"))
        XCTAssertThrowsError(try ProjectStore.changeVariable(path, expectedRevision: 0, address: "1000", id: "EDI:4", name: "bad name"))
        XCTAssertThrowsError(try ProjectStore.changeVariable(path, expectedRevision: 0, address: "1000", id: "EDI:4", type: "a\nb"))
        XCTAssertThrowsError(try ProjectStore.changeVariable(path, expectedRevision: 3, address: "1000", id: "EDI:4", name: "x"), "stale revision")
    }

    func testTransactionAppliesEverythingOrNothingUnderOneRevisionBump() throws {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        var base = sample(); base.functions = [FunctionRecord(address: "00001000", name: "f")]
        try ProjectStore.create(base, to: path)
        let p = try ProjectStore.transact(path, expectedRevision: 0, [
            .function(address: "00001000", name: "decode", comment: "reads input", signature: nil),
            .addressNote(address: "1010", comment: "loop", label: "again"),
            .variable(address: "1000", id: "EDI:4", name: "count", type: nil)])
        XCTAssertEqual(p.revision, 1, "one bump for the whole transaction")
        XCTAssertEqual(p.functions[0].name, "decode"); XCTAssertEqual(p.addressLabels?["1010"], "again"); XCTAssertEqual(p.variableChanges?["1000"]?["EDI:4"]?.name, "count")
        XCTAssertEqual(p.edits?.count, 5)
        // A later operation fails: nothing from this transaction may reach the disk.
        XCTAssertThrowsError(try ProjectStore.transact(path, expectedRevision: 1, [
            .function(address: "00001000", name: "renamed_again", comment: nil, signature: nil),
            .addressNote(address: "2020", comment: nil, label: "bad label with spaces")]))
        let after = try ProjectStore.load(path)
        XCTAssertEqual(after.revision, 1); XCTAssertEqual(after.functions[0].name, "decode", "the valid first operation was rolled back with the failing one")
        XCTAssertNil(after.addressLabels?["2020"])
        XCTAssertThrowsError(try ProjectStore.transact(path, expectedRevision: 0, [.function(address: "00001000", name: "x", comment: nil, signature: nil)]), "stale revision")
    }

    func testReanalysisKeepsAddressNotesAndVariableChanges() throws {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        var base = sample(); base.functions = [FunctionRecord(address: "00001000", name: "f")]
        try ProjectStore.create(base, to: path)
        _ = try ProjectStore.transact(path, expectedRevision: 0, [.addressNote(address: "1010", comment: "c", label: "l"), .variable(address: "1000", id: "EDI:4", name: "n", type: nil)])
        let current = try ProjectStore.load(path)
        var fresh = current; fresh.addressComments = nil; fresh.addressLabels = nil; fresh.variableChanges = nil   // what an engine re-analysis produces
        let replaced = try ProjectStore.replace(fresh, to: path, expectedID: current.id, expectedRevision: current.revision, preserveAnnotations: true)
        XCTAssertEqual(replaced.addressComments?["1010"], "c"); XCTAssertEqual(replaced.addressLabels?["1010"], "l"); XCTAssertEqual(replaced.variableChanges?["1000"]?["EDI:4"]?.name, "n")
    }

    func testEditsRecordWhoMadeThemWhenAProvenanceScopeIsBound() throws {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        try ProjectStore.create(sample(), to: path)
        _ = try ProjectStore.annotate(path, expectedRevision: 0, address: "1000", comment: "by the analyst")
        _ = try EditSource.$current.withValue("agent:claude-code") { try EditSource.$rationale.withValue("checks the length") { try ProjectStore.annotate(path, expectedRevision: 1, address: "1004", comment: "by an agent") } }
        let edits = try ProjectStore.load(path).edits ?? []
        XCTAssertNil(edits[0].source); XCTAssertEqual(edits[1].source, "agent:claude-code"); XCTAssertEqual(edits[1].rationale, "checks the length")
    }

    func testEngineWorkspaceFallsBackOutsideHiddenFolders() {
        let support = URL(fileURLWithPath: "/Users/a/Library/Application Support")
        XCTAssertEqual(Analyzer.engineWorkspace(projectPath: "/Users/a/QA/p.axiom", projectID: "ID1", supportDirectory: support), "/Users/a/QA/p.axiom/engine")
        XCTAssertEqual(Analyzer.engineWorkspace(projectPath: "/Users/a/.hidden/p.axiom", projectID: "ID1", supportDirectory: support), "/Users/a/Library/Application Support/AxiomRE/engine/ID1")
    }

    func testGhidraWorkspaceRejectsHiddenPathComponents() throws {
        XCTAssertThrowsError(try Analyzer.validateGhidraWorkspace("/Users/a/.runtime/proj/engine")) { XCTAssertTrue($0.localizedDescription.contains(".runtime")) }
        XCTAssertNoThrow(try Analyzer.validateGhidraWorkspace("/Users/a/QA/proj.axiom/engine"))
    }

    func testExtractStringsFindsPrintableRunsWithOffsets() {
        var bytes: [UInt8] = [0, 1, 2]
        bytes += Array("hello world".utf8) + [0] + Array("ab".utf8) + [0] + Array("tail".utf8)
        let found = Analyzer.extractStrings(Data(bytes))
        XCTAssertEqual(found.map(\.value), ["hello world", "tail"])
        XCTAssertEqual(found.first?.offset, 3)
    }

    func testParseAssemblySplitsFunctions() {
        let text = "_main:\n0000000100000f00\tsub\tsp, sp, #0x20\n0000000100000f04\tret\n_other:\n0000000100000f10\tret\n"
        let functions = Analyzer.parseAssembly(text)
        XCTAssertEqual(functions.map(\.name), ["_main", "_other"])
        XCTAssertEqual(functions[0].address, "0000000100000f00")
        XCTAssertEqual(functions[0].assembly.split(separator: "\n").count, 2)
    }

    func testProjectRoundTripAndEditBumpsRevision() throws {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        try ProjectStore.save(sample(), to: path)
        let edited = try ProjectStore.edit(path, expectedRevision: 0, address: "00001000", name: "entry", comment: "note")
        XCTAssertEqual(edited.revision, 1)
        let loaded = try ProjectStore.load(path)
        XCTAssertEqual(loaded.functions[0].name, "entry")
        XCTAssertEqual(loaded.functions[0].comment, "note")
    }

    func testBookmarksToggleSurviveReplaceAndRejectBadInput() throws {
        let path = try tempDir().appendingPathComponent("b.axiom").path
        let created = sample()
        try ProjectStore.create(created, to: path)
        let marked = try ProjectStore.toggleBookmark(path, expectedRevision: 0, address: "0x00001000")
        XCTAssertEqual(marked.bookmarks, ["1000"]); XCTAssertEqual(marked.revision, 1)
        XCTAssertThrowsError(try ProjectStore.toggleBookmark(path, expectedRevision: 0, address: "1000"))
        XCTAssertThrowsError(try ProjectStore.toggleBookmark(path, expectedRevision: 1, address: "9999"))
        let replaced = try ProjectStore.replace(created, to: path, expectedID: marked.id, expectedRevision: 1, preserveAnnotations: true)
        XCTAssertEqual(replaced.bookmarks, ["1000"])
        let cleared = try ProjectStore.toggleBookmark(path, expectedRevision: 2, address: "1000")
        XCTAssertNil(cleared.bookmarks)
    }

    func testEditsAreLoggedAndUndoRedoRestoreValues() throws {
        let path = try tempDir().appendingPathComponent("u.axiom").path
        try ProjectStore.create(sample(), to: path)
        var p = try ProjectStore.edit(path, expectedRevision: 0, address: "00001000", name: "decode", comment: "reads input")
        XCTAssertEqual(p.edits?.map(\.field), ["name", "comment"])
        p = try ProjectStore.edit(path, expectedRevision: 1, address: "00001000", name: "decode")   // unchanged: no log entry
        XCTAssertEqual(p.edits?.count, 2)
        p = try ProjectStore.undo(path, expectedRevision: p.revision)
        XCTAssertEqual(p.functions[0].comment, ""); XCTAssertEqual(p.functions[0].name, "decode"); XCTAssertEqual(p.undone?.count, 1)
        p = try ProjectStore.undo(path, expectedRevision: p.revision)
        XCTAssertEqual(p.functions[0].name, "_main")
        XCTAssertThrowsError(try ProjectStore.undo(path, expectedRevision: p.revision))
        p = try ProjectStore.redo(path, expectedRevision: p.revision)
        XCTAssertEqual(p.functions[0].name, "decode")
        p = try ProjectStore.edit(path, expectedRevision: p.revision, address: "00001000", comment: "new")   // new edit clears redo
        XCTAssertNil(p.undone)
        XCTAssertThrowsError(try ProjectStore.redo(path, expectedRevision: p.revision))
        XCTAssertThrowsError(try ProjectStore.undo(path, expectedRevision: 0))
    }

    func testEditRejectsStaleRevisionAndBadInput() throws {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        try ProjectStore.save(sample(), to: path)
        _ = try ProjectStore.edit(path, expectedRevision: 0, address: "00001000", name: "a")
        XCTAssertThrowsError(try ProjectStore.edit(path, expectedRevision: 0, address: "00001000", name: "b"))
        XCTAssertThrowsError(try ProjectStore.edit(path, expectedRevision: 1, address: "dead", name: "b"))
        XCTAssertThrowsError(try ProjectStore.edit(path, expectedRevision: 1, address: "00001000", name: "bad\nname"))
        XCTAssertThrowsError(try ProjectStore.edit(path, expectedRevision: 1, address: "00001000", name: ""))
    }

    func testStaleLockIsReportedNotIgnored() throws {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        try ProjectStore.save(sample(), to: path)
        try FileManager.default.createDirectory(atPath: path + "/.edit-lock", withIntermediateDirectories: false)
        XCTAssertThrowsError(try ProjectStore.edit(path, expectedRevision: 0, address: "00001000", name: "a"))
    }

    func testCreateNeverOverwritesAndReplacementPreservesAnnotations() throws {
        let path = try tempDir().appendingPathComponent("p.axiom").path
        let original = sample()
        try ProjectStore.create(original, to: path)
        XCTAssertThrowsError(try ProjectStore.create(sample(), to: path))
        let edited = try ProjectStore.edit(path, expectedRevision: 0, address: "00001000", name: "analyst", comment: "evidence")
        var exported = sample()
        exported.functions = [FunctionRecord(address: "1000", name: "recovered", code: "return 7;")]
        let merged = try ProjectStore.replace(exported, to: path, expectedID: original.id, expectedRevision: edited.revision, preserveAnnotations: true)
        XCTAssertEqual(merged.id, original.id)
        XCTAssertEqual(merged.revision, 2)
        XCTAssertEqual(merged.functions[0].name, "analyst")
        XCTAssertEqual(merged.functions[0].engineName, "recovered")
        XCTAssertEqual(merged.functions[0].comment, "evidence")
        XCTAssertThrowsError(try ProjectStore.replace(exported, to: path, expectedID: original.id, expectedRevision: 1))
        exported.sha256 = "changed"
        XCTAssertThrowsError(try ProjectStore.replace(exported, to: path, expectedID: original.id, expectedRevision: 2))
        XCTAssertEqual(try ProjectStore.load(path).functions[0].name, "analyst")
    }

    func testInspectRejectsDirectoryAndMissingFile() throws {
        XCTAssertThrowsError(try Analyzer.inspect(try tempDir().path))
        XCTAssertThrowsError(try Analyzer.inspect("/nonexistent/axiom"))
    }

    func testInspectCompiledFixture() throws {
        let dir = try tempDir()
        let source = dir.appendingPathComponent("f.c"), out = dir.appendingPathComponent("f")
        try "int assess(int v){return v>42?v*3:v+7;} int main(void){return assess(1);}".write(to: source, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run("/usr/bin/clang", ["-O0", "-o", out.path, source.path])
        let analysis = try Analyzer.inspect(out.path)
        XCTAssertTrue(analysis.format.contains("Mach-O"))
        XCTAssertTrue(analysis.functions.contains { $0.name == "_assess" })
        XCTAssertEqual(analysis.sha256.count, 64)
    }

    func testUniversalBinarySliceSelection() throws {
        let dir = try tempDir()
        let source = dir.appendingPathComponent("u.c"), fat = dir.appendingPathComponent("u")
        try "int assess(int v){return v>42?v*3:v+7;} int main(void){return assess(1);}".write(to: source, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run("/usr/bin/clang", ["-O0", "-arch", "arm64", "-arch", "x86_64", "-o", fat.path, source.path])
        let dataBefore = try Data(contentsOf: fat)
        let defaulted = try Analyzer.inspect(fat.path)
        XCTAssertEqual(Set(defaulted.slices ?? []), ["arm64", "x86_64"])
        XCTAssertEqual(defaulted.slice, Analyzer.preferredSlice(defaulted.slices ?? []))
        XCTAssertEqual(defaulted.functions.filter { $0.name == "_assess" }.count, 1, "only one slice's functions are listed")
        XCTAssertEqual(defaulted.binaryPath, fat.path)
        let x86 = try Analyzer.inspect(fat.path, arch: "x86_64")
        XCTAssertEqual(x86.slice, "x86_64")
        XCTAssertEqual(x86.sha256, defaulted.sha256, "identity is the chosen file, not the slice")
        XCTAssertNotEqual(x86.functions.first { $0.name == "_assess" }?.assembly, try Analyzer.inspect(fat.path, arch: "arm64").functions.first { $0.name == "_assess" }?.assembly)
        XCTAssertThrowsError(try Analyzer.inspect(fat.path, arch: "armv7")) { XCTAssertTrue($0.localizedDescription.contains("Available")) }
        let thin = dir.appendingPathComponent("thin")
        _ = try ProcessRunner.run("/usr/bin/clang", ["-o", thin.path, source.path])
        XCTAssertNil(try Analyzer.inspect(thin.path).slices)
        XCTAssertThrowsError(try Analyzer.inspect(thin.path, arch: "arm64"))
        XCTAssertEqual(try Data(contentsOf: fat), dataBefore)
    }

    func testProcessRunnerTimesOutAndReportsFailure() {
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.3))
        XCTAssertThrowsError(try ProcessRunner.run("/usr/bin/false", []))
    }

    func testParseRadare2BuildsCallGraphBlocksAndSourceLines() {
        let output = """
        INFO: noise on stderr
        AXIOM_AFL
        [{"addr":4096,"name":"sym._leaf","signature":"int leaf();"},{"addr":8192,"name":"sym._root","signature":""}]
        AXIOM_PDF
        {"name":"sym._leaf","size":8,"addr":4096,"ops":[{"addr":4096,"disasm":"ret","type":"ret"}]}
        {"name":"sym._root","size":12,"addr":8192,"ops":[{"addr":8192,"disasm":"bl 0x1000","type":"call","jump":4096,"addrline":{"file":"/src/x.c","line":7}},{"addr":8196,"disasm":"ret","type":"ret"}]}
        AXIOM_BB
        [{"addr":4096,"jump":null,"size":4}]
        [{"addr":8192,"jump":8196,"fail":8200,"size":4}]
        """
        let parsed = Analyzer.parseRadare2(output)
        XCTAssertEqual(parsed.functions.map(\.name), ["_leaf", "_root"])
        XCTAssertEqual(parsed.functions[1].callees, ["1000"])
        XCTAssertEqual(parsed.functions[0].callers, ["2000"])
        XCTAssertTrue(parsed.functions[1].assembly.contains("; x.c:7"))
        XCTAssertEqual(parsed.functions[1].blocks?.first?.destinations, ["2004", "2008"])
    }

    func testRadare2AnalyzesCompiledFixture() throws {
        try XCTSkipUnless(Analyzer.radare2Available(), "radare2 not installed")
        let dir = try tempDir()
        let source = dir.appendingPathComponent("f.c"), out = dir.appendingPathComponent("f")
        try "int assess(int v){return v>42?v*3:v+7;} int main(void){return assess(1);}".write(to: source, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run("/usr/bin/clang", ["-O0", "-o", out.path, source.path])
        let analysis = try Analyzer.radare2(out.path)
        let assess = try XCTUnwrap(analysis.functions.first { $0.name.hasSuffix("assess") })
        let main = try XCTUnwrap(analysis.functions.first { $0.name.hasSuffix("main") })
        XCTAssertTrue(main.callees.contains(assess.address))
        XCTAssertTrue(assess.callers.contains(main.address))
        XCTAssertFalse(assess.blocks?.isEmpty ?? true)
        XCTAssertTrue(analysis.engine.hasPrefix("radare2"))
    }
}
