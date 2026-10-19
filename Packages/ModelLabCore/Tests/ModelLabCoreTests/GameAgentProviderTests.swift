import Foundation
import Testing
@testable import ModelLabCore

struct GameAgentProviderTests {
    @Test func trainedCircuitPolicyCompletesGreedyEvaluation() {
        let trainer = GameAgentTrainer()
        let result = trainer.train(environment: .circuitSprint, episodes: 2_500)

        #expect(result.policy.evaluationReward > 10)
        #expect(trainer.evaluate(policy: result.policy) == result.policy.evaluationReward)
    }

    @Test func savedPolicyRoundTrips() throws {
        let policy = GameAgentTrainer().train(environment: .platformHop, episodes: 500).policy
        let store = GameAgentPolicyStore()
        let relativePath = try store.save(policy)
        defer { try? FileManager.default.removeItem(at: LibraryPaths.models.appendingPathComponent(relativePath)) }

        let loaded = try store.load(relativePath: relativePath)
        #expect(loaded.id == policy.id)
        #expect(loaded.environment == .platformHop)
    }
}
