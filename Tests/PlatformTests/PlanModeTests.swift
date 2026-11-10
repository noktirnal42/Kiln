import Foundation
import Testing
@testable import Kiln

@MainActor
struct PlanModeTests {
    private func session(project: URL, chain: AuditChain) async throws -> ChatSession {
        var stub = PlatformSessionFactory.Stub()
        stub.reply = { request in
            let planning = request.messages.first?.content.contains("# Plan mode") == true
            if request.messages.last?.role == .tool {
                return ChatMessage(role: .assistant, content: planning ? "Goal: add a.txt\n1. write a.txt" : "done")
            }
            let call = ToolCall(id: "c1", name: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#, index: 0)
            return ChatMessage(role: .assistant, content: "", toolCalls: [call])
        }
        return try await PlatformSessionFactory.make(project: project, chain: chain, stub: stub,
                                                     toolRegistry: ToolRegistry(tools: [WriteFileTool()]), autoResolve: .approveOnce)
    }

    @Test func planRunWritesNothingThenApprovalRunsThePlan() async throws {
        let project = try PlatformTestSupport.tempDir()
        let chain = try PlatformTestSupport.auditChain()
        let session = try await session(project: project, chain: chain)
        let target = project.appendingPathComponent("a.txt")
        await session.send("/plan on")
        #expect(session.planMode)
        await session.send("add a.txt")
        // The model tried to write; plan mode refused, and the run ended with a plan.
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let plan = try #require(session.pendingPlan)
        #expect(plan.text.contains("1. write a.txt") && plan.request == "add a.txt")

        await session.approvePlan(editedText: plan.text + "\n2. nothing else")
        #expect(!session.planMode && session.pendingPlan == nil)
        #expect(session.messages.contains { $0.role == .user && $0.content.contains("2. nothing else") && $0.content.contains("approved") })
        #expect(FileManager.default.fileExists(atPath: target.path))

        let types = try await chain.recent(60).map(\.type)
        #expect(types.contains("plan.mode") && types.contains("plan.proposed") && types.contains("plan.approved"))
    }

    @Test func rejectingDiscardsThePlanAndWritesNothing() async throws {
        let project = try PlatformTestSupport.tempDir()
        let chain = try PlatformTestSupport.auditChain()
        let session = try await session(project: project, chain: chain)
        session.planMode = true
        await session.send("add a.txt")
        #expect(session.pendingPlan != nil)
        await session.rejectPlan()
        #expect(session.pendingPlan == nil)
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("a.txt").path))
        #expect(try await chain.recent(60).map(\.type).contains("plan.rejected"))
    }

    @Test func slashPlanParsing() {
        #expect(PlanMode.parse("on") == true && PlanMode.parse("off") == false && PlanMode.parse("") == nil)
    }
}
