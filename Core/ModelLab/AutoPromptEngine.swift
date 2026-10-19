import Foundation

/// Prompt 5 item 9 — prompt generation and optimization. Generation is
/// deterministic for a given seed (templates + mutation); the LLM leg is
/// optional and only used when a generator closure is supplied by the
/// module, so tests and offline use exercise the deterministic paths.
public struct AutoPromptEngine: Sendable {
    public struct Constraints: Sendable, Equatable {
        public var maxPrompts: Int
        public var seed: UInt64
        public var includeMutations: Bool
        public var includeTemplates: Bool

        public init(maxPrompts: Int = 12, seed: UInt64 = 42, includeMutations: Bool = true, includeTemplates: Bool = true) {
            self.maxPrompts = maxPrompts
            self.seed = seed
            self.includeMutations = includeMutations
            self.includeTemplates = includeTemplates
        }
    }

    public struct Task: Sendable, Equatable {
        public let description: String
        public let seedPrompts: [String]

        public init(description: String, seedPrompts: [String]) {
            self.description = description
            self.seedPrompts = seedPrompts
        }
    }

    /// Optional LLM leg: given a task description, produce candidate prompts.
    /// The module wires this to the app's ModelRegistry; tests leave it nil.
    public typealias LLMGenerator = @Sendable (Task, Int) async -> [String]

    private let templates: [String]
    private let llmGenerator: LLMGenerator?

    public init(templates: [String] = Self.defaultTemplates, llmGenerator: LLMGenerator? = nil) {
        self.templates = templates
        self.llmGenerator = llmGenerator
    }

    public static let defaultTemplates: [String] = [
        "You are a helpful assistant. {task}",
        "Complete the following task carefully and concisely: {task}",
        "Step by step, reason about: {task}",
        "As an expert reviewer, evaluate: {task}",
        "List the key considerations for: {task}",
        "Explain to a beginner: {task}",
        "Summarize the tradeoffs involved in: {task}",
        "What could go wrong with: {task}? Answer concretely.",
    ]

    public func generatePrompts(for task: Task, constraints: Constraints = Constraints()) async -> [String] {
        var candidates: [String] = []
        if constraints.includeTemplates {
            candidates.append(contentsOf: templates.map { template in
                template.replacingOccurrences(of: "{task}", with: task.description)
            })
        }
        candidates.append(contentsOf: task.seedPrompts)
        if constraints.includeMutations {
            var generator = SeededRandom(seed: constraints.seed)
            let mutationSources = task.seedPrompts.isEmpty ? candidates : task.seedPrompts
            for source in mutationSources {
                candidates.append(contentsOf: Self.mutations(of: source, count: 3, using: &generator))
            }
        }
        if let llmGenerator {
            candidates.append(contentsOf: await llmGenerator(task, max(4, constraints.maxPrompts / 3)))
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }.prefix(constraints.maxPrompts).map { $0 }
    }

    /// Deterministic mutations: small, meaningful edits (prefix, suffix,
    /// imperative rephrase, sentence shuffle) rather than character noise.
    static func mutations(of prompt: String, count: Int, using generator: inout SeededRandom) -> [String] {
        var results: [String] = []
        for _ in 0..<count {
            switch generator.nextBounded(5) {
            case 0:
                results.append("Please be precise. " + prompt)
            case 1:
                results.append(prompt + " Support your answer with specifics.")
            case 2:
                results.append("Answer directly: " + prompt)
            case 3:
                results.append("Think critically and answer: " + prompt)
            default:
                let sentences = prompt.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if sentences.count > 1, let shuffled = generator.shuffle(sentences) {
                    results.append(shuffled.joined(separator: ". ") + ".")
                } else {
                    results.append(prompt)
                }
            }
        }
        return results
    }

    /// Hill-climbing optimization against a caller-supplied evaluator
    /// (higher score is better). Keeps the best-so-far; deterministic given
    /// the seed and evaluator.
    public struct OptimizationResult: Sendable, Equatable {
        public let bestPrompt: String
        public let bestScore: Double
        public let iterationsRun: Int
        public let candidatesEvaluated: Int
    }

    public func optimizePrompt(
        initial: String,
        task: Task,
        evaluator: @escaping @Sendable (String) async -> Double,
        iterations: Int,
        constraints: Constraints = Constraints()
    ) async -> OptimizationResult {
        var best = initial
        var bestScore = await evaluator(best)
        var evaluated = 1
        var generator = SeededRandom(seed: constraints.seed)
        for _ in 0..<iterations {
            var current = best
            for _ in 0..<4 {
                let candidate = Self.mutations(of: current, count: 1, using: &generator).first ?? current
                let score = await evaluator(candidate)
                evaluated += 1
                if score > bestScore {
                    bestScore = score
                    best = candidate
                    current = candidate
                }
            }
        }
        return OptimizationResult(
            bestPrompt: best,
            bestScore: bestScore,
            iterationsRun: iterations,
            candidatesEvaluated: evaluated
        )
    }
}

/// Deterministic splitmix64 — small, seedable, no Foundation randomness, so
/// mutation sequences are reproducible in tests.
public struct SeededRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func nextBounded(_ bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(next() % UInt64(bound))
    }

    public mutating func shuffle<T>(_ items: [T]) -> [T]? {
        guard items.count > 1 else { return nil }
        var copy = items
        for index in stride(from: copy.count - 1, to: 0, by: -1) {
            let swapIndex = nextBounded(index + 1)
            copy.swapAt(index, swapIndex)
        }
        return copy
    }
}
