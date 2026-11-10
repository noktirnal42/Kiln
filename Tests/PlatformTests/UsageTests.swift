import Foundation
import Testing
@testable import Kiln

struct UsageLedgerTests {
    private func record(_ model: String, provider: String = "nim", local: Bool = false, input: Int, output: Int, at date: Date = Date()) -> UsageRecord {
        UsageRecord(date: date, providerID: provider, modelID: model, local: local, inputTokens: input, outputTokens: output, conversationID: nil)
    }

    @Test func persistsAndSummarisesByProviderModelAndDay() throws {
        let dir = try PlatformTestSupport.tempDir("usage")
        let ledger = UsageLedger(directory: dir)
        ledger.setPrice(ModelPrice(inputPer1M: 1, outputPer1M: 3), forModel: "big")
        ledger.record(record("big", input: 1_000_000, output: 1_000_000))
        ledger.record(record("free", provider: "ollama", local: true, input: 500, output: 500))
        ledger.record(record("mystery", input: 2_000, output: 0))
        ledger.record(record("zero", input: 0, output: 0))      // nothing to record

        let reloaded = UsageLedger(directory: dir)
        #expect(reloaded.all.count == 3 && reloaded.prices["big"] != nil)
        let models = Dictionary(uniqueKeysWithValues: reloaded.byModel().map { ($0.key, $0) })
        #expect(models["big"]?.costUSD == 4.0)                       // 1M × $1 + 1M × $3
        #expect(models["free"]?.costUSD == 0)                        // local is free
        #expect(models["mystery"]?.unpricedTokens == 2_000)          // hosted with no price: not guessed
        #expect(reloaded.byProvider().first { $0.key == "nim" }?.tokens == 2_002_000)
        #expect(reloaded.daily().count == 1 && reloaded.today().runs == 3)
    }

    @Test func budgetStopsRunsByTokensAndDollars() throws {
        let ledger = UsageLedger(directory: try PlatformTestSupport.tempDir("usage"))
        ledger.setPrice(ModelPrice(inputPer1M: 10, outputPer1M: 10), forModel: "big")
        ledger.record(record("big", input: 50_000, output: 50_000))   // $1.00 today
        ledger.setBudget(UsageBudget(dailyTokens: 150_000, dailyUSD: 2.0))
        let gate = UsageBudgetGate(ledger: ledger, modelID: "big", local: false)
        #expect(gate.isActive)
        #expect(gate.check(runTokens: 10_000) == nil)
        #expect(gate.check(runTokens: 60_000)?.contains("token budget") == true)
        ledger.setBudget(UsageBudget(dailyTokens: 0, dailyUSD: 1.5))
        #expect(UsageBudgetGate(ledger: ledger, modelID: "big", local: false).check(runTokens: 60_000)?.contains("$1.50") == true)
        #expect(UsageBudgetGate(ledger: ledger, modelID: "big", local: true).check(runTokens: 60_000) == nil)   // local never spends dollars
        ledger.setBudget(UsageBudget())
        #expect(!UsageBudgetGate(ledger: ledger, modelID: "big", local: false).isActive)
    }
}

@MainActor
struct UsageSessionTests {
    @Test func aRunIsRecordedAndOverBudgetRunsStop() async throws {
        let ledger = UsageLedger(directory: try PlatformTestSupport.tempDir("usage"))
        let chain = try PlatformTestSupport.auditChain()
        let session = try await PlatformSessionFactory.make(project: nil, chain: chain, usage: ledger)
        await session.send("hello")
        let first = try #require(ledger.all.first)
        #expect(first.modelID == "stub-m1" && first.providerID == "stub" && first.totalTokens == 15)

        // A 10-token daily budget is already spent: the next run stops before calling the model.
        ledger.setBudget(UsageBudget(dailyTokens: 10, dailyUSD: 0))
        await session.send("again")
        #expect(session.messages.last?.content.contains("budget") == true || session.errorText?.contains("budget") == true)
        #expect(ledger.all.count == 1)
        #expect(try await chain.recent(40).map(\.type).contains("usage.budget_stop"))
    }
}
