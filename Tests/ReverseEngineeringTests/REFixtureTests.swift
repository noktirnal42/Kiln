import Foundation
import Testing
import AxiomCore
@testable import Kiln

/// Tests against `Tests/Fixtures/re-sample` (source beside it): functions add_numbers, scale_value, greet, main.
@MainActor
struct REFixtureTests {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/re-sample")

    private func call(_ tool: String, _ arguments: [String: Any], _ module: REModule) async throws -> [String: Any] {
        let text = try await REMCPTools.call(tool: tool, arguments: arguments, service: module)
        return (try JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    @Test func nativeImportFindsTheKnownString() async throws {
        let module = REModule()
        _ = try await module.importBinary(at: Self.fixture)
        let project = try #require(module.selected)
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let analysis = try await module.analysis(projectID: project.id)
        #expect(analysis.strings.contains { $0.value.contains("KILN-FIXTURE-GREETING") })
        #expect(analysis.engine.contains("otool"))
    }

    @Test(.enabled(if: Analyzer.radare2Available()))
    func radare2RecoversTheKnownFunctionsAndCallGraph() async throws {
        let module = REModule()
        _ = try await module.importBinary(at: Self.fixture)
        let project = try #require(module.selected)
        defer { try? FileManager.default.removeItem(at: project.folder) }
        _ = try await call("analyze_binary", ["project_id": project.id, "engine": "radare2"], module)
        let analysis = try await module.analysis(projectID: project.id)
        #expect(analysis.engine.contains("radare2"))
        func function(_ fragment: String) -> FunctionRecord? { analysis.functions.first { $0.name.contains(fragment) } }
        let add = try #require(function("add_numbers"))
        let main = try #require(function("main"))
        #expect(function("scale_value") != nil && function("greet") != nil)
        #expect(main.callees.contains(add.address) || main.callees.contains { ProjectStore.normalizedAddress($0) == ProjectStore.normalizedAddress(add.address) })
        #expect(analysis.warnings.contains { $0.contains("radare2") })
    }

    @Test func analystEditsAreRevisionCheckedAndUndoable() async throws {
        let module = REModule()
        _ = try await module.importBinary(at: Self.fixture)
        let project = try #require(module.selected)
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let start = try await module.analysis(projectID: project.id)
        let address = try #require(start.functions.first?.address ?? "100000460")
        let revision = start.revision

        let renamed = try await call("rename_function", ["project_id": project.id, "address": address, "name": "analyst_name", "expected_revision": revision], module)
        let revision2 = try #require(renamed["revision"] as? Int)
        #expect(revision2 == revision + 1)

        // A stale revision is rejected instead of overwriting newer work.
        await #expect(throws: (any Error).self) {
            _ = try await self.call("set_comment", ["project_id": project.id, "address": address, "comment": "late", "expected_revision": revision], module)
        }
        let commented = try await call("set_comment", ["project_id": project.id, "address": address, "comment": "checked", "expected_revision": revision2], module)
        let revision3 = try #require(commented["revision"] as? Int)
        let bookmarked = try await call("toggle_bookmark", ["project_id": project.id, "address": address, "expected_revision": revision3], module)
        let revision4 = try #require(bookmarked["revision"] as? Int)
        #expect((try await module.analysis(projectID: project.id)).bookmarks?.isEmpty == false)

        // Undo walks the analyst edit log (renames and comments); bookmarks are a separate toggle.
        func comment() async throws -> String? {
            try await module.analysis(projectID: project.id).functions.first { $0.address == address }?.comment
        }
        #expect(try await comment() == "checked")
        let undone = try await call("undo_edit", ["project_id": project.id, "expected_revision": revision4], module)
        let revision5 = try #require(undone["revision"] as? Int)
        #expect(try await comment() != "checked")
        _ = try await call("redo_edit", ["project_id": project.id, "expected_revision": revision5], module)
        #expect(try await comment() == "checked")
    }

    @Test func newToolsAreDeclaredWithTheRightAccess() {
        let byName = Dictionary(uniqueKeysWithValues: REMCPTools.definitions.map { ($0.name, $0) })
        for name in ["rename_function", "set_comment", "toggle_bookmark", "undo_edit", "redo_edit"] {
            #expect(byName[name]?.readOnly == false, "re_\(name) must be a write tool")
        }
        #expect(byName["scan_pointers"]?.readOnly == true)
        let engine = (byName["analyze_binary"]?.inputSchema["properties"] as? [String: Any])?["engine"]
        #expect(engine != nil)
    }
}

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE_GHIDRA"] == "1"), .serialized)
struct LiveGhidraFixtureTests {
    @Test func ghidraRecoversTheFixtureFunctionsStringAndDecompilation() async throws {
        let module = REModule()
        module.configureDiscoveredGhidra()
        #expect(module.isGhidraAvailable, "\(module.ghidraStatus)")
        _ = try await module.importBinary(at: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/re-sample"))
        let project = try #require(module.selected)
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let analysis = try await module.analyzeWithGhidra(projectID: project.id)
        let names = analysis.functions.map(\.name)
        // Ghidra names the Mach-O entry point `entry` rather than `main`.
        for expected in ["add_numbers", "scale_value", "greet", "entry", "printf"] {
            #expect(names.contains { $0.contains(expected) }, "missing \(expected) in \(names.prefix(20))")
        }
        let add = try #require(analysis.functions.first { $0.name.contains("add_numbers") })
        let entry = try #require(analysis.functions.first { $0.name == "entry" })
        let greet = try #require(analysis.functions.first { $0.name.contains("greet") })
        #expect(entry.callees.contains { ProjectStore.normalizedAddress($0) == ProjectStore.normalizedAddress(add.address) })
        #expect(entry.callees.contains { ProjectStore.normalizedAddress($0) == ProjectStore.normalizedAddress(greet.address) })
        #expect((add.code ?? "").contains("+"))
        #expect(analysis.strings.contains { $0.value.contains("KILN-FIXTURE-GREETING") })
        #expect(analysis.engine.hasPrefix("Ghidra"))
    }
}

/// Harder inputs than the plain C sample: a stripped binary (no symbols), C++ (mangled methods) and Swift. Opt-in with a real Ghidra.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE_GHIDRA"] == "1"), .serialized)
struct LiveGhidraHarderFixtureTests {
    private func analyse(_ name: String) async throws -> (Analysis, REModule, REModule.REProject) {
        let module = REModule()
        module.configureDiscoveredGhidra()
        #expect(module.isGhidraAvailable, "\(module.ghidraStatus)")
        _ = try await module.importBinary(at: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)"))
        let project = try #require(module.selected)
        let analysis = try await module.analyzeWithGhidra(projectID: project.id)
        return (analysis, module, project)
    }

    @Test func aStrippedBinaryStillYieldsFunctionsAndPseudocodeWithTheString() async throws {
        let (analysis, module, project) = try await analyse("re-sample-stripped")
        defer { try? FileManager.default.removeItem(at: project.folder) }
        print("HARDER stripped functions=\(analysis.functions.map(\.name))")
        #expect(analysis.functions.count >= 4)
        #expect(!analysis.functions.contains { $0.name == "add_numbers" || $0.name == "greet" }, "a stripped binary must not carry source names")
        var sawString = false
        for function in analysis.functions where !function.code.isEmpty {
            if try await module.decompilation(projectID: project.id, address: function.address).contains("KILN-FIXTURE-GREETING") { sawString = true }
        }
        #expect(sawString, "no decompiled function references the greeting string")
    }

    @Test func cppMethodsAreRecoveredWithTheirMangledOrDemangledNames() async throws {
        let (analysis, _, project) = try await analyse("re-sample-cpp")
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let names = analysis.functions.map(\.name)
        print("HARDER cpp functions=\(names)")
        #expect(names.contains { $0.contains("describe") })
        #expect(names.contains { $0.contains("Counter") && $0.contains("add") })
    }

    @Test func swiftFunctionsAreRecovered() async throws {
        let (analysis, _, project) = try await analyse("re-sample-swift")
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let names = analysis.functions.map(\.name)
        print("HARDER swift count=\(names.count) sample=\(names.prefix(12))")
        #expect(names.contains { $0.contains("fibonacci") })
        #expect(names.contains { $0.contains("greet") || $0.contains("Greeter") })
    }
}
