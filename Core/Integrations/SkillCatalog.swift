import Foundation

/// Skills (a folder with a `SKILL.md`) that Claude Code, Codex and OpenCode already keep on this Mac. Kiln reads them
/// where they are instead of copying them: one skill that appears in several places, or under several names for the
/// same folder, is listed once.
public enum SkillCatalog {
    public struct Skill: Equatable, Sendable {
        public var name: String
        public var description: String
        public var directory: URL
        public var sources: [String]
        public var file: URL { directory.appendingPathComponent("SKILL.md") }
    }

    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Skill] {
        var roots: [(source: String, url: URL)] = [
            ("Claude Code", home.appendingPathComponent(".claude/skills")),
            ("Codex", home.appendingPathComponent(".codex/skills")),
            ("OpenCode", home.appendingPathComponent(".config/opencode/skills")),
            ("Agents", home.appendingPathComponent(".agents/skills")),
        ]
        roots += openCodeConfiguredPaths(home: home).map { ("OpenCode", $0) }
        roots += claudePluginSkillRoots(home: home).map { ("Claude Code plugin", $0) }
        return merge(roots)
    }

    static func merge(_ roots: [(source: String, url: URL)]) -> [Skill] {
        var byName: [String: Int] = [:]
        var seenPaths = Set<String>()
        var skills: [Skill] = []
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for directory in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let file = directory.appendingPathComponent("SKILL.md")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let real = directory.resolvingSymlinksInPath().path
                guard let header = frontmatter(of: file) else { continue }
                let name = header.name ?? directory.lastPathComponent
                if let index = byName[name] {
                    if !skills[index].sources.contains(root.source) { skills[index].sources.append(root.source) }
                    continue
                }
                guard seenPaths.insert(real).inserted else { continue }
                byName[name] = skills.count
                skills.append(Skill(name: name, description: header.description ?? "", directory: directory, sources: [root.source]))
            }
        }
        return skills.sorted { $0.name < $1.name }
    }

    static func frontmatter(of file: URL) -> (name: String?, description: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 8192)) ?? Data(), as: UTF8.self)
        let lines = head.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        var name: String?
        var description: String?
        var index = 1
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[index]
            if let value = value(of: "name", in: line) { name = value }
            else if let value = value(of: "description", in: line) {
                var text = value
                // Folded or continued descriptions: take indented continuation lines.
                while index + 1 < lines.count, lines[index + 1].hasPrefix("  ") || lines[index + 1].hasPrefix("\t") {
                    index += 1
                    text += " " + lines[index].trimmingCharacters(in: .whitespaces)
                }
                description = text.trimmingCharacters(in: CharacterSet(charactersIn: ">|-\" '").union(.whitespaces))
            }
            index += 1
        }
        return (name, description)
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix("\(key):") else { return nil }
        let raw = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    static func openCodeConfiguredPaths(home: URL) -> [URL] {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".config/opencode/opencode.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let skills = root["skills"] as? [String: Any],
              let paths = skills["paths"] as? [String] else { return [] }
        return paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    /// Skills bundled in installed Claude Code plugins: any `skills` directory under the plugin cache.
    static func claudePluginSkillRoots(home: URL) -> [URL] {
        let cache = home.appendingPathComponent(".claude/plugins/cache")
        guard let walker = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var roots: [URL] = []
        for case let url as URL in walker {
            let depth = url.pathComponents.count - cache.pathComponents.count
            if depth > 5 { walker.skipDescendants(); continue }
            if url.lastPathComponent == "skills",
               (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                roots.append(url)
                walker.skipDescendants()
            }
        }
        return roots.sorted { $0.path < $1.path }
    }
}
