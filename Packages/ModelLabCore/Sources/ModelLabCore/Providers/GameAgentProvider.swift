import Foundation

/// Two original, deterministic game-like environments. They intentionally use
/// no third-party game assets or ROMs, so policies can be trained and replayed
/// locally without presenting an emulator as part of Model Lab.
public enum GameAgentEnvironment: String, Codable, Sendable, CaseIterable, Identifiable {
    case circuitSprint
    case platformHop

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .circuitSprint: "Circuit Sprint"
        case .platformHop: "Platform Hop"
        }
    }

    public var summary: String {
        switch self {
        case .circuitSprint: "Steer through a shifting three-lane circuit."
        case .platformHop: "Choose the next landing lane across a platform course."
        }
    }

    public var laneTargets: [Int] { targetLanes }

    fileprivate var targetLanes: [Int] {
        switch self {
        case .circuitSprint:
            [1, 1, 0, 0, 1, 2, 2, 1, 0, 1, 2, 2, 1, 0]
        case .platformHop:
            [1, 2, 2, 1, 0, 0, 1, 2, 1, 0, 1, 2]
        }
    }
}

public enum GameAgentAction: Int, Codable, Sendable, CaseIterable {
    case left = -1
    case hold = 0
    case right = 1

    public var displayName: String {
        switch self {
        case .left: "Left"
        case .hold: "Hold"
        case .right: "Right"
        }
    }
}

public struct GameAgentState: Codable, Sendable, Hashable {
    public var segment: Int
    public var lane: Int

    public init(segment: Int, lane: Int) {
        self.segment = segment
        self.lane = lane
    }

    fileprivate var key: String { "\(segment):\(lane)" }
}

public struct GameAgentStep: Sendable {
    public let state: GameAgentState
    public let reward: Double
    public let isTerminal: Bool
    public let completedCourse: Bool
}

public struct GameAgentPolicy: Codable, Sendable, Identifiable {
    public let id: UUID
    public let environment: GameAgentEnvironment
    public let qValues: [String: [Double]]
    public let trainingEpisodes: Int
    public let meanTrainingReward: Double
    public let evaluationReward: Double
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        environment: GameAgentEnvironment,
        qValues: [String: [Double]],
        trainingEpisodes: Int,
        meanTrainingReward: Double,
        evaluationReward: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.environment = environment
        self.qValues = qValues
        self.trainingEpisodes = trainingEpisodes
        self.meanTrainingReward = meanTrainingReward
        self.evaluationReward = evaluationReward
        self.createdAt = createdAt
    }

    public func action(for state: GameAgentState) -> GameAgentAction {
        let values = qValues[state.key] ?? [0, 0, 0]
        let index = values.enumerated().max { lhs, rhs in
            lhs.element == rhs.element ? lhs.offset > rhs.offset : lhs.element < rhs.element
        }?.offset ?? 1
        return GameAgentAction(rawValue: index - 1) ?? .hold
    }
}

public struct GameAgentTrainingResult: Sendable {
    public let policy: GameAgentPolicy
    public let lastEpisodeReward: Double
}

public struct GameAgentTrainer: Sendable {
    public init() {}

    public func initialState(for environment: GameAgentEnvironment) -> GameAgentState {
        GameAgentState(segment: 0, lane: 1)
    }

    public func step(
        environment: GameAgentEnvironment,
        state: GameAgentState,
        action: GameAgentAction
    ) -> GameAgentStep {
        let lane = min(2, max(0, state.lane + action.rawValue))
        let nextSegment = state.segment + 1
        let targets = environment.targetLanes
        let target = targets[min(nextSegment - 1, targets.count - 1)]
        let distance = abs(lane - target)
        let onCourse = distance == 0
        let terminal = distance == 2 || nextSegment >= targets.count
        let completed = nextSegment >= targets.count && onCourse
        let reward: Double
        if completed {
            reward = 6
        } else if distance == 0 {
            reward = 1
        } else if distance == 1 {
            reward = -0.35
        } else {
            reward = -2
        }
        return GameAgentStep(
            state: GameAgentState(segment: min(nextSegment, targets.count), lane: lane),
            reward: reward,
            isTerminal: terminal,
            completedCourse: completed
        )
    }

    public func train(
        environment: GameAgentEnvironment,
        episodes: Int = 5_000,
        learningRate: Double = 0.2,
        discountFactor: Double = 0.94,
        explorationStart: Double = 0.3
    ) -> GameAgentTrainingResult {
        precondition(episodes > 0)
        var qValues: [String: [Double]] = [:]
        var rewards: [Double] = []
        rewards.reserveCapacity(episodes)
        var generator = GameAgentSeededGenerator(seed: 0x4d4f44454c4c4142)

        for episode in 0 ..< episodes {
            var state = initialState(for: environment)
            var totalReward = 0.0
            let exploration = max(0.02, explorationStart * (1 - Double(episode) / Double(episodes)))

            while true {
                let current = qValues[state.key] ?? [0, 0, 0]
                let actionIndex: Int
                if Double.random(in: 0 ... 1, using: &generator) < exploration {
                    actionIndex = Int.random(in: 0 ... 2, using: &generator)
                } else {
                    actionIndex = Self.bestActionIndex(values: current)
                }
                let action = GameAgentAction(rawValue: actionIndex - 1) ?? .hold
                let outcome = step(environment: environment, state: state, action: action)
                let future = outcome.isTerminal ? 0 : (qValues[outcome.state.key] ?? [0, 0, 0]).max() ?? 0
                var updated = current
                updated[actionIndex] += learningRate * (outcome.reward + discountFactor * future - updated[actionIndex])
                qValues[state.key] = updated
                totalReward += outcome.reward
                state = outcome.state
                if outcome.isTerminal { break }
            }
            rewards.append(totalReward)
        }

        let policy = GameAgentPolicy(
            environment: environment,
            qValues: qValues,
            trainingEpisodes: episodes,
            meanTrainingReward: rewards.reduce(0, +) / Double(rewards.count),
            evaluationReward: evaluate(qValues: qValues, environment: environment)
        )
        return GameAgentTrainingResult(policy: policy, lastEpisodeReward: rewards.last ?? 0)
    }

    public func evaluate(policy: GameAgentPolicy) -> Double {
        evaluate(qValues: policy.qValues, environment: policy.environment)
    }

    private func evaluate(qValues: [String: [Double]], environment: GameAgentEnvironment) -> Double {
        var state = initialState(for: environment)
        var reward = 0.0
        while true {
            let values = qValues[state.key] ?? [0, 0, 0]
            let action = GameAgentAction(rawValue: Self.bestActionIndex(values: values) - 1) ?? .hold
            let outcome = step(environment: environment, state: state, action: action)
            reward += outcome.reward
            state = outcome.state
            if outcome.isTerminal { return reward }
        }
    }

    private static func bestActionIndex(values: [Double]) -> Int {
        values.enumerated().max { lhs, rhs in
            lhs.element == rhs.element ? lhs.offset > rhs.offset : lhs.element < rhs.element
        }?.offset ?? 1
    }
}

public struct GameAgentPolicyStore: Sendable {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func save(_ policy: GameAgentPolicy) throws -> String {
        let filename = "game-agent-\(policy.environment.rawValue)-\(policy.id.uuidString.prefix(8)).json"
        let url = LibraryPaths.models.appendingPathComponent(filename)
        try encoder.encode(policy).write(to: url, options: .atomic)
        return filename
    }

    public func load(relativePath: String) throws -> GameAgentPolicy {
        let url = LibraryPaths.models.appendingPathComponent(relativePath)
        return try decoder.decode(GameAgentPolicy.self, from: Data(contentsOf: url))
    }
}

private struct GameAgentSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
