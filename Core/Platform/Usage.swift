import Foundation

/// Tokens and estimated cost, per provider and model, with daily totals and an optional budget that stops a run.
/// Costs are estimates: Kiln knows tokens, not invoices. On-device and local models cost nothing; a hosted model has a
/// price only if the person entered one (Usage pane → prices), otherwise its cost shows as unpriced, never guessed.
public struct UsageRecord: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var providerID: String
    public var modelID: String
    public var local: Bool
    public var inputTokens: Int
    public var outputTokens: Int
    public var conversationID: UUID?
    public var totalTokens: Int { inputTokens + outputTokens }
}

public struct ModelPrice: Codable, Equatable, Sendable {
    public var inputPer1M: Double
    public var outputPer1M: Double
    public init(inputPer1M: Double, outputPer1M: Double) { self.inputPer1M = inputPer1M; self.outputPer1M = outputPer1M }
    /// When only a total is known, assume the average of the two.
    public var blendedPer1M: Double { (inputPer1M + outputPer1M) / 2 }
}

public struct UsageBudget: Codable, Equatable, Sendable {
    /// 0 = no limit.
    public var dailyTokens = 0
    public var dailyUSD = 0.0
    public var isSet: Bool { dailyTokens > 0 || dailyUSD > 0 }
}

public struct UsageLine: Equatable, Sendable {
    public var key: String
    public var tokens: Int
    public var costUSD: Double
    public var unpricedTokens: Int
    public var runs: Int
}

public final class UsageLedger: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var records: [UsageRecord] = []
    public private(set) var prices: [String: ModelPrice] = [:]
    public private(set) var budget = UsageBudget()
    private let calendar: Calendar

    public init(directory: URL, calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("usage.jsonl")), let text = String(data: data, encoding: .utf8) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            records = text.split(separator: "\n").compactMap { try? decoder.decode(UsageRecord.self, from: Data($0.utf8)) }
        }
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: directory.appendingPathComponent("prices.json")) { prices = (try? decoder.decode([String: ModelPrice].self, from: data)) ?? [:] }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("budget.json")) { budget = (try? decoder.decode(UsageBudget.self, from: data)) ?? UsageBudget() }
    }

    public static var `default`: UsageLedger {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return UsageLedger(directory: base.appendingPathComponent("Kiln/Usage", isDirectory: true))
    }

    public var all: [UsageRecord] { lock.withLock { records } }

    public func record(_ record: UsageRecord) {
        guard record.totalTokens > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        records.append(record)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0a)
        let url = directory.appendingPathComponent("usage.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line) }
        else { try? line.write(to: url) }
    }

    public func setPrice(_ price: ModelPrice?, forModel model: String) {
        lock.lock(); defer { lock.unlock() }
        prices[model] = price
        if let data = try? JSONEncoder().encode(prices) { try? data.write(to: directory.appendingPathComponent("prices.json"), options: .atomic) }
    }

    public func setBudget(_ budget: UsageBudget) {
        lock.lock(); defer { lock.unlock() }
        self.budget = budget
        if let data = try? JSONEncoder().encode(budget) { try? data.write(to: directory.appendingPathComponent("budget.json"), options: .atomic) }
    }

    /// Estimated cost of a record, nil when it has no price (hosted, none entered). Local models cost 0.
    public func cost(of record: UsageRecord) -> Double? {
        if record.local { return 0 }
        guard let price = prices[record.modelID] else { return nil }
        if record.inputTokens == 0 || record.outputTokens == 0 { return Double(record.totalTokens) / 1_000_000 * price.blendedPer1M }
        return Double(record.inputTokens) / 1_000_000 * price.inputPer1M + Double(record.outputTokens) / 1_000_000 * price.outputPer1M
    }

    private func summarise(_ list: [UsageRecord], key: (UsageRecord) -> String) -> [UsageLine] {
        var lines: [String: UsageLine] = [:]
        for record in list {
            var line = lines[key(record)] ?? UsageLine(key: key(record), tokens: 0, costUSD: 0, unpricedTokens: 0, runs: 0)
            line.tokens += record.totalTokens; line.runs += 1
            if let cost = cost(of: record) { line.costUSD += cost } else { line.unpricedTokens += record.totalTokens }
            lines[key(record)] = line
        }
        return lines.values.sorted { $0.tokens > $1.tokens }
    }

    public func byProvider(since: Date? = nil) -> [UsageLine] { summarise(all.filter { since == nil || $0.date >= since! }) { $0.providerID } }
    public func byModel(since: Date? = nil) -> [UsageLine] { summarise(all.filter { since == nil || $0.date >= since! }) { $0.modelID } }

    /// One line per day, newest first. The key is `yyyy-MM-dd`.
    public func daily(limit: Int = 30) -> [UsageLine] {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.dateFormat = "yyyy-MM-dd"
        return Array(summarise(all) { formatter.string(from: $0.date) }.sorted { $0.key > $1.key }.prefix(limit))
    }

    public func today(now: Date = Date()) -> UsageLine {
        let start = calendar.startOfDay(for: now)
        let list = all.filter { $0.date >= start }
        return summarise(list) { _ in "today" }.first ?? UsageLine(key: "today", tokens: 0, costUSD: 0, unpricedTokens: 0, runs: 0)
    }
}

/// Stops a run when today's usage plus this run's would pass the budget. Checked before every model call, so a run ends
/// at the next step instead of overspending. Unpriced tokens count toward the token cap but not the dollar cap, and the
/// message says so.
public final class UsageBudgetGate: @unchecked Sendable {
    private let budget: UsageBudget
    private let todayTokens: Int
    private let todayUSD: Double
    private let price: ModelPrice?
    private let local: Bool

    public init(ledger: UsageLedger, modelID: String, local: Bool, now: Date = Date()) {
        budget = ledger.budget
        let today = ledger.today(now: now)
        todayTokens = today.tokens; todayUSD = today.costUSD
        price = ledger.prices[modelID]; self.local = local
    }

    public var isActive: Bool { budget.isSet }

    /// A reason to stop, or nil.
    public func check(runTokens: Int) -> String? {
        if budget.dailyTokens > 0, todayTokens + runTokens >= budget.dailyTokens {
            return "Daily token budget of \(budget.dailyTokens.formatted()) reached (\((todayTokens + runTokens).formatted()) used today)."
        }
        if budget.dailyUSD > 0, !local, let price {
            let spent = todayUSD + Double(runTokens) / 1_000_000 * price.blendedPer1M
            if spent >= budget.dailyUSD { return String(format: "Daily budget of $%.2f reached (about $%.2f estimated today).", budget.dailyUSD, spent) }
        }
        return nil
    }
}
