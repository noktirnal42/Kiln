import Foundation
import Testing
import AxiomCore
@testable import Kiln

struct GhidraInstallationTests {
    private func fixture(_ root: URL, _ name: String, version: String, release: String = "PUBLIC", executable: Bool = true) throws -> URL {
        let home = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("support"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Ghidra"), withIntermediateDirectories: true)
        let launcher = home.appendingPathComponent("support/analyzeHeadless")
        try "#!/bin/sh\nexit 1\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: launcher.path)
        try "application.version=\(version)\napplication.release.name=\(release)\n".write(to: home.appendingPathComponent("Ghidra/application.properties"), atomically: true, encoding: .utf8)
        return home
    }

    @Test func prefersTheHighestStableVersionOverDevelopmentBuilds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-ghidra-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root, "ghidra_12.2_DEV", version: "12.2", release: "DEV")
        _ = try fixture(root, "ghidra_12.1.9_PUBLIC", version: "12.1.9")
        let expected = try fixture(root, "ghidra_12.1.10_PUBLIC", version: "12.1.10")
        #expect(GhidraInstallation.discover(environment: [:], applicationDirectories: [root])?.path == expected.path)
    }

    @Test func validEnvironmentHomeWinsAndInvalidHomeFallsBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-ghidra-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let release = try fixture(root, "ghidra_12.1.4_PUBLIC", version: "12.1.4")
        let explicit = try fixture(root, "ghidra_custom", version: "11.3.2")
        #expect(GhidraInstallation.discover(environment: ["GHIDRA_HOME": explicit.path], applicationDirectories: [root])?.path == explicit.path)
        #expect(GhidraInstallation.discover(environment: ["GHIDRA_HOME": root.appendingPathComponent("missing").path], applicationDirectories: [root])?.path == release.path)
    }

    @Test func ignoresNonExecutableAndUnsupportedInstallations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-ghidra-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root, "ghidra_12_PUBLIC", version: "12", executable: false)
        _ = try fixture(root, "ghidra_10_PUBLIC", version: "10.4")
        #expect(GhidraInstallation.discover(environment: [:], applicationDirectories: [root]) == nil)
    }

    @Test func installationsListsEveryUsableGhidraBestFirstAndAChosenOneWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-ghidra-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fixture(root, "ghidra_11.3.2_PUBLIC", version: "11.3.2")
        let stable = try fixture(root, "ghidra_12.1.4_PUBLIC", version: "12.1.4")
        let dev = try fixture(root, "ghidra_12.2_DEV", version: "12.2", release: "DEV")
        _ = try fixture(root, "ghidra_10_PUBLIC", version: "10.4")
        let all = GhidraInstallation.installations(environment: [:], applicationDirectories: [root])
        #expect(all.map(\.home.path) == [stable.path, old.path, dev.path].map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        #expect(all.last?.label == "Ghidra 12.2 (development build)")
        #expect(GhidraInstallation.discover(environment: [:], applicationDirectories: [root], preferred: dev)?.path == dev.standardizedFileURL.path)
        #expect(GhidraInstallation.discover(environment: [:], applicationDirectories: [root], preferred: root.appendingPathComponent("gone"))?.path == stable.standardizedFileURL.path)
    }

    @Test func rejectionExplainsWhyAFolderCannotBeUsed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-ghidra-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("not_ghidra")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let tooOld = try fixture(root, "ghidra_10_PUBLIC", version: "10.4")
        let good = try fixture(root, "ghidra_12_PUBLIC", version: "12.0")
        #expect(GhidraInstallation.rejection(for: empty)?.contains("analyzeHeadless") == true)
        #expect(GhidraInstallation.rejection(for: tooOld)?.contains("older than 11") == true)
        #expect(GhidraInstallation.rejection(for: good) == nil)
    }

    @Test func exporterIsBundledWithTheApp() throws {
        let script = try #require(GhidraInstallation.exporter())
        #expect(FileManager.default.fileExists(atPath: script.appendingPathComponent("AxiomExport.java").path))
    }
}

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE_GHIDRA"] == "1"), .serialized)
struct LiveGhidraTests {
    @Test func configuredEngineProducesPersistedPseudocodeThroughTheAgentTool() async throws {
        let module = REModule()
        module.configureDiscoveredGhidra()
        #expect(module.isGhidraAvailable, "\(module.ghidraStatus)")
        _ = try await module.importBinary(at: URL(fileURLWithPath: "/usr/bin/true"))
        let project = try #require(module.selected)
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let initial = try await module.analysis(projectID: project.id)
        let annotated = try await module.editProject(projectID: project.id, expectedRevision: initial.revision,
            operations: [.addressNote(address: "100000000", comment: "Keep this analyst note", label: "qa_binary")])
        let tool = REAgentTool(definition: try #require(REMCPTools.definitions.first { $0.name == "analyze_binary" }), module: module)
        #expect(tool.spec.permission == .execute)
        let context = ToolExecutionContext(workspaceRoot: nil, conversationID: UUID(), redactSecrets: true, services: ToolServices())
        let arguments = try JSONSerialization.data(withJSONObject: ["project_id": project.id])
        let run = Task { try await tool.execute(argumentsJSON: String(decoding: arguments, as: UTF8.self), context: context) }
        for _ in 0..<100 where !module.isGhidraAnalysisRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(module.isGhidraAnalysisRunning)
        do {
            _ = try await module.analyzeWithGhidra(projectID: project.id)
            Issue.record("Concurrent analysis must be rejected")
        } catch REError.analysisInProgress {} catch { Issue.record("Unexpected duplicate-run error: \(error)") }
        _ = try await run.value
        let analysis = try await module.analysis(projectID: project.id)
        let persisted = try ProjectStore.load(project.folder.path)
        #expect(persisted.id == initial.id && persisted.revision == annotated.revision + 1)
        #expect(persisted.addressComments == annotated.addressComments && persisted.addressLabels == annotated.addressLabels)
        #expect(analysis.sha256 == initial.sha256 && analysis.binaryPath == project.binaryURL.path)
        #expect(analysis.engine.hasPrefix("Ghidra"))
        let function = try #require(analysis.functions.first { !$0.code.isEmpty })
        #expect(!function.assembly.isEmpty)
        let code = try await module.decompilation(projectID: project.id, address: function.address)
        #expect(code == function.code)
        #expect(!module.isGhidraAnalysisRunning)
        print("GHIDRA_QA engine=\(analysis.engine) functions=\(analysis.functions.count) pseudocode=\(code.prefix(180))")
    }
}

@Suite("Ghidra failure messages")
struct GhidraFailureMessageTests {
    @Test func aUnsupportedJavaIsExplainedNotShownAsAMissingExport() {
        let log = "Caused by: java.lang.ClassNotFoundException: AxiomExport ... missing requirement osgi.ee; (osgi.ee=UNKNOWN)"
        let message = Analyzer.ghidraFailureMessage(log: log)
        #expect(message.contains("JDK 21") && message.contains("JAVA_HOME"))
        #expect(!message.hasPrefix("Ghidra produced no export"))
    }
    @Test func otherFailuresKeepTheirLog() {
        #expect(Analyzer.ghidraFailureMessage(log: "some other error").hasPrefix("Ghidra produced no export. some other error"))
    }
}

@Suite("Ghidra Java selection")
struct GhidraJavaSelectionTests {
    @Test func ghidra12AndNewerUseTheDefaultJava() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Ghidra"), withIntermediateDirectories: true)
        try "application.version=12.1.4\n".write(to: home.appendingPathComponent("Ghidra/application.properties"), atomically: true, encoding: .utf8)
        #expect(Analyzer.ghidraMajorVersion(home: home.path) == 12)
        #expect(Analyzer.ghidraJavaEnvironment(home: home.path).isEmpty)
    }
    @Test func ghidra11IsPinnedToJDK21WhenOneIsInstalled() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Ghidra"), withIntermediateDirectories: true)
        try "application.version=11.3.2\n".write(to: home.appendingPathComponent("Ghidra/application.properties"), atomically: true, encoding: .utf8)
        #expect(Analyzer.ghidraMajorVersion(home: home.path) == 11)
        let env = Analyzer.ghidraJavaEnvironment(home: home.path)
        if let java = env["JAVA_HOME"] { #expect(java.hasPrefix("/")) }   // empty when this Mac has no JDK 21
    }
}

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE_GHIDRA"] == "1"), .serialized)
struct LiveGhidraCancelTests {
    @Test func cancellingAnAnalysisEndsTheProcessTreeAndLeavesTheProjectUntouched() async throws {
        let module = REModule()
        module.configureDiscoveredGhidra()
        #expect(module.isGhidraAvailable, "\(module.ghidraStatus)")
        _ = try await module.importBinary(at: URL(fileURLWithPath: "/usr/bin/true"))
        let project = try #require(module.selected)
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let before = try await module.analysis(projectID: project.id)
        let run = Task { try await module.analyzeWithGhidra(projectID: project.id) }
        for _ in 0..<200 where !module.isGhidraAnalysisRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(module.isGhidraAnalysisRunning)
        try await Task.sleep(nanoseconds: 800_000_000)
        let started = Date()
        module.cancelGhidraAnalysis()
        do { _ = try await run.value; Issue.record("A cancelled analysis must not succeed") }
        catch is OperationCancelled {} catch { Issue.record("Expected cancellation, got \(error)") }
        #expect(Date().timeIntervalSince(started) < 10, "cancellation should end the analysis promptly")
        #expect(!module.isGhidraAnalysisRunning)
        let after = try await module.analysis(projectID: project.id)
        #expect(after.revision == before.revision && after.functions.count == before.functions.count)
        // No analyzeHeadless/Ghidra JVM left running for this project.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-axo", "command="]
        let pipe = Pipe(); ps.standardOutput = pipe; try ps.run()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        #expect(!listing.contains("engine/\(project.id)"), "a Ghidra process is still running for this project after cancel")
    }
}
