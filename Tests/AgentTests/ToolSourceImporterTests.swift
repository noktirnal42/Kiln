import Foundation
import Testing
@testable import Kiln

struct ToolSourceImporterTests {
    private func home(_ files: [String: String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-src-\(UUID().uuidString)", isDirectory: true)
        for (path, text) in files {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return home
    }

    @Test func sameServerInThreeToolsAppearsOnceWithAllSources() throws {
        let root = try home([
            ".claude.json": #"{"mcpServers":{"rea":{"command":"/usr/local/bin/rea-mcp","args":["--stdio"]}}}"#,
            ".codex/config.toml": """
            [mcp_servers.rea]
            command = "rea-mcp"
            args = ["--stdio"]
            [mcp_servers.rea.env]
            TOKEN = "secret"
            [mcp_servers.docs]
            url = "https://docs.example.com/mcp"
            """,
            ".config/opencode/opencode.json": #"{"mcp":{"servers":{"reverse":{"command":["rea-mcp","--stdio"]},"local":{"command":["npx","-y","thing"]}}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let servers = ToolSourceImporter.importServers(home: root)
        #expect(servers.map(\.config.id).sorted() == ["docs", "local", "rea"])
        let rea = try #require(servers.first { $0.config.id == "rea" })
        #expect(rea.sources == ["Claude Code", "Codex", "OpenCode"])
        #expect(rea.config.environment["TOKEN"] == "secret")      // kept in memory only
        #expect(servers.first { $0.config.id == "docs" }?.config.transport == .http)
    }

    @Test func sameNameWithADifferentCommandIsKeptApart() {
        let a = MCPServerConfig(id: "kettle", transport: .stdio, command: "kettle", arguments: ["a"])
        let b = MCPServerConfig(id: "kettle", transport: .stdio, command: "other", arguments: ["b"])
        let merged = ToolSourceImporter.merge([("Claude Code", a), ("Codex", b)])
        #expect(merged.map(\.config.id) == ["kettle", "kettle-codex"])
    }

    @Test func multiLineTomlArraysAndDisabledServers() {
        let toml = """
        [mcp_servers.big]
        command = "node"
        args = [
          "a.js",
          "--flag",
        ]
        [mcp_servers.off]
        command = "x"
        enabled = false
        """
        let parsed = ToolSourceImporter.parseCodexTOML(toml)
        #expect(parsed.map(\.id) == ["big"])
        #expect(parsed.first?.arguments == ["a.js", "--flag"])
    }
}

struct SkillCatalogTests {
    @Test func aSkillInSeveralPlacesIsListedOnce() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-skills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        func skill(_ root: String, _ folder: String, name: String, description: String) throws {
            let dir = home.appendingPathComponent("\(root)/\(folder)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: \(description)\n---\nBody".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try skill(".claude/skills", "gplay-apps", name: "gplay-apps", description: "Registry and app details")
        try skill(".codex/skills", "gplay-apps", name: "gplay-apps", description: "Registry and app details")
        try skill(".codex/skills", "adaptive", name: "adaptive", description: "Adaptive UI")
        let skills = SkillCatalog.scan(home: home)
        #expect(skills.map(\.name) == ["adaptive", "gplay-apps"])
        #expect(skills.first { $0.name == "gplay-apps" }?.sources == ["Claude Code", "Codex"])
        #expect(skills.first { $0.name == "adaptive" }?.description == "Adaptive UI")
    }
}
