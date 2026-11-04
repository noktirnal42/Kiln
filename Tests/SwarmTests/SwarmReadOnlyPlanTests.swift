import Testing
@testable import Kiln

@Suite("Read-only swarm goals")
struct SwarmReadOnlyPlanTests {
    private let reply = #"{"tasks":[{"id":"review","title":"Review","role":"implementer","expects":["file:report.md"]}]}"#

    @Test("goals that forbid changes are recognised") func detects() {
        #expect(SwarmPlanner.isReadOnly(goal: "Do a read-only review of the project"))
        #expect(SwarmPlanner.isReadOnly(goal: "Summarise the code. Do not write any files."))
        #expect(!SwarmPlanner.isReadOnly(goal: "Write summary.md with one paragraph"))
    }

    @Test("a read-only goal never keeps a required output file, so the run is not marked blocked") func dropsExpectations() async throws {
        let (graph, _) = await SwarmPlanner.plan(goal: "Read-only review of the repo") { _, _ in reply }
        #expect(try #require(graph.tasks.first).expects.isEmpty)
    }

    @Test("a goal that wants a file keeps its expectation") func keepsExpectations() async throws {
        let (graph, _) = await SwarmPlanner.plan(goal: "Write the report to report.md") { _, _ in reply }
        #expect(try #require(graph.tasks.first).expects == ["file:report.md"])
    }

    @Test("the planner is told not to expect files for a read-only goal") func promptNote() async {
        let seen = PromptBox()
        _ = await SwarmPlanner.plan(goal: "Read-only review") { system, _ in await seen.set(system); return "x" }
        #expect(await seen.value.contains("asked for no changes"))
    }
}

private actor PromptBox { var value = ""; func set(_ v: String) { value = v } }
