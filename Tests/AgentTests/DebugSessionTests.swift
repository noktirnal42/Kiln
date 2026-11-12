import Foundation
import Testing
@testable import Kiln

/// Drives the real `lldb` from the Xcode toolchain against a tiny Swift package built on the fly.
@MainActor
@Suite(.serialized)
struct DebugSessionTests {
    private func buildFixture() throws -> (root: URL, source: URL, program: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-dbg-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources/dbg", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "dbg", targets: [.executableTarget(name: "dbg")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let source = sources.appendingPathComponent("main.swift")
        try """
        func compute(_ n: Int) -> Int {
            let doubled = n * 2
            let total = doubled + 1
            return total
        }
        print("result:", compute(20))
        """.write(to: source, atomically: true, encoding: .utf8)
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.arguments = ["swift", "build", "--package-path", root.path]
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try build.run()
        build.waitUntilExit()
        #expect(build.terminationStatus == 0)
        return (root, source, root.appendingPathComponent(".build/debug/dbg").path)
    }

    private func waitFor(_ session: DebugSession, timeout: Double = 30, _ done: (DebugSession.State) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !done(session.state) { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test(.enabled(if: DebugSession.isAvailable))
    func hitsABreakpointShowsLocalsStepsAndRunsToTheEnd() async throws {
        let fixture = try buildFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = DebugSession()
        defer { session.reset() }
        session.breakpoints = [fixture.source.path: [3]]
        await session.start(program: fixture.program, workingDirectory: fixture.root)

        try await waitFor(session, timeout: 15) { if case .paused = $0 { true } else { false } }
        if !session.isPaused { Issue.record("state=\(session.state) console=\(session.console.prefix(600))") }
        #expect(session.isPaused)
        for _ in 0..<100 where session.variables.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        for _ in 0..<100 where session.frames.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        let top = try #require(session.frames.first)
        #expect(top.line == 3 && top.name.contains("compute"))
        #expect(session.currentLocation?.line == 3 && session.currentLocation?.path.hasSuffix("main.swift") == true)
        #expect(session.variables.contains { $0.name == "doubled" && $0.value == "40" })
        #expect(session.variables.contains { $0.name == "n" && $0.value == "20" })

        await session.stepOver()
        try await waitFor(session) { if case .paused = $0 { true } else { false } }
        for _ in 0..<100 where session.frames.first?.line != 4 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(session.frames.first?.line == 4)

        await session.resume()
        try await waitFor(session) { if case .finished = $0 { true } else { false } }
        #expect(session.state == .finished(exitCode: 0))
        #expect(session.console.contains("result: 41"))
    }

    @Test(.enabled(if: DebugSession.isAvailable))
    func stopEndsARunningSession() async throws {
        let fixture = try buildFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = DebugSession()
        defer { session.reset() }
        session.breakpoints = [fixture.source.path: [3]]
        await session.start(program: fixture.program, workingDirectory: fixture.root)
        try await waitFor(session) { if case .paused = $0 { true } else { false } }
        await session.stop()
        #expect(!session.isActive)
    }

    @Test func parsesLLDBOutput() throws {
        let frame = try #require(LLDBOutput.frame("  * frame #0: compute(n=20) at /p/Sources/dbg/main.swift:3:25"))
        #expect(frame.id == 0 && frame.name == "compute(n=20)" && frame.path == "/p/Sources/dbg/main.swift" && frame.line == 3 && frame.column == 25)
        let system = try #require(LLDBOutput.frame("    frame #2: start"))
        #expect(system.path == nil && system.name == "start")
        let variable = try #require(LLDBOutput.variable("(Int) doubled = 40"))
        #expect(variable.name == "doubled" && variable.value == "40" && variable.type == "Int")
        #expect(LLDBOutput.exitStatus("Process 28010 exited with status = 3 (0x00000003) ") == 3)
        #expect(LLDBOutput.breakpointID("Breakpoint 2: where = dbg`compute(_:) + 60 at main.swift:3:25") == 2)
        #expect(LLDBOutput.stopReason("* thread #1, queue = 'q', stop reason = breakpoint 1.1") == "breakpoint 1.1")
        #expect(LLDBOutput.frame("result: 41") == nil && LLDBOutput.variable("result: 41") == nil)
    }

    @Test func aMissingAdapterFailsInsteadOfHanging() async {
        let session = DebugSession(command: "definitely-not-a-debugger")
        await session.start(program: "/usr/bin/true", workingDirectory: FileManager.default.temporaryDirectory)
        if case .failed = session.state {} else { Issue.record("expected failed, got \(session.state)") }
    }

    @Test(.enabled(if: DebugSession.isAvailable))
    func removingOneOfSeveralBreakpointsRemovesTheCorrectLLDBBreakpoint() async throws {
        let fixture = try buildFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = DebugSession()
        defer { session.reset() }
        session.breakpoints = [fixture.source.path: [2, 3]]
        await session.start(program: fixture.program, workingDirectory: fixture.root)
        try await waitFor(session) { if case .paused = $0 { true } else { false } }
        #expect(session.isPaused)
        session.toggleBreakpoint(path: fixture.source.path, line: 3)
        await session.resume()
        try await waitFor(session) { if case .finished = $0 { true } else { false } }
        #expect(session.state == .finished(exitCode: 0), "Removed breakpoint must not stop execution: \(session.console)")
        #expect(session.console.contains("result: 41"))
    }

    @Test(.enabled(if: DebugSession.isAvailable))
    func aFinishedSessionCanRestartBeforeTheOldDebuggerExits() async throws {
        let fixture = try buildFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = DebugSession()
        defer { session.reset() }
        for _ in 0..<3 {
            await session.start(program: fixture.program, workingDirectory: fixture.root)
            try await waitFor(session) { if case .finished = $0 { true } else { false } }
            #expect(session.state == .finished(exitCode: 0))
            #expect(session.console.contains("result: 41"))
        }
    }

    @Test(.enabled(if: DebugSession.isAvailable))
    func aMissingProgramFailsAndAllowsAnotherStart() async throws {
        let session = DebugSession()
        defer { session.reset() }
        await session.start(program: "/no/such/kiln-debug-fixture", workingDirectory: FileManager.default.temporaryDirectory)
        if case .failed = session.state {} else { Issue.record("Expected launch failure, got \(session.state)") }
        #expect(!session.isActive)
    }

    @Test(.enabled(if: DebugSession.isAvailable))
    func changingProjectsStopsThePreviousDebugger() async throws {
        let fixture = try buildFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let editor = EditorWorkspace()
        editor.setRoot(fixture.root.path)
        let session = editor.debug
        defer { session.reset() }
        session.breakpoints = [fixture.source.path: [3]]
        await session.start(program: fixture.program, workingDirectory: fixture.root)
        try await waitFor(session) { if case .paused = $0 { true } else { false } }
        #expect(session.isPaused)
        editor.setRoot(fixture.root.appendingPathComponent("another-project").path)
        #expect(!session.isActive)
        #expect(session.frames.isEmpty && session.breakpoints.isEmpty)
    }

    @Test(.enabled(if: DebugSession.isAvailable))
    func breakpointsDoNotMatchAnotherTargetsSameNamedSource() async throws {
        let fixture = try buildFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for module in ["First", "Second"] {
            let directory = fixture.root.appendingPathComponent("Sources/" + module)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let function = module.lowercased()
            try "public func \(function)(_ n: Int) -> Int {\n    return n + 1\n}\n".write(to: directory.appendingPathComponent("Logic.swift"), atomically: true, encoding: .utf8)
        }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "dbg", targets: [.target(name: "First"), .target(name: "Second"), .executableTarget(name: "dbg", dependencies: ["First", "Second"])])
        """.write(to: fixture.root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "import First\nimport Second\nprint(first(5), second(8))\n".write(to: fixture.source, atomically: true, encoding: .utf8)
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.arguments = ["swift", "build", "--package-path", fixture.root.path]
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try build.run()
        build.waitUntilExit()
        #expect(build.terminationStatus == 0)
        let session = DebugSession()
        defer { session.reset() }
        session.breakpoints = [fixture.root.appendingPathComponent("Sources/First/Logic.swift").path: [2]]
        await session.start(program: fixture.program, workingDirectory: fixture.root)
        try await waitFor(session) { if case .paused = $0 { true } else { false } }
        #expect(session.isPaused)
        for _ in 0..<100 where session.frames.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(session.frames.first?.name.contains("first") == true)
        await session.resume()
        try await waitFor(session) { if case .finished = $0 { true } else { false } }
        #expect(session.state == .finished(exitCode: 0))
        #expect(session.console.contains("6 9"))
    }

    @Test func debuggerSourceAliasesReuseAnAlreadyOpenDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-debug-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("main.swift")
        try "print(42)\n".write(to: source, atomically: true, encoding: .utf8)
        let editor = EditorWorkspace()
        let original = editor.open(source)
        let fromDebugger = editor.open(URL(fileURLWithPath: DebugSession.canonicalSourcePath(source.path)), line: 1)
        #expect(original.id == fromDebugger.id)
        #expect(editor.documents.count == 1)
    }

    @Test func preparingABuildPreservesAnotherProjectsUnsavedDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-build-saves-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let unrelated = root.appendingPathComponent("project-other")
        for directory in [project, unrelated] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let own = project.appendingPathComponent("main.swift")
        let other = unrelated.appendingPathComponent("main.swift")
        for file in [own, other] { try "original\n".write(to: file, atomically: true, encoding: .utf8) }
        let editor = EditorWorkspace()
        editor.languageServerEnabled = false
        editor.setRoot(project.path)
        let ownDocument = editor.open(own)
        let otherDocument = editor.open(other)
        ownDocument.text = "current project edit\n"
        otherDocument.text = "unrelated recovered draft\n"
        #expect(editor.saveProjectDocuments())
        #expect(try String(contentsOf: own, encoding: .utf8) == "current project edit\n")
        #expect(try String(contentsOf: other, encoding: .utf8) == "original\n")
        #expect(otherDocument.isDirty && editor.hasUnsavedChanges)
    }

    @Test func buildSettingsSelectAnExecutableInsteadOfASchemeDependency() {
        let settings = #"[{"target":"Support","buildSettings":{"MACH_O_TYPE":"staticlib","TARGET_BUILD_DIR":"/tmp/Build","EXECUTABLE_PATH":"libSupport.a"}},{"target":"My App's Scheme","buildSettings":{"MACH_O_TYPE":"mh_execute","TARGET_BUILD_DIR":"/tmp/Build","EXECUTABLE_PATH":"My App.app/Contents/MacOS/My App"}}]"#
        #expect(ProgramResolver.parseBuildSettings(settings, preferredTarget: "My App's Scheme") == "/tmp/Build/My App.app/Contents/MacOS/My App")
        #expect(ProgramResolver.parseBuildSettings("    TARGET_BUILD_DIR = /tmp/Build\n    EXECUTABLE_PATH = App.app/Contents/MacOS/App") == "/tmp/Build/App.app/Contents/MacOS/App")
    }

    @Test func togglingBreakpointsAddsAndRemoves() {
        let session = DebugSession()
        defer { session.reset() }
        session.toggleBreakpoint(path: "/p/a.swift", line: 5)
        session.toggleBreakpoint(path: "/p/a.swift", line: 9)
        #expect(session.breakpoints["/p/a.swift"] == [5, 9])
        session.toggleBreakpoint(path: "/p/a.swift", line: 5)
        session.toggleBreakpoint(path: "/p/a.swift", line: 9)
        #expect(session.breakpoints.isEmpty)
    }
}
