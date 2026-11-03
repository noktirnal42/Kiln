import Foundation

/// What the open folder is, and what can be built in it: schemes and configurations for Xcode projects, products for
/// Swift packages. Loaded by asking the toolchain, so it matches what the build will do.
public struct ProjectInfo: Equatable, Sendable {
    public enum Kind: String, Sendable { case xcodeProject, xcodeWorkspace, swiftPackage, other }

    public var kind: Kind
    /// The `.xcodeproj` / `.xcworkspace` file name, when there is one.
    public var container: String?
    public var schemes: [String]
    public var configurations: [String]
    /// Executable products of a Swift package (what `swift run` can start).
    public var executables: [String]

    public static let empty = ProjectInfo(kind: .other, container: nil, schemes: [], configurations: [], executables: [])

    /// Pure: turns `xcodebuild -list -json` output into schemes and configurations.
    public static func parseXcodebuildList(_ data: Data) -> (schemes: [String], configurations: [String]) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], []) }
        let body = (root["project"] as? [String: Any]) ?? (root["workspace"] as? [String: Any]) ?? [:]
        return ((body["schemes"] as? [String]) ?? [], (body["configurations"] as? [String]) ?? [])
    }

    /// Pure: executable product names from `swift package describe --type json`.
    public static func parsePackageDescription(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let products = root["products"] as? [[String: Any]] else { return [] }
        return products.compactMap { product in
            guard let type = product["type"] as? [String: Any], type["executable"] != nil else { return nil }
            return product["name"] as? String
        }.sorted()
    }

    public static func load(in root: URL) -> ProjectInfo {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        if let workspace = entries.first(where: { $0.hasSuffix(".xcworkspace") }) {
            let listed = parseXcodebuildList(run(["xcodebuild", "-list", "-json", "-workspace", workspace], in: root))
            return ProjectInfo(kind: .xcodeWorkspace, container: workspace, schemes: listed.schemes, configurations: listed.configurations, executables: [])
        }
        if let project = entries.first(where: { $0.hasSuffix(".xcodeproj") }) {
            let listed = parseXcodebuildList(run(["xcodebuild", "-list", "-json", "-project", project], in: root))
            return ProjectInfo(kind: .xcodeProject, container: project, schemes: listed.schemes, configurations: listed.configurations, executables: [])
        }
        if entries.contains("Package.swift") {
            let executables = parsePackageDescription(run(["swift", "package", "describe", "--type", "json"], in: root))
            return ProjectInfo(kind: .swiftPackage, container: "Package.swift", schemes: [], configurations: ["debug", "release"], executables: executables)
        }
        return .empty
    }

    private static func run(_ arguments: [String], in directory: URL) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", arguments.map { "'\($0)'" }.joined(separator: " ")]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

/// The scheme and configuration chosen for a project, remembered per folder.
public struct BuildSelection: Equatable, Codable, Sendable {
    public var scheme: String?
    public var configuration: String?

    private static func key(_ root: URL) -> String { "build.selection." + root.path }

    public static func load(for root: URL, defaults: UserDefaults = .standard) -> BuildSelection {
        guard let data = defaults.data(forKey: key(root)), let value = try? JSONDecoder().decode(BuildSelection.self, from: data) else {
            return BuildSelection()
        }
        return value
    }

    public func save(for root: URL, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key(root)) }
    }
}

/// Build, test and run commands for a project and a selection. Pure, so the choices can be tested without a toolchain.
public enum ProjectCommands {
    private static func q(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func build(info: ProjectInfo, selection: BuildSelection) -> BuildRunner.Plan? {
        switch info.kind {
        case .xcodeProject, .xcodeWorkspace:
            guard let container = info.container else { return nil }
            let scheme = selection.scheme ?? info.schemes.first ?? (container as NSString).deletingPathExtension
            let flag = info.kind == .xcodeWorkspace ? "-workspace" : "-project"
            var command = "xcodebuild build \(flag) \(q(container)) -scheme \(q(scheme)) -destination 'platform=macOS'"
            if let configuration = selection.configuration { command += " -configuration \(q(configuration))" }
            return BuildRunner.Plan(title: "\(scheme)\(selection.configuration.map { " · \($0)" } ?? "")", command: command)
        case .swiftPackage:
            let release = selection.configuration == "release"
            return BuildRunner.Plan(title: "swift build\(release ? " · release" : "")", command: "swift build" + (release ? " -c release" : ""))
        case .other:
            return nil
        }
    }

    public static func test(info: ProjectInfo, selection: BuildSelection, filter: String? = nil) -> BuildRunner.Plan? {
        switch info.kind {
        case .xcodeProject, .xcodeWorkspace:
            guard let container = info.container else { return nil }
            let scheme = selection.scheme ?? info.schemes.first ?? (container as NSString).deletingPathExtension
            let flag = info.kind == .xcodeWorkspace ? "-workspace" : "-project"
            var command = "xcodebuild test \(flag) \(q(container)) -scheme \(q(scheme)) -destination 'platform=macOS'"
            if let filter { command += " -only-testing:\(q(filter))" }
            return BuildRunner.Plan(title: "Test \(scheme)", command: command)
        case .swiftPackage:
            return BuildRunner.Plan(title: "swift test", command: "swift test" + (filter.map { " --filter \(q($0))" } ?? ""))
        case .other:
            return nil
        }
    }

    /// Something to start: `swift run <product>` for a package; for an Xcode project, build then launch the product.
    public static func run(info: ProjectInfo, selection: BuildSelection, executable: String? = nil) -> BuildRunner.Plan? {
        switch info.kind {
        case .swiftPackage:
            guard let product = executable ?? info.executables.first else { return nil }
            return BuildRunner.Plan(title: "Run \(product)", command: "swift run \(q(product))")
        case .xcodeProject, .xcodeWorkspace:
            guard let container = info.container, let build = build(info: info, selection: selection) else { return nil }
            let scheme = selection.scheme ?? info.schemes.first ?? (container as NSString).deletingPathExtension
            let flag = info.kind == .xcodeWorkspace ? "-workspace" : "-project"
            let settings = "xcodebuild \(flag) \(q(container)) -scheme \(q(scheme)) -destination 'platform=macOS'"
                + (selection.configuration.map { " -configuration \(q($0))" } ?? "") + " -showBuildSettings"
            // Build, then run the product's executable directly so its output streams into the panel.
            let command = "\(build.command) && S=$(\(settings) 2>/dev/null) && "
                + "D=$(echo \"$S\" | awk -F' = ' '/ TARGET_BUILD_DIR /{print $2; exit}') && "
                + "P=$(echo \"$S\" | awk -F' = ' '/ FULL_PRODUCT_NAME /{print $2; exit}') && "
                + "X=$(echo \"$S\" | awk -F' = ' '/ EXECUTABLE_PATH /{print $2; exit}') && "
                + "echo \"Launching $P\" && exec \"$D/$X\""
            return BuildRunner.Plan(title: "Run \(scheme)", command: command)
        case .other:
            return nil
        }
    }
}

public struct TestResult: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case passed, failed, skipped }
    public var id: String { name }
    public var name: String
    public var status: Status
    public var seconds: Double?
}

/// Reads test results out of `swift test` / `xcodebuild test` output: XCTest ("Test Case '-[A b]' passed (0.001 seconds)"),
/// Swift Testing ("✔ Test name() passed after 0.001 seconds"), and the xcodebuild flavours of both.
public enum TestOutputParser {
    public static func parse(_ output: String) -> [TestResult] {
        var results: [String: TestResult] = [:]
        var order: [String] = []
        func record(_ name: String, _ status: TestResult.Status, _ seconds: Double?) {
            if results[name] == nil { order.append(name) }
            results[name] = TestResult(name: name, status: status, seconds: seconds)
        }
        let xctest = try? NSRegularExpression(pattern: #"Test Case '(.+?)' (passed|failed) \(([\d.]+) seconds\)"#)
        // Requires "after N seconds" so "recorded an issue … Expectation failed:" lines and the closing "Test run with …" summary don't match.
        let swiftTesting = try? NSRegularExpression(pattern: #"^[✔✘]\s*Test (.+?) (passed|failed) after ([\d.]+) seconds"#)
        for line in output.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            if let match = xctest?.firstMatch(in: line, range: range),
               let name = Range(match.range(at: 1), in: line), let status = Range(match.range(at: 2), in: line),
               let seconds = Range(match.range(at: 3), in: line) {
                var testName = String(line[name])
                if testName.hasPrefix("-["), testName.hasSuffix("]") { testName = String(testName.dropFirst(2).dropLast()) }
                record(testName, TestResult.Status(rawValue: String(line[status])) ?? .failed, Double(line[seconds]))
            } else if let match = swiftTesting?.firstMatch(in: line, range: range),
                      let name = Range(match.range(at: 1), in: line), let status = Range(match.range(at: 2), in: line),
                      !line[name].hasPrefix("run with") {
                let seconds = Range(match.range(at: 3), in: line).flatMap { Double(line[$0]) }
                record(String(line[name]), TestResult.Status(rawValue: String(line[status])) ?? .failed, seconds)
            }
        }
        return order.compactMap { results[$0] }
    }
}


/// Finds the executable a build produced, so the debugger can launch it.
public enum ProgramResolver {
    /// Supports both xcodebuild's structured settings and its human-readable output.
    public static func parseBuildSettings(_ text: String, preferredTarget: String? = nil) -> String? {
        func executable(_ settings: [String: String]) -> String? {
            guard let directory = settings["TARGET_BUILD_DIR"], !directory.isEmpty,
                  let path = settings["EXECUTABLE_PATH"], !path.isEmpty else { return nil }
            return URL(fileURLWithPath: directory).appendingPathComponent(path).path
        }
        if let rows = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] {
            let runnable = rows.filter { row in
                guard let settings = row["buildSettings"] as? [String: String] else { return false }
                return settings["MACH_O_TYPE"] == "mh_execute"
                    || settings["PRODUCT_TYPE"] == "com.apple.product-type.application"
            }
            let row = runnable.first { $0["target"] as? String == preferredTarget } ?? runnable.first
            return (row?["buildSettings"] as? [String: String]).flatMap(executable)
        }
        var values: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.range(of: " = ") else { continue }
            values[String(trimmed[..<separator.lowerBound])] = String(trimmed[separator.upperBound...])
        }
        return executable(values)
    }

    public static func resolve(info: ProjectInfo, selection: BuildSelection, root: URL) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            func run(_ arguments: [String]) -> String {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = arguments
                process.currentDirectoryURL = root
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { return "" }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return "" }
                return String(decoding: data, as: UTF8.self)
            }
            switch info.kind {
            case .swiftPackage:
                let arguments = ["swift", "build"] + (selection.configuration == "release" ? ["-c", "release"] : []) + ["--show-bin-path"]
                let binPath = run(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let product = info.executables.first, !binPath.isEmpty else { return nil }
                return URL(fileURLWithPath: binPath).appendingPathComponent(product).path
            case .xcodeProject, .xcodeWorkspace:
                guard let container = info.container else { return nil }
                let scheme = selection.scheme ?? info.schemes.first ?? (container as NSString).deletingPathExtension
                let flag = info.kind == .xcodeWorkspace ? "-workspace" : "-project"
                var arguments = ["xcodebuild", flag, container, "-scheme", scheme, "-destination", "platform=macOS"]
                if let configuration = selection.configuration { arguments += ["-configuration", configuration] }
                arguments += ["-showBuildSettings", "-json"]
                return parseBuildSettings(run(arguments), preferredTarget: scheme)
            case .other:
                return nil
            }
        }.value
    }
}
