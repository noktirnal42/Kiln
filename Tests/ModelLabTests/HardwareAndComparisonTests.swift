import Testing
import Foundation
import ModelLabCore
@testable import Kiln

@Suite struct HardwareProfileTests {
    @Test func untestedNetworkAndMLXDoNotClaimAvailability() {
        #expect(CapabilityDetector.detectNetwork().status == .notChecked)
        if CapabilityDetector.detectHardware().status.isAvailable {
            #expect(CapabilityDetector.detectMLX().status == .notChecked)
        }
    }
    @Test func catalogProbeChecksResponseAndRejectsErrors() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let session = ProviderSessions.stubbed()
        MockURLProtocol.route("huggingface.co/api/models", json: "[]")
        #expect(await CapabilityDetector.checkNetwork(session: session).status == .available)
        MockURLProtocol.route("huggingface.co/api/models", status: 503, json: "{}")
        #expect(!(await CapabilityDetector.checkNetwork(session: session).status.isAvailable))
        MockURLProtocol.route("huggingface.co/api/models", json: "{}")
        #expect(!(await CapabilityDetector.checkNetwork(session: session).status.isAvailable))
    }
    @Test func liveProbeReturnsRealValues() {
        let profile = HardwareProfile.current()
        #expect(profile.memoryGB > 0)
        #expect(profile.coreCount > 0)
    }

    @Test func eighteenGBHostWarnsOnLargeLoads() {
        // The reference machine: M3 Pro, 18 GB. A 7B fp16 model (~14 GB
        // weights) must NOT fit; a 4-bit 0.6B model (~0.4 GB) must fit.
        let host = HardwareProfile(isAppleSilicon: true, memoryGB: 18, coreCount: 11, metalDeviceName: "Apple M3 Pro")
        if case .doesNotFit = host.canLoad(weightsBytes: 14 * 1_073_741_824, forTraining: false) {
        } else {
            Issue.record("14 GB weights should not fit an 18 GB host")
        }
        if case .fits = host.canLoad(weightsBytes: 400 * 1_048_576, forTraining: false) {
        } else {
            Issue.record("0.4 GB weights should fit an 18 GB host")
        }
    }

    @Test func trainingNeedsMoreOverheadThanInference() {
        let host = HardwareProfile(isAppleSilicon: true, memoryGB: 18, coreCount: 11, metalDeviceName: nil)
        // 9 GB weights fit inference (9+2 < 12.6) but not training (9+8 > 12.6).
        let nineGB: Int64 = 9 * 1_073_741_824
        if case .fits = host.canLoad(weightsBytes: nineGB, forTraining: false) {} else {
            Issue.record("9 GB weights + 2 GB overhead fits 18 GB host inference")
        }
        if case .tight = host.canLoad(weightsBytes: nineGB, forTraining: true) {} else {
            Issue.record("9 GB weights + 8 GB overhead is tight on an 18 GB host")
        }
    }

    @Test func quantizationAdviceScalesWithParameters() {
        let host = HardwareProfile(isAppleSilicon: true, memoryGB: 18, coreCount: 11, metalDeviceName: nil)
        #expect(host.recommendedQuantization(parameterCount: 0.6e9) == .fourBit)
        #expect(host.recommendedQuantization(parameterCount: 32e9) == nil) // even 4-bit won't fit
    }

    @Test func warningsNameTheActualNumbers() {
        let host = HardwareProfile(isAppleSilicon: true, memoryGB: 18, coreCount: 11, metalDeviceName: nil)
        let warnings = host.warnings(weightsBytes: 14 * 1_073_741_824, forTraining: false)
        #expect(warnings.contains { $0.contains("Does not fit") && $0.contains("GB") })
        // Training on <24 GB hosts gets the LoRA-over-full-fine-tune advice.
        let trainingWarnings = host.warnings(weightsBytes: 14 * 1_073_741_824, forTraining: true)
        #expect(warnings.contains { $0.contains("Does not fit") && $0.contains("GB") })
        #expect(trainingWarnings.contains { $0.contains("LoRA") })
    }

    @Test func intelHostIsFlagged() {
        let intel = HardwareProfile(isAppleSilicon: false, memoryGB: 32, coreCount: 8, metalDeviceName: nil)
        #expect(intel.warnings(weightsBytes: 1_000_000, forTraining: false).contains { $0.contains("Intel") })
    }
}

@Suite struct ExperimentComparisonTests {
    @Test func finalMetricsTakeLatestObservation() {
        let points = [
            MetricPoint(timestamp: Date(timeIntervalSince1970: 1), name: "loss", value: 3.1),
            MetricPoint(timestamp: Date(timeIntervalSince1970: 2), name: "loss", value: 1.0),
        ]
        #expect(ExperimentComparison.finalMetrics(from: points)["loss"] == 1.0)
    }

    @Test func bestIsDirectionAware() {
        let goodLoss = ExperimentComparisonEntry(
            id: "good", name: "good", task: .mlxFineTuning, status: .completed,
            elapsedSeconds: 10, finalMetrics: ["loss": 0.5], hyperparameters: [:], producedArtifactID: nil
        )
        let badLoss = ExperimentComparisonEntry(
            id: "bad", name: "bad", task: .mlxFineTuning, status: .completed,
            elapsedSeconds: 10, finalMetrics: ["loss": 2.0], hyperparameters: [:], producedArtifactID: nil
        )
        let higherAcc = ExperimentComparisonEntry(
            id: "acc", name: "acc", task: .textClassification, status: .completed,
            elapsedSeconds: 10, finalMetrics: ["validationAccuracy": 0.9], hyperparameters: [:], producedArtifactID: nil
        )
        let lowerAcc = ExperimentComparisonEntry(
            id: "acc2", name: "acc2", task: .textClassification, status: .completed,
            elapsedSeconds: 10, finalMetrics: ["validationAccuracy": 0.7], hyperparameters: [:], producedArtifactID: nil
        )
        let comparison = ExperimentComparison(entries: [goodLoss, badLoss, higherAcc, lowerAcc])
        #expect(comparison.best(forMetric: "loss")?.id == "good")          // lower loss wins
        #expect(comparison.best(forMetric: "perplexity") == nil)           // nobody recorded it
        #expect(comparison.best(forMetric: "validationAccuracy")?.id == "acc") // higher accuracy wins
    }

    @Test func deltaSignsFollowMetricDirection() {
        let a = ExperimentComparisonEntry(
            id: "a", name: "a", task: .mlxFineTuning, status: .completed,
            elapsedSeconds: nil, finalMetrics: ["loss": 0.5, "validationAccuracy": 0.9],
            hyperparameters: [:], producedArtifactID: nil
        )
        let b = ExperimentComparisonEntry(
            id: "b", name: "b", task: .mlxFineTuning, status: .completed,
            elapsedSeconds: nil, finalMetrics: ["loss": 2.0, "validationAccuracy": 0.7],
            hyperparameters: [:], producedArtifactID: nil
        )
        let comparison = ExperimentComparison(entries: [a, b])
        #expect(comparison.delta(improved: a, baseline: b, metric: "loss") == 1.5) // lower is better → positive improvement
        let deltaAccuracy = comparison.delta(improved: a, baseline: b, metric: "validationAccuracy")
        #expect(deltaAccuracy != nil)
        #expect(abs(deltaAccuracy! - 0.2) < 0.0001)
        #expect(comparison.delta(improved: a, baseline: b, metric: "missing") == nil)
    }
}
