import Testing
import Foundation
@testable import SuperMetaApp

// swift test cannot exercise MLX paths on this machine (metallib packaging
// issue — see CAPABILITIES.md); these tests cover the pure metric math and
// every non-MLX behavior.

@Suite struct MetricsTests {
    @Test func accuracyPerfectAndPartial() throws {
        let accuracy = AccuracyMetric()
        #expect(try accuracy.score(predictions: ["pos", "NEG", "neg"], references: ["pos", "neg", "neg"]) == 1.0)
        #expect(try accuracy.score(predictions: ["a", "b", "c", "d"], references: ["a", "b", "x", "d"]) == 0.75)
    }

    @Test func accuracyRejectsMismatchedCounts() {
        #expect(throws: MetricError.countMismatch(predictions: 2, references: 3)) {
            try AccuracyMetric().score(predictions: ["a", "b"], references: ["a", "b", "c"])
        }
    }

    @Test func accuracyRejectsEmpty() {
        #expect(throws: MetricError.emptyInput) {
            try AccuracyMetric().score(predictions: [], references: [])
        }
    }

    @Test func macroF1KnownValue() throws {
        // pos: p=1.0, r=2/3 → 0.8 ; neg: p=0.5, r=1 → 2/3 ; macro = 0.7333
        let f1 = F1Metric()
        let value = try f1.score(
            predictions: ["pos", "pos", "neg", "neg"],
            references: ["pos", "pos", "neg", "pos"]
        )
        #expect(abs(value - 0.733333) < 0.0001)
    }

    @Test func bleuIdenticalCorpusIsOne() throws {
        let bleu = BLEUMetric(maxN: 3)
        #expect(try bleu.score(predictions: ["the cat sat"], references: ["the cat sat"]) == 1.0)
    }

    @Test func bleuTwoGramKnownValue() throws {
        // h="the cat was found" r="the cat is found": p1=3/4, p2=1/3,
        // equal lengths so BP=1 → sqrt(3/4 · 1/3) = 0.5 exactly.
        let bleu = BLEUMetric(maxN: 2)
        let value = try bleu.score(predictions: ["the cat was found"], references: ["the cat is found"])
        #expect(abs(value - 0.5) < 0.0001)
    }

    @Test func bleuZeroWhenHighestNGramMissing() throws {
        // 4-gram precision is 0 → corpus BLEU is 0 by the standard formula.
        let bleu = BLEUMetric()
        #expect(try bleu.score(predictions: ["the cat was found"], references: ["the cat is found"]) == 0)
    }

    @Test func bleuBrevityPenaltyApplies() throws {
        // Short hypothesis vs long reference, 1-gram metric: p=1, r=1 at
        // n=1 but BP = exp(1 - 6/2) = exp(-2).
        let bleu = BLEUMetric(maxN: 1)
        let value = try bleu.score(predictions: ["the cat"], references: ["the cat sat on the mat"])
        #expect(abs(value - exp(-2.0)) < 0.0001)
    }

    @Test func rougeKnownValues() throws {
        let h = ["the cat sat"]
        let r = ["the cat ran"]
        #expect(abs(try ROUGEMetric(.rouge1).score(predictions: h, references: r) - 2.0 / 3.0) < 0.0001)
        #expect(abs(try ROUGEMetric(.rouge2).score(predictions: h, references: r) - 0.5) < 0.0001)
        #expect(abs(try ROUGEMetric(.rougeL).score(predictions: h, references: r) - 2.0 / 3.0) < 0.0001)
    }

    @Test func rougeIdenticalIsOne() throws {
        for variant in [ROUGEMetric.Variant.rouge1, .rouge2, .rougeL] {
            #expect(try ROUGEMetric(variant).score(predictions: ["a b c"], references: ["a b c"]) == 1.0)
        }
    }

    @Test func perplexityKnownValues() throws {
        let metric = PerplexityMetric()
        #expect(try metric.perplexity(fromNegativeLogLikelihoods: [log(2), log(2)]) == 2.0)
        #expect(try metric.perplexity(fromNegativeLogLikelihoods: [0, 0]) == 1.0)
        #expect(abs(try metric.perplexity(fromLogProbabilities: [-1.0, -2.0]) - exp(1.5)) < 0.0001)
    }

    @Test func perplexityRejectsEmpty() {
        #expect(throws: MetricError.emptyInput) {
            _ = try PerplexityMetric().perplexity(fromNegativeLogLikelihoods: [])
        }
    }

    @Test func evaluationRunnerCollectsOutcomes() throws {
        let run = try EvaluationRunner().evaluate(
            modelName: "test",
            predictions: ["a", "b"],
            references: ["a", "b"],
            metrics: [AccuracyMetric(), BLEUMetric()]
        )
        #expect(run.outcomes.count == 2)
        #expect(run.outcomes.contains { $0.metricName == "accuracy" && $0.value == 1.0 })
    }

    @Test func customMetricProtocolExtends() throws {
        struct LengthRatioMetric: LabMetric {
            let name = "length-ratio"
            let lowerIsBetter = false
            func score(predictions: [String], references: [String]) throws -> Double {
                guard predictions.count == references.count, !predictions.isEmpty else {
                    throw MetricError.emptyInput
                }
                let p = predictions.map(\.count).reduce(0, +)
                let r = references.map(\.count).reduce(0, +)
                return Double(p) / Double(r)
            }
        }
        let run = try EvaluationRunner().evaluate(
            modelName: "custom",
            predictions: ["abc"],
            references: ["abcdef"],
            metrics: [LengthRatioMetric()]
        )
        #expect(run.outcomes.first?.value == 0.5)
    }
}
