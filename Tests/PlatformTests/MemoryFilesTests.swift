import Foundation
import Testing
@testable import Kiln

struct MemoryFilesTests {
    @Test func readsUserThenProjectFilesAndCountsTokens() throws {
        let home = try PlatformTestSupport.tempDir("home"), project = try PlatformTestSupport.tempDir("proj")
        try PlatformTestSupport.write("Prefer tabs.", to: home.appendingPathComponent(".kiln/KILN.md"))
        try PlatformTestSupport.write("Run `make test` before commit.", to: project.appendingPathComponent("AGENTS.md"))
        try PlatformTestSupport.write("Claude only note", to: project.appendingPathComponent("CLAUDE.md"))
        let snapshot = MemoryLoader.load(workspaceRoot: project, home: home)
        #expect(snapshot.injected.map(\.name) == ["KILN.md", "AGENTS.md", "CLAUDE.md"])
        #expect(snapshot.injected.map(\.scope) == [.user, .project, .project])
        #expect(snapshot.totalTokens > 0 && snapshot.injected.allSatisfy { $0.tokens > 0 })
        #expect(snapshot.promptSection.contains("Prefer tabs."))
        #expect(snapshot.promptSection.contains("never change what you are permitted to do"))
        #expect(snapshot.files.count == 6)   // three user candidates + three project candidates, existing or not
    }

    @Test func identicalFilesAreSentOnce() throws {
        let project = try PlatformTestSupport.tempDir("proj")
        try PlatformTestSupport.write("Same rules.", to: project.appendingPathComponent("AGENTS.md"))
        try PlatformTestSupport.write("Same rules.", to: project.appendingPathComponent("CLAUDE.md"))
        let snapshot = MemoryLoader.load(workspaceRoot: project, home: nil)
        #expect(snapshot.injected.count == 1)
        let duplicate = try #require(snapshot.files.first { $0.name == "CLAUDE.md" })
        #expect(duplicate.duplicateOf == project.appendingPathComponent("AGENTS.md").path && duplicate.tokens == 0)
        #expect(snapshot.promptSection.components(separatedBy: "Same rules.").count == 2)
    }

    @Test func nothingFoundMeansNoPromptSection() throws {
        let snapshot = MemoryLoader.load(workspaceRoot: try PlatformTestSupport.tempDir(), home: nil)
        #expect(snapshot.promptSection.isEmpty && snapshot.totalTokens == 0)
    }

    @Test func oversizedFilesAreCutAtACharacterBoundary() throws {
        let project = try PlatformTestSupport.tempDir()
        try PlatformTestSupport.write(String(repeating: "é", count: MemoryLoader.maxBytesPerFile), to: project.appendingPathComponent("KILN.md"))
        let file = try #require(MemoryLoader.load(workspaceRoot: project, home: nil).injected.first)
        #expect(file.truncated && file.content.utf8.count <= MemoryLoader.maxBytesPerFile && !file.content.isEmpty)
    }

    @Test func saveOnlyWritesKnownMemoryFiles() throws {
        let project = try PlatformTestSupport.tempDir("proj"), home = try PlatformTestSupport.tempDir("home")
        let kiln = project.appendingPathComponent("KILN.md")
        try MemoryLoader.save("hello", path: kiln.path, workspaceRoot: project, home: home)
        #expect(try String(contentsOf: kiln, encoding: .utf8) == "hello")
        try MemoryLoader.save("user", path: home.appendingPathComponent(".kiln/KILN.md").path, workspaceRoot: project, home: home)
        #expect(throws: MemoryLoader.SaveError.self) {
            try MemoryLoader.save("x", path: project.appendingPathComponent("notes.txt").path, workspaceRoot: project, home: home)
        }
        #expect(throws: MemoryLoader.SaveError.self) {
            try MemoryLoader.save("x", path: project.appendingPathComponent("../KILN.md").path, workspaceRoot: project, home: home)
        }
    }

    @Test func toolsReadWriteAndAudit() async throws {
        let project = try PlatformTestSupport.tempDir("proj"), home = try PlatformTestSupport.tempDir("home")
        let chain = try PlatformTestSupport.auditChain()
        var services = ToolServices()
        services.audit = PlatformAudit(chain: chain)
        let context = ToolExecutionContext(workspaceRoot: project, conversationID: UUID(), services: services)
        let path = project.appendingPathComponent("KILN.md").path
        let write = MemoryWriteTool(home: home)
        let json = String(data: try JSONSerialization.data(withJSONObject: ["path": path, "content": "Use Swift 6."]), encoding: .utf8)!
        _ = try await write.execute(argumentsJSON: json, context: context)
        let read = try await MemoryReadTool(home: home).execute(argumentsJSON: "{}", context: context)
        #expect(read.contains("Use Swift 6.") && read.contains("tokens"))
        let events = try await chain.recent(10)
        #expect(events.contains { $0.type == "memory.saved" })
        #expect(write.spec.permission == .write)
        await #expect(throws: (any Error).self) {
            _ = try await write.execute(argumentsJSON: "{\"path\":\"/etc/hosts\",\"content\":\"x\"}", context: context)
        }
    }
}

@MainActor
struct MemorySessionTests {
    @Test func sessionPutsMemoryInTheSystemPromptAndSaves() async throws {
        let project = try PlatformTestSupport.tempDir("proj")
        try PlatformTestSupport.write("Always answer in French.", to: project.appendingPathComponent("KILN.md"))
        let session = try await PlatformSessionFactory.make(project: project)
        session.reloadMemory()
        let profile = try #require(session.agentProfile)
        #expect(session.effectiveProfile(profile).systemPrompt.contains("Always answer in French."))
        #expect(!profile.systemPrompt.contains("Always answer in French."))
        try await session.saveMemory(path: project.appendingPathComponent("KILN.md").path, text: "Be brief.")
        #expect(session.memory.injected.first?.content == "Be brief.")
    }
}
