import Foundation
import Testing
@testable import Kiln

struct SlashCommandsTests {
    @Test func parsesOnlyRealCommands() {
        #expect(SlashCommands.parse("/review src/a.swift")?.name == "review")
        #expect(SlashCommands.parse("/review src/a.swift")?.arguments == "src/a.swift")
        #expect(SlashCommands.parse("/usr/bin/env") == nil)
        #expect(SlashCommands.parse("//") == nil)
        #expect(SlashCommands.parse("hello /compact") == nil)
    }

    @Test func frontmatterAndArguments() throws {
        let project = try PlatformTestSupport.tempDir()
        try PlatformTestSupport.write("---\ndescription: Review a file\nargument-hint: <file>\nmodel: m1\n---\nReview $1 carefully. Extra: $ARGUMENTS", to: project.appendingPathComponent(".kiln/commands/review.md"))
        try PlatformTestSupport.write("Just do it", to: project.appendingPathComponent(".kiln/commands/team/ship.md"))
        try PlatformTestSupport.write("shadow", to: project.appendingPathComponent(".kiln/commands/clear.md"))
        let commands = SlashCommands.loadCustom(workspaceRoot: project, home: nil)
        #expect(commands.map(\.name) == ["review", "team:ship"])
        let review = try #require(commands.first)
        #expect(review.summary == "Review a file" && review.argumentHint == "<file>" && review.model == "m1")
        #expect(SlashCommands.expand(review, arguments: "a.swift now") == "Review a.swift carefully. Extra: a.swift now")
        let ship = try #require(commands.last)
        #expect(SlashCommands.expand(ship, arguments: "fast") == "Just do it\n\nARGUMENTS: fast")
    }

    @Test func projectOverridesUserAndBuiltInsWin() throws {
        let home = try PlatformTestSupport.tempDir("home"), project = try PlatformTestSupport.tempDir()
        try PlatformTestSupport.write("user version", to: home.appendingPathComponent(".kiln/commands/x.md"))
        try PlatformTestSupport.write("project version", to: project.appendingPathComponent(".kiln/commands/x.md"))
        let commands = SlashCommands.all(workspaceRoot: project, home: home)
        #expect(SlashCommands.resolve("/x", commands: commands) == .prompt("project version", command: "x", model: nil))
        #expect(SlashCommands.resolve("/compact", commands: commands) == .builtIn(.compact, arguments: ""))
        #expect(SlashCommands.resolve("/nope", commands: commands) == .unknown("nope"))
        #expect(SlashCommands.resolve("plain", commands: commands) == .plainMessage)
    }

    @Test func completionMatchesPrefixThenSubstring() {
        let commands = SlashCommands.builtIns
        #expect(SlashCommands.completions(for: "/co", commands: commands).map(\.name).prefix(2) == ["compact", "commands"])
        #expect(SlashCommands.completions(for: "/model x", commands: commands).isEmpty)
        #expect(SlashCommands.completions(for: "/", commands: commands).count == commands.count)
        #expect(SlashCommands.fileURL(name: "clear", scope: .project, workspaceRoot: URL(fileURLWithPath: "/tmp"), home: nil) == nil)
    }

    @Test func toolsListExpandWriteAndAudit() async throws {
        let project = try PlatformTestSupport.tempDir(), home = try PlatformTestSupport.tempDir("home")
        let chain = try PlatformTestSupport.auditChain()
        var services = ToolServices(); services.audit = PlatformAudit(chain: chain)
        let context = ToolExecutionContext(workspaceRoot: project, conversationID: UUID(), services: services)
        let body = String(data: try JSONSerialization.data(withJSONObject: ["name": "fix", "content": "Fix $ARGUMENTS"]), encoding: .utf8)!
        _ = try await CommandWriteTool(home: home).execute(argumentsJSON: body, context: context)
        let listing = try await CommandListTool(home: home).execute(argumentsJSON: "{}", context: context)
        #expect(listing.contains("/fix [project]") && listing.contains("/compact [builtIn]"))
        let expanded = try await CommandExpandTool(home: home).execute(argumentsJSON: "{\"name\":\"fix\",\"arguments\":\"the bug\"}", context: context)
        #expect(expanded == "Fix the bug")
        let types = try await chain.recent(10).map(\.type)
        #expect(types.contains("command.saved") && types.contains("command.invoked"))
        await #expect(throws: (any Error).self) {
            _ = try await CommandWriteTool(home: home).execute(argumentsJSON: "{\"name\":\"clear\",\"content\":\"x\"}", context: context)
        }
    }
}

@MainActor
struct SlashCommandSessionTests {
    @Test func customCommandSendsExpandedPromptAndBuiltInsAct() async throws {
        let project = try PlatformTestSupport.tempDir()
        try PlatformTestSupport.write("Say hi to $ARGUMENTS", to: project.appendingPathComponent(".kiln/commands/greet.md"))
        let chain = try PlatformTestSupport.auditChain()
        let session = try await PlatformSessionFactory.make(project: project, chain: chain)
        session.agentEnabled = false
        await session.send("/greet Ada")
        #expect(session.messages.first?.content == "Say hi to Ada")
        await session.send("/memory")
        #expect(session.requestedPane == .memory)
        await session.send("/bogus")
        #expect(session.errorText?.contains("Unknown command") == true)
        let before = session.conversationID
        await session.send("/clear")
        #expect(session.conversationID != before && session.messages.isEmpty)
        await session.send("/model m1")
        #expect(session.selectedModelID == "stub-m1")
        let types = try await chain.recent(20).map(\.type)
        #expect(types.contains("command.invoked") && types.contains("command.builtin"))
    }
}
