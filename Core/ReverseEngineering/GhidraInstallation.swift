import Foundation

/// Locates an existing Ghidra installation. Discovery never installs or launches software.
enum GhidraInstallation {
    private struct Candidate {
        let home: URL
        let version: String
        let isRelease: Bool
    }

    static func discover(environment: [String: String] = ProcessInfo.processInfo.environment,
                         applicationDirectories: [URL] = defaultDirectories) -> URL? {
        if let explicit = environment["GHIDRA_HOME"], let candidate = candidate(URL(fileURLWithPath: explicit)) {
            return candidate.home
        }
        let candidates = applicationDirectories.flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.lowercased().hasPrefix("ghidra") }
                .compactMap(candidate)
        }
        return candidates.sorted {
            if $0.isRelease != $1.isRelease { return $0.isRelease }
            let order = $0.version.compare($1.version, options: .numeric)
            if order != .orderedSame { return order == .orderedDescending }
            return $0.home.path < $1.home.path
        }.first?.home
    }

    static var defaultDirectories: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
         URL(fileURLWithPath: "/Applications", isDirectory: true)]
    }

    static func exporter(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "AxiomExport", withExtension: "java", subdirectory: "Ghidra")?
            .deletingLastPathComponent()
    }

    static func isValid(_ home: URL) -> Bool { candidate(home) != nil }

    private static func candidate(_ home: URL) -> Candidate? {
        guard FileManager.default.isExecutableFile(atPath: home.appendingPathComponent("support/analyzeHeadless").path),
              let text = try? String(contentsOf: home.appendingPathComponent("Ghidra/application.properties"), encoding: .utf8) else { return nil }
        var properties: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let separator = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            properties[String(line[..<separator]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let version = properties["application.version"],
              let major = version.split(separator: ".").first.flatMap({ Int($0) }), major >= 11 else { return nil }
        return Candidate(home: home.standardizedFileURL, version: version,
                         isRelease: properties["application.release.name"] == "PUBLIC")
    }
}
