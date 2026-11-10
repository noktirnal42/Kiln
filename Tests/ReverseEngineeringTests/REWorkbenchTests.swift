import Foundation
import Testing
import AxiomCore
@testable import Kiln

private let loopAsm = """
100000460  stp x29, x30, [sp, #-0x10]!
100000464  mov w8, #0x0
100000468  cmp w8, #0xa
10000046c  b.ge 0x100000480
100000470  bl 0x100000500 ; symbol stub for: _puts
100000474  add w8, w8, #0x1
100000478  b 0x100000468
10000047c  nop
100000480  ldp x29, x30, [sp], #0x10
100000484  ret
"""

private func function(_ name: String, _ address: String, _ asm: String, callees: [String] = [], callers: [String] = []) -> FunctionRecord {
    FunctionRecord(address: address, name: name, assembly: asm)
        .with { $0.callees = callees; $0.callers = callers }
}
private extension FunctionRecord { func with(_ change: (inout FunctionRecord) -> Void) -> FunctionRecord { var copy = self; change(&copy); return copy } }

private func analysis(_ functions: [FunctionRecord], strings: [StringRecord] = []) -> Analysis {
    Analysis(binaryPath: "/tmp/x", sha256: "00", size: 1, format: "Mach-O 64-bit executable arm64", engine: "test", sections: "", hex: "", functions: functions, strings: strings)
}

struct REWorkbenchTests {
    @Test func listingParsesAndClassifiesBranches() throws {
        let line = try #require(REListing.parseLine("0000000100000470\tbl\t0x100000500 ; symbol stub for: _puts"))
        #expect(line.address == 0x100000470 && line.mnemonic == "bl" && line.comment == "symbol stub for: _puts")
        #expect(REListing.branchTarget(line) == 0x100000500)
        #expect(REListing.branchKind("b.ge") == .conditional && REListing.branchKind("jne") == .conditional)
        #expect(REListing.branchKind("ret").endsBlock && !REListing.branchKind("bl").endsBlock)
        // Stack offsets and small immediates are not links.
        #expect(REListing.addressTokens(in: "ldp x29, x30, [sp], #0x10").isEmpty)
        #expect(REListing.addressTokens(in: "adrp x0, 0x100003000").count == 1)
    }

    @Test func cfgSplitsBlocksAndFindsTheLoop() {
        let graph = CFGBuilder.build(function: function("loop", "100000460", loopAsm), names: [0x100000500: "_puts"])
        #expect(graph.source == "derived")
        #expect(graph.nodes.map(\.address) == [0x100000460, 0x100000468, 0x100000470, 0x10000047c, 0x100000480])
        #expect(graph.edges.contains { $0.from == 0x100000478 || $0.from == 0x100000470 })
        #expect(graph.edges.contains { $0.kind == .back && $0.to == 0x100000468 })
        #expect(graph.edges.contains { $0.from == 0x100000468 && $0.to == 0x100000480 && $0.kind == .taken })
        #expect(graph.nodes.first { $0.address == 0x100000470 }?.calls == ["_puts"])
        #expect(graph.complexity >= 2)
        #expect(graph.nodes.allSatisfy { $0.frame.width > 0 })
        #expect(graph.dot().contains("digraph"))
    }

    @Test func callGraphHasCallersAbove() throws {
        let a = analysis([function("main", "1000", "1000  bl 0x2000", callees: ["2000"]), function("mid", "2000", "2000  bl 0x3000", callees: ["3000"], callers: ["1000"]), function("leaf", "3000", "3000  ret", callers: ["2000"])])
        let graph = try #require(CallGraph.build(analysis: a, root: "2000", depth: 2))
        #expect(Set(graph.nodes.map(\.name)) == ["main", "mid", "leaf"])
        #expect(graph.nodes.first { $0.name == "main" }?.depth == -1 && graph.nodes.first { $0.name == "leaf" }?.depth == 1)
        #expect(graph.edges.count == 2)
        #expect(CallGraph.build(analysis: a, root: "9999") == nil)
    }

    @Test func xrefsCoverCallsJumpsAndStrings() {
        let a = analysis([function("main", "100000460", "100000460  bl 0x100000500\n100000464  adrp x0, 0x100000f00\n100000468  add x0, x0, #0x1 ; literal pool for: \"hello\"\n10000046c  ret"),
                          function("helper", "100000500", "100000500  ret", callers: ["100000460"])], strings: [StringRecord(offset: 0xf00, value: "hello")])
        let index = REXrefIndex.build(a)
        #expect(index.callers(of: 0x100000500).first?.fromFunction == "main")
        #expect(index.references(toString: "hello").count == 1)
        #expect(index.resolve("helper") == .function(address: "100000500", name: "helper"))
        #expect(index.resolve("hello") == .string(offset: 0xf00, value: "hello"))
    }

    @Test func hexSearchAndPatchNeverTouchTheOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("re-hex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("bin")
        try Data([0, 1, 2, 0xde, 0xad, 0xbe, 0xef, 9, 9]).write(to: original)
        #expect(try REHex.search(original, pattern: REHex.pattern("de ad ?? ef")) == [3])
        #expect(try REHex.search(original, pattern: REHex.pattern("0xdeadbeef")) == [3])
        #expect(throws: (any Error).self) { try REHex.pattern("zz") }
        let map = REAddressMap(segments: [])
        let patch = try REPatcher.makePatch(binary: original, map: map, address: 3, bytes: Data([0x90, 0x90]), note: "nop")
        #expect(patch.original == "dead")
        #expect(throws: (any Error).self) { try REPatcher.apply([patch], to: original, output: original) }
        let copy = folder.appendingPathComponent("bin.patched")
        let hash = try REPatcher.apply([patch], to: original, output: copy)
        #expect(hash.count == 64)
        #expect(try Data(contentsOf: copy) == Data([0, 1, 2, 0x90, 0x90, 0xbe, 0xef, 9, 9]))
        #expect(try Data(contentsOf: original) == Data([0, 1, 2, 0xde, 0xad, 0xbe, 0xef, 9, 9]))
        // A patch made for another build is refused.
        try Data([0, 1, 2, 7, 7, 7, 7, 9, 9]).write(to: original)
        #expect(throws: (any Error).self) { try REPatcher.apply([patch], to: original, output: folder.appendingPathComponent("again")) }
        #expect(try REPatcher.nop(architecture: "arm64", length: 8) == Data([0x1f, 0x20, 0x03, 0xd5, 0x1f, 0x20, 0x03, 0xd5]))
    }

    @Test func addressMapReadsLoadCommands() {
        let sections = """
        Load command 1
              cmd LC_SEGMENT_64
          cmdsize 72
          segname __PAGEZERO
           vmaddr 0x0000000000000000
           vmsize 0x0000000100000000
          fileoff 0
         filesize 0
        Load command 2
              cmd LC_SEGMENT_64
          segname __TEXT
           vmaddr 0x0000000100000000
           vmsize 0x0000000000004000
          fileoff 0
         filesize 16384
        """
        let map = REAddressMap.parse(sections: sections)
        #expect(map.fileOffset(forAddress: 0x100000460) == 0x460)
        #expect(map.address(forFileOffset: 0x460) == 0x100000460)
        #expect(map.fileOffset(forAddress: 0x200000000) == nil)
    }

    @Test func structuresLayOutLikeC() throws {
        let list = try REStructureParser.parse("struct Header { uint8_t kind; uint32_t length; char name[6]; void *next; };")
        let s = try #require(list.first)
        #expect(s.fields.map(\.offset) == [0, 4, 8, 16])
        #expect(s.size == 24 && s.alignment == 8)
        let nested = try REStructureParser.parse("struct Outer { struct Header h; int tail; };", existing: list)
        #expect(nested[0].fields[1].offset == 24 && nested[0].size == 32)
        #expect(throws: (any Error).self) { try REStructureParser.parse("struct Bad { Unknown x; };") }
        #expect(s.declaration.contains("+0x10"))
        var workspace = REWorkspace()
        workspace.setStructures(list)
        #expect(workspace.undoStructures() && workspace.structures.isEmpty && workspace.redoStructures() && workspace.structures.count == 1)
    }

    @Test func diffFindsChangedAddedRemoved() {
        let a = analysis([function("keep", "1000", "1000  mov x0, x1\n1004  ret"), function("edit", "2000", "2000  mov x0, #1\n2004  add x0, x0, #2\n2008  ret"), function("gone", "3000", "3000  nop\n3004  ret")])
        let b = analysis([function("keep", "5000", "5000  mov x0, x1\n5004  ret"), function("edit", "6000", "6000  mov x0, #1\n6004  sub x0, x0, #2\n6008  ret"), function("new", "7000", "7000  brk #1")])
        let result = REDiff.compare(a, b)
        #expect(result.unchanged == 1 && result.changed.map(\.nameA) == ["edit"] && result.removed.map(\.nameA) == ["gone"] && result.added.map(\.nameB) == ["new"])
        #expect(REDiff.listingDiff(a.functions[1], b.functions[1]).contains { $0.hasPrefix("- add") } )
    }

    @Test func reportIncludesFindingsAndEvidence() {
        var workspace = REWorkspace()
        workspace.findings = [REFinding(title: "Hardcoded key", severity: .high, summary: "Key in __data", address: "100000460", function: "main", evidence: ["100000464 adrp x0"])]
        let md = REReport.markdown(analysis: analysis([function("main", "100000460", "100000460  ret")]), workspace: workspace)
        #expect(md.contains("Hardcoded key") && md.contains("high") && md.contains("Listing of `main`"))
        #expect(REReport.html(fromMarkdown: md, title: "t").contains("<h3>"))
    }

    @Test func debugPlanQuotesAndLimits() throws {
        let plan = try REDebugLink.plan(mode: .inspect, program: URL(fileURLWithPath: "/usr/bin/true"), breakpoints: [0x1000])
        #expect(plan.commands.contains { $0.contains("--address 0x1000") } && !plan.commands.contains { $0.hasPrefix("process launch") })
        let launch = try REDebugLink.plan(mode: .launch, program: URL(fileURLWithPath: "/usr/bin/true"), breakpoints: [])
        #expect(launch.commands.contains { $0.hasPrefix("process launch --stop-at-entry") })
        #expect(throws: (any Error).self) { try REDebugLink.plan(mode: .attach, program: URL(fileURLWithPath: "/x"), breakpoints: []) }
    }

    @Test func packageInspectorReadsAnIPA() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("re-ipa-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.demo", "CFBundleExecutable": "Demo", "CFBundleShortVersionString": "1.2", "MinimumOSVersion": "16.0", "CFBundleName": "Demo"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try Data("_OBJC_CLASS_$_DemoController\0".utf8).write(to: app.appendingPathComponent("Demo"))
        let ipa = root.appendingPathComponent("demo.ipa")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = root
        zip.arguments = ["-qr", ipa.path, "Payload"]; try zip.run(); zip.waitUntilExit()
        let report = try REPackage.inspect(ipa)
        #expect(report.kind == .ipa && report.identifier == "com.example.demo" && report.executable == "Payload/Demo.app/Demo")
        #expect(report.classes == ["DemoController"])
        let out = try REPackage.extract(ipa, entry: "Payload/Demo.app/Demo", into: root.appendingPathComponent("out"))
        #expect(out.lastPathComponent == "Demo")
    }

    @Test func toolPermissionsFollowTheRules() {
        let defs = Dictionary(uniqueKeysWithValues: REMCPTools.definitions.map { ($0.name, $0) })
        for name in ["get_cfg", "get_call_graph", "get_references", "read_bytes", "search_bytes", "diff_projects", "inspect_package", "plan_debugger", "list_structures"] { #expect(defs[name]?.readOnly == true, "\(name)") }
        for name in ["create_patch", "export_patched", "annotate_address", "define_structure", "add_finding", "export_report"] { #expect(defs[name]?.readOnly == false && defs[name]?.executes == false, "\(name)") }
        for name in ["run_debugger", "run_script"] { #expect(defs[name]?.executes == true, "\(name)") }
    }
}

@MainActor
struct REWorkbenchFixtureTests {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/re-sample")
    private func call(_ tool: String, _ args: [String: Any], _ module: REModule) async throws -> [String: Any] {
        let text = try await REMCPTools.call(tool: tool, arguments: args, service: module)
        return (try JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    @Test func endToEndOnTheFixture() async throws {
        let module = REModule()
        _ = try await module.importBinary(at: Self.fixture)
        let project = try #require(module.selected)
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let analysis = try await module.analysis(projectID: project.id)
        let main = try #require(analysis.functions.first { $0.name.contains("main") })

        let cfg = try await call("get_cfg", ["project_id": project.id, "function": main.address], module)
        #expect((cfg["blocks"] as? [[String: Any]])?.isEmpty == false)

        let refs = try await call("get_references", ["project_id": project.id, "target": "KILN-FIXTURE-GREETING"], module)
        #expect(refs["count"] != nil)

        let bytes = try await call("read_bytes", ["project_id": project.id, "address": main.address, "length": 32], module)
        #expect((bytes["rows"] as? [[String: Any]])?.count == 2)

        let found = try await call("search_bytes", ["project_id": project.id, "pattern": "\"KILN-FIXTURE-GREETING\""], module)
        #expect((found["count"] as? Int ?? 0) >= 1)

        let patch = try await call("create_patch", ["project_id": project.id, "address": main.address, "nop_length": 4, "note": "test"], module)
        #expect(patch["bytes"] as? String == "1f2003d5")
        let exported = try await call("export_patched", ["project_id": project.id], module)
        let path = try #require(exported["path"] as? String)
        #expect(path != Self.fixture.path && FileManager.default.fileExists(atPath: path))
        // The fixture is untouched.
        let original = try Data(contentsOf: Self.fixture), copy = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(original != copy && original.count == copy.count)

        _ = try await call("define_structure", ["project_id": project.id, "source": "struct Pair { int a; int b; };"], module)
        let listed = try await call("list_structures", ["project_id": project.id], module)
        #expect((listed["structures"] as? [[String: Any]])?.count == 1)

        _ = try await call("add_finding", ["project_id": project.id, "title": "Greeting string", "summary": "Fixture string", "function": main.name], module)
        let report = try await call("export_report", ["project_id": project.id], module)
        let md = try String(contentsOfFile: try #require(report["markdown"] as? String), encoding: .utf8)
        #expect(md.contains("Greeting string"))

        let script = try await call("run_script", ["project_id": project.id, "source": "re.functions().length"], module)
        #expect((script["result"] as? String).flatMap(Int.init) == analysis.functions.count)

        let inspect = try await call("run_debugger", ["project_id": project.id, "addresses": [main.address], "mode": "inspect"], module)
        #expect((inspect["commands"] as? [String])?.contains { $0.contains("breakpoint set") } == true)
    }
}
