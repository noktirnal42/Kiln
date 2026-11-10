import Foundation
import Testing
@testable import Kiln

@MainActor
struct HooksTests {
    private func project(hooks: String, scripts: [String: String] = [:]) throws -> URL {
        let dir = try PlatformTestSupport.tempDir()
        try PlatformTestSupport.write(hooks, to: dir.appendingPathComponent(".kiln/hooks/hooks.json"))
        for (name, body) in scripts {
            let url = dir.appendingPathComponent(".kiln/hooks/\(name)")
            try PlatformTestSupport.write(body, to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return dir
    }

    @Test func exitTwoDeniesAndJSONAnnotates() async throws {
        let dir = try project(hooks: """
        {"hooks":[{"event":"pre_tool","match":"run_command","command":".kiln/hooks/deny.sh"},
                  {"event":"post_tool","match":"*","command":".kiln/hooks/note.sh"},
                  {"event":"pre_tool","match":"read_file","command":"exit 7"}]}
        """, scripts: ["deny.sh": "#!/bin/zsh\ncat >/dev/null\necho 'no rm' >&2\nexit 2\n",
                       "note.sh": "#!/bin/zsh\ncat >/dev/null\necho '{\"decision\":\"annotate\",\"note\":\"remember tests\"}'\n"])
        let chain = try PlatformTestSupport.auditChain()
        let runner = HookRunner(hooks: HookRunner.load(workspaceRoot: dir, home: nil), workspaceRoot: dir, audit: PlatformAudit(chain: chain))
        let denied = await runner.run(.preTool, tool: "run_command", payload: ["arguments": ["command": "rm -rf x"]])
        #expect(denied.denial == "no rm")
        let noted = await runner.run(.postTool, tool: "write_file", payload: [:])
        #expect(noted.notes == ["remember tests"])
        let failed = await runner.run(.preTool, tool: "read_file", payload: [:])
        #expect(failed.denial == nil && failed.decisions.first?.verdict == .failed)
        let other = await runner.run(.preTool, tool: "glob_files", payload: [:])
        #expect(other.decisions.isEmpty)
        let events = try await chain.recent(10).filter { $0.type == "hook.decision" }
        #expect(events.count == 3)
    }

    @Test func hookReceivesEventJSONOnStdin() async throws {
        let dir = try project(hooks: #"{"hooks":[{"event":"prompt_submit","command":"cat > seen.json"}]}"#)
        let runner = HookRunner(hooks: HookRunner.load(workspaceRoot: dir, home: nil), workspaceRoot: dir)
        _ = await runner.run(.promptSubmit, payload: ["prompt_characters": 12])
        let seen = try String(contentsOf: dir.appendingPathComponent("seen.json"), encoding: .utf8)
        #expect(seen.contains("prompt_submit") && seen.contains("12"))
    }

    @Test func allowNeverSkipsAnApproval() async throws {
        // An allow decision is recorded but the run still stops at the approval gate; a denial in the approval center ends the call.
        let dir = try project(hooks: #"{"hooks":[{"event":"pre_tool","match":"write_file","command":"echo '{\"decision\":\"allow\"}'"}]}"#)
        let (center, watcher) = try makeTestApprovalCenter(autoResolve: .deny)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(toolRegistry: ToolRegistry(tools: [WriteFileTool()]), approvalCenter: center)
        var profile = AgentProfile(name: "t", mode: .act, toolPermissions: ToolPermissionSet(enabledTools: ["write_file"]))
        profile.modelID = "m"
        let call = ToolCall(id: "c1", name: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#, index: 0)
        let calls = HookCallCounter()
        let stream = orchestrator.run(profile: profile, prompt: "go", workspaceRoot: dir, hooks: HookRunner.load(workspaceRoot: dir, home: nil)) { _ in
            let n = calls.next()
            return AsyncThrowingStream { c in
                c.yield(ChatChunk(delta: ChatMessage(role: .assistant, content: n == 0 ? "" : "done"), finishReason: .stop, toolCalls: n == 0 ? [call] : []))
                c.finish()
            }
        }
        var denied = false
        for try await event in stream { if case .toolCallFinished(let r) = event, r.status == .denied { denied = true } }
        #expect(denied)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path))
    }

    @Test func preToolDenialBlocksTheCallInARun() async throws {
        let dir = try project(hooks: #"{"hooks":[{"event":"pre_tool","match":"write_file","command":"echo nope >&2; exit 2"}]}"#)
        let (center, watcher) = try makeTestApprovalCenter(autoResolve: .approveOnce)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(toolRegistry: ToolRegistry(tools: [WriteFileTool()]), approvalCenter: center)
        var profile = AgentProfile(name: "t", mode: .act, toolPermissions: ToolPermissionSet(enabledTools: ["write_file"]))
        profile.modelID = "m"
        let call = ToolCall(id: "c1", name: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#, index: 0)
        let calls = HookCallCounter()
        let stream = orchestrator.run(profile: profile, prompt: "go", workspaceRoot: dir, hooks: HookRunner.load(workspaceRoot: dir, home: nil)) { _ in
            let n = calls.next()
            return AsyncThrowingStream { c in
                c.yield(ChatChunk(delta: ChatMessage(role: .assistant, content: n == 0 ? "" : "done"), finishReason: .stop, toolCalls: n == 0 ? [call] : []))
                c.finish()
            }
        }
        var reason = ""
        for try await event in stream { if case .toolCallFinished(let r) = event, r.status == .denied { reason = r.errorText ?? "" } }
        #expect(reason.contains("hook blocked") && reason.contains("nope"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path))
    }
}

final class HookCallCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
