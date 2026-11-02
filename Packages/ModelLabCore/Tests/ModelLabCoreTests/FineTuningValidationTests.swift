import Testing
@testable import ModelLabCore

struct FineTuningValidationTests {
    private func job(texts: [String] = ["An example"], rate: Float = 0.001, name: String = "adapter") -> FineTuningJob {
        FineTuningJob(baseModelRepoID: "example/model", trainingTexts: texts, learningRate: rate, outputName: name)
    }

    @Test func rejectsEmptyDataAndUnsafeOutputs() throws {
        #expect(throws: FineTuningError.self) { try MLXFineTuningProvider.validate(job: job(texts: ["  \n"])) }
        #expect(throws: FineTuningError.self) { try MLXFineTuningProvider.validate(job: job(name: "../other")) }
        #expect(throws: FineTuningError.self) { try MLXFineTuningProvider.validate(job: job(rate: .nan)) }
        try MLXFineTuningProvider.validate(job: job())
    }
}
