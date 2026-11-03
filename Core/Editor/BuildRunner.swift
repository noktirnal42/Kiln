import Foundation

public struct Diagnostic: Identifiable, Equatable, Sendable {
    public enum Severity: String, Sendable { case error, warning, note }
    public var id = UUID()
    public var path: String
    public var line: Int
    public var column: Int
    public var severity: Severity
    public var message: String
}

public enum DiagnosticParser {
    /// `path:line:col: error: message` (clang, swiftc, xcodebuild, tsc, rustc short form, gcc) and the same without a column.
    public static func parse(_ line: String) -> Diagnostic? {
        // SwiftPM prefixes its own form: `error: /path/File.swift:81:13 message` (no colon after the column).
        if let regex = try? NSRegularExpression(pattern: #"^(error|warning|note): (/.+?):(\d+)(?::(\d+))?:? (.+)$"#),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let severity = Range(match.range(at: 1), in: line), let path = Range(match.range(at: 2), in: line),
           let number = Range(match.range(at: 3), in: line), let message = Range(match.range(at: 5), in: line),
           let lineNumber = Int(line[number]) {
            let column = Range(match.range(at: 4), in: line).flatMap { Int(line[$0]) } ?? 1
            return Diagnostic(path: String(line[path]), line: lineNumber, column: column,
                              severity: Diagnostic.Severity(rawValue: String(line[severity])) ?? .error,
                              message: String(line[message]))
        }
        let pattern = #"^(.+?):(\d+):(?:(\d+):)?\s*(error|warning|note):\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let path = Range(match.range(at: 1), in: line), let number = Range(match.range(at: 2), in: line),
              let severity = Range(match.range(at: 4), in: line), let message = Range(match.range(at: 5), in: line),
              let lineNumber = Int(line[number]) else { return nil }
        let column = Range(match.range(at: 3), in: line).flatMap { Int(line[$0]) } ?? 1
        return Diagnostic(path: String(line[path]), line: lineNumber, column: column,
                          severity: Diagnostic.Severity(rawValue: String(line[severity])) ?? .error,
                          message: String(line[message]))
    }
}

/// Works out how to build the open project, runs it, streams the output and collects diagnostics.
@MainActor @Observable
public final class BuildRunner {
    public struct Plan: Equatable, Sendable {
        public var title: String
        public var command: String
    }

    public private(set) var output = ""
    public private(set) var diagnostics: [Diagnostic] = []
    public private(set) var isRunning = false
    /// What the current run is doing, so the UI can label it and the tests panel can read its output.
    public private(set) var currentKind: RunKind = .build
    public enum RunKind: String, Sendable { case build, test, run }
    public private(set) var testResults: [TestResult] = []
    public private(set) var info: ProjectInfo = .empty
    public var selection = BuildSelection()
    private var infoRoot: URL?
    public private(set) var lastExitStatus: Int32?
    public var customCommand = ""

    private var process: Process?

    public init() {}

    /// A sensible build command for the folder, or nil when nothing is recognised.
    public nonisolated static func detectPlan(in root: URL) -> Plan? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(name).path) }
        let entries = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        if let project = entries.first(where: { $0.hasSuffix(".xcodeproj") }) {
            let scheme = (project as NSString).deletingPathExtension
            return Plan(title: "xcodebuild \(scheme)", command: "xcodebuild build -project '\(project)' -scheme '\(scheme)' -destination 'platform=macOS'")
        }
        if has("project.yml") && !entries.contains(where: { $0.hasSuffix(".xcodeproj") }) {
            return Plan(title: "xcodegen + xcodebuild", command: "xcodegen generate && xcodebuild build -scheme \(root.lastPathComponent) -destination 'platform=macOS'")
        }
        if has("Package.swift") { return Plan(title: "swift build", command: "swift build") }
        if has("Cargo.toml") { return Plan(title: "cargo build", command: "cargo build --message-format short") }
        if has("go.mod") { return Plan(title: "go build", command: "go build ./...") }
        if has("package.json") { return Plan(title: "npm run build", command: "npm run build --if-present") }
        if has("Makefile") { return Plan(title: "make", command: "make") }
        if has("pyproject.toml") || has("setup.py") { return Plan(title: "python compileall", command: "python3 -m compileall -q .") }
        return nil
    }

    /// Runs `command` through a login shell so Homebrew, nvm and Xcode's tools are on PATH as in Terminal.
    /// Asks the toolchain what the folder contains (schemes, configurations, executables) and restores the saved selection.
    public func loadProject(at root: URL) async {
        guard infoRoot != root else { return }
        infoRoot = root
        let loaded = await Task.detached(priority: .userInitiated) { ProjectInfo.load(in: root) }.value
        info = loaded
        var chosen = BuildSelection.load(for: root)
        if let scheme = chosen.scheme, !loaded.schemes.contains(scheme) { chosen.scheme = nil }
        if let configuration = chosen.configuration, !loaded.configurations.contains(configuration) { chosen.configuration = nil }
        selection = chosen
    }

    public func reloadProject(at root: URL) async {
        infoRoot = nil
        await loadProject(at: root)
    }

    public func select(scheme: String?, configuration: String?, root: URL) {
        selection = BuildSelection(scheme: scheme, configuration: configuration)
        selection.save(for: root)
    }

    public func run(command: String, in root: URL, kind: RunKind = .build) {
        guard !isRunning else { return }
        currentKind = kind
        testResults = []
        output = ""
        diagnostics = []
        lastExitStatus = nil
        isRunning = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.process = process
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] file in
            let data = file.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(chunk, root: root) }
        }
        process.terminationHandler = { [weak self] finished in
            handle.readabilityHandler = nil
            let rest = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in
                if !rest.isEmpty { self?.append(rest, root: root) }
                self?.finish(status: finished.terminationStatus)
            }
        }
        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            output = "Could not start: \(error.localizedDescription)"
            isRunning = false
            self.process = nil
        }
    }

    public func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private var carry = ""

    private func append(_ chunk: String, root: URL) {
        output += chunk
        if output.count > 400_000 { output = String(output.suffix(300_000)) }
        carry += chunk
        var lines = carry.components(separatedBy: "\n")
        carry = lines.removeLast()
        for line in lines {
            guard var diagnostic = DiagnosticParser.parse(line) else { continue }
            if !diagnostic.path.hasPrefix("/") { diagnostic.path = root.appendingPathComponent(diagnostic.path).path }
            if !diagnostics.contains(where: { $0.path == diagnostic.path && $0.line == diagnostic.line && $0.message == diagnostic.message }) {
                diagnostics.append(diagnostic)
            }
        }
    }

    private func finish(status: Int32) {
        lastExitStatus = status
        if currentKind == .test { testResults = TestOutputParser.parse(output) }
        isRunning = false
        process = nil
        carry = ""
    }

    public var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
    public var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }
}
