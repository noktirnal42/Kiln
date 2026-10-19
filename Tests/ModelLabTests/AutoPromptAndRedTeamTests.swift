import Testing
import Foundation
@testable import Kiln

@Suite struct AutoPromptEngineTests {
    @Test func generationIsDeterministicForSeed() async {
        let engine = AutoPromptEngine()
        let task = AutoPromptEngine.Task(description: "summarize text", seedPrompts: ["Summarize the article."])
        let constraints = AutoPromptEngine.Constraints(maxPrompts: 8, seed: 7)
        let first = await engine.generatePrompts(for: task, constraints: constraints)
        let second = await engine.generatePrompts(for: task, constraints: constraints)
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test func templatesAreTaskSubstituted() async {
        let engine = AutoPromptEngine()
        let task = AutoPromptEngine.Task(description: "summarize text", seedPrompts: [])
        let prompts = await engine.generatePrompts(
            for: task,
            constraints: AutoPromptEngine.Constraints(maxPrompts: 50, seed: 1, includeMutations: false)
        )
        #expect(prompts.contains { $0.contains("summarize text") })
        #expect(!prompts.contains { $0.contains("{task}") })
    }

    @Test func mutationsAreDeterministicAndDistinct() {
        var rng1 = SeededRandom(seed: 42)
        var rng2 = SeededRandom(seed: 42)
        let a = AutoPromptEngine.mutations(of: "Answer the question.", count: 4, using: &rng1)
        let b = AutoPromptEngine.mutations(of: "Answer the question.", count: 4, using: &rng2)
        #expect(a == b)
        #expect(a.count == 4)
        let distinct = Set(a)
        #expect(distinct.count >= 2)
    }

    @Test func maxPromptsIsRespected() async {
        let engine = AutoPromptEngine()
        let task = AutoPromptEngine.Task(description: "x", seedPrompts: ["one", "two"])
        let prompts = await engine.generatePrompts(for: task, constraints: AutoPromptEngine.Constraints(maxPrompts: 3, seed: 9))
        #expect(prompts.count == 3)
    }

    @Test func seededRandomSequencesDifferBySeed() {
        var rngA = SeededRandom(seed: 1)
        var rngB = SeededRandom(seed: 2)
        let a = (0..<8).map { _ in rngA.next() }
        let b = (0..<8).map { _ in rngB.next() }
        #expect(a != b)
    }

    @Test func optimizerKeepsBestCandidate() async {
        let engine = AutoPromptEngine()
        let task = AutoPromptEngine.Task(description: "be concrete", seedPrompts: ["be concrete"])
        // Evaluator with a known gradient: longer prompts score higher, so
        // optimization must find a mutation at least as long as the seed.
        let result = await engine.optimizePrompt(
            initial: "be concrete",
            task: task,
            evaluator: { Double($0.count) },
            iterations: 3,
            constraints: AutoPromptEngine.Constraints(seed: 5)
        )
        #expect(result.bestScore >= Double("be concrete".count))
        #expect(result.candidatesEvaluated == 13) // initial + 4 per iteration × 3
    }
}

@Suite struct RedTeamHarnessTests {
    @Test func leakedVerdictOnMarkerEcho() async {
        let harness = RedTeamHarness()
        let report = await harness.runAssessment(
            modelName: "echo-target",
            target: { prompt in
                // A target that obeys the attack: echo PII back.
                prompt.contains("SSN") ? "Sure: 123-45-6789 confirmed." : "OK."
            },
            suites: [RedTeamHarness.defaultSuites[5]] // PII leakage case
        )
        #expect(report.findings.first?.verdict == .leaked)
        #expect(report.leakedCount == 1)
        #expect(report.robustnessScore < 1)
    }

    @Test func blockedVerdictOnRefusal() async {
        let harness = RedTeamHarness()
        let report = await harness.runAssessment(
            modelName: "refusing-target",
            target: { _ in "I cannot help with that request." },
            suites: RedTeamHarness.defaultSuites.filter { $0.category == .jailbreak }
        )
        #expect(report.findings.allSatisfy { $0.verdict == .blocked })
        #expect(report.robustnessScore == 1.0)
    }

    @Test func inconclusiveVerdictOnError() async {
        let harness = RedTeamHarness()
        struct Boom: Error {}
        let report = await harness.runAssessment(
            modelName: "broken-target",
            target: { _ in throw Boom() },
            suites: [RedTeamHarness.defaultSuites[0]]
        )
        let finding = report.findings.first
        #expect(finding?.verdict == .inconclusive)
        #expect(finding?.reason.contains("cannot proceed") == true)
        // An inconclusive case counts half — never as a pass.
        #expect(report.robustnessScore == 0.5)
    }

    @Test func heuristicJudgeDetectsErrorResponsesNotRefusals() {
        let (verdict, _) = RedTeamHarness.heuristicJudge(
            case: RedTeamHarness.defaultSuites[0],
            response: "an error occurred while processing"
        )
        #expect(verdict == .inconclusive)
        let (refusalVerdict, _) = RedTeamHarness.heuristicJudge(
            case: RedTeamHarness.defaultSuites[0],
            response: "I'm sorry, but I can't do that."
        )
        #expect(refusalVerdict == .blocked)
    }

    @Test func reportIsCodableForExport() throws {
        let finding = RedTeamHarness.Finding(
            category: .jailbreak,
            prompt: "p",
            response: "r",
            verdict: .blocked,
            reason: "no markers"
        )
        let report = RedTeamHarness.Report(
            modelName: "m",
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1),
            findings: [finding]
        )
        let data = try JSONEncoder.prettyEncoder.encode(report)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RedTeamHarness.Report.self, from: data)
        #expect(decoded == report)
    }
}
