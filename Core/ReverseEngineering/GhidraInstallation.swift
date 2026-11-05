import Foundation

/// Locates an existing Ghidra installation. Discovery never installs or launches software.
enum GhidraInstallation {
    struct Candidate: Equatable {
        let home: URL
        let version: String
        let isRelease: Bool
        var label: String { "Ghidra \(version)\(isRelease ? "" : " (development build)")" }
    }

    /// The choice made in the Analyze view, kept across launches. Nil means "pick automatically".
    static let preferenceKey = "re.ghidraHome"

    /// An explicit choice (a valid `preferred` folder) wins, then GHIDRA_HOME, then the highest stable release.
    static func discover(environment: [String: String] = ProcessInfo.processInfo.environment,
                         applicationDirectories: [URL] = defaultDirectories,
                         preferred: URL? = nil) -> URL? {
        if let preferred, let candidate = candidate(preferred) { return candidate.home }
        if let explicit = environment["GHIDRA_HOME"], let candidate = candidate(URL(fileURLWithPath: explicit)) {
            return candidate.home
        }
        return installations(environment: environment, applicationDirectories: applicationDirectories).first?.home
    }

    /// Every usable installation (Ghidra 11 or newer with a launcher), best first: stable before development
    /// builds, then newest. GHIDRA_HOME is included even when it lives outside the scanned folders.
    static func installations(environment: [String: String] = ProcessInfo.processInfo.environment,
                              applicationDirectories: [URL] = defaultDirectories) -> [Candidate] {
        var found = applicationDirectories.flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.lowercased().hasPrefix("ghidra") }
                .compactMap(candidate)
        }
        if let explicit = environment["GHIDRA_HOME"], let extra = candidate(URL(fileURLWithPath: explicit)),
           !found.contains(where: { $0.home == extra.home }) {
            found.append(extra)
        }
        return found.sorted {
            if $0.isRelease != $1.isRelease { return $0.isRelease }
            let order = $0.version.compare($1.version, options: .numeric)
            if order != .orderedSame { return order == .orderedDescending }
            return $0.home.path < $1.home.path
        }
    }

    /// Why a folder the analyst picked cannot be used, or nil when it can.
    static func rejection(for home: URL) -> String? {
        let launcher = home.appendingPathComponent("support/analyzeHeadless")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
            return "\(home.lastPathComponent) has no support/analyzeHeadless. Choose the folder that contains support/ and Ghidra/ (the unpacked Ghidra release)."
        }
        return candidate(home) == nil ? "\(home.lastPathComponent) is Ghidra older than 11 or its application.properties is unreadable. Kiln needs Ghidra 11 or newer." : nil
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

    static func candidate(_ home: URL) -> Candidate? {
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
