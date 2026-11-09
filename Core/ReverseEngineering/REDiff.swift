import Foundation
import AxiomCore

/// Function-level diff of two analysed binaries (two builds of one program, or a patched copy against its original).
public struct REDiffResult: Sendable, Equatable {
    public enum Status: String, Sendable { case unchanged, changed, added, removed }
    public struct Match: Sendable, Equatable, Identifiable {
        public var id: String { (a ?? "-") + "|" + (b ?? "-") }
        public let a: String?
        public let b: String?
        public let nameA: String?
        public let nameB: String?
        public let status: Status
        /// 0...1, by instruction sequence; 1 means identical mnemonics and operands after address normalisation.
        public let similarity: Double
        public let how: String
    }
    public let matches: [Match]
    public var changed: [Match] { matches.filter { $0.status == .changed } }
    public var added: [Match] { matches.filter { $0.status == .added } }
    public var removed: [Match] { matches.filter { $0.status == .removed } }
    public var unchanged: Int { matches.filter { $0.status == .unchanged }.count }

    public func json() -> [String: Any] {
        func row(_ m: Match) -> [String: Any] {
            var r: [String: Any] = ["status": m.status.rawValue, "similarity": (m.similarity * 1000).rounded() / 1000, "matched_by": m.how]
            if let a = m.a { r["address_a"] = a }; if let b = m.b { r["address_b"] = b }
            if let n = m.nameA { r["name_a"] = n }; if let n = m.nameB { r["name_b"] = n }
            return r
        }
        return ["unchanged": unchanged, "changed": changed.map(row), "added": added.map(row), "removed": removed.map(row)]
    }
}

public enum REDiff {
    /// Matches functions by name first (stripped binaries have none worth trusting), then by identical instruction hash, then by
    /// best Jaccard similarity of mnemonic trigrams plus the callee names. Addresses are masked so a relocated build still matches.
    public static func compare(_ a: Analysis, _ b: Analysis) -> REDiffResult {
        func names(_ analysis: Analysis) -> [String: String] {
            Dictionary(analysis.functions.map { (ProjectStore.normalizedAddress($0.address), $0.name) }, uniquingKeysWith: { first, _ in first })
        }
        let namesA = names(a), namesB2 = names(b)
        let fa = a.functions.map { Signature($0, names: namesA) }, fb = b.functions.map { Signature($0, names: namesB2) }
        var usedB = Set<Int>(), usedA = Set<Int>()
        var matches: [REDiffResult.Match] = []
        func record(_ i: Int, _ j: Int, how: String) {
            usedA.insert(i); usedB.insert(j)
            let similarity = fa[i].normalized == fb[j].normalized ? 1.0 : jaccard(fa[i].grams, fb[j].grams)
            let identical = fa[i].normalized == fb[j].normalized && fa[i].normalizedCode == fb[j].normalizedCode
            matches.append(.init(a: fa[i].address, b: fb[j].address, nameA: fa[i].name, nameB: fb[j].name,
                                 status: identical ? .unchanged : .changed, similarity: similarity, how: how))
        }
        // 1. Same meaningful name.
        var namesB: [String: Int] = [:]
        for (j, f) in fb.enumerated() where f.hasMeaningfulName { namesB[f.name] = namesB[f.name] == nil ? j : -1 }
        for (i, f) in fa.enumerated() where f.hasMeaningfulName {
            if let j = namesB[f.name], j >= 0, !usedB.contains(j) { record(i, j, how: "name") }
        }
        // 2. Identical normalised body.
        var hashesB: [Int: [Int]] = [:]
        for (j, f) in fb.enumerated() where !usedB.contains(j) && f.count >= 4 { hashesB[f.normalized, default: []].append(j) }
        for (i, f) in fa.enumerated() where !usedA.contains(i) {
            if let candidates = hashesB[f.normalized]?.filter({ !usedB.contains($0) }), let j = candidates.first { record(i, j, how: "identical code") }
        }
        // 3. Best fuzzy match above a threshold, one-to-one, preferring the same relative position.
        for (i, f) in fa.enumerated() where !usedA.contains(i) && f.grams.count >= 2 {
            var best: (Int, Double)?
            for (j, g) in fb.enumerated() where !usedB.contains(j) && g.grams.count >= 2 {
                let score = jaccard(f.grams, g.grams) * 0.85 + jaccard(f.callees, g.callees) * 0.15
                if score >= 0.6, score > (best?.1 ?? 0) { best = (j, score) }
            }
            if let best { record(i, best.0, how: "similar code") }
        }
        for (i, f) in fa.enumerated() where !usedA.contains(i) {
            matches.append(.init(a: f.address, b: nil, nameA: f.name, nameB: nil, status: .removed, similarity: 0, how: "no counterpart"))
        }
        for (j, g) in fb.enumerated() where !usedB.contains(j) {
            matches.append(.init(a: nil, b: g.address, nameA: nil, nameB: g.name, status: .added, similarity: 0, how: "no counterpart"))
        }
        return REDiffResult(matches: matches.sorted { ($0.status.rawValue, $0.nameA ?? $0.nameB ?? "") < ($1.status.rawValue, $1.nameA ?? $1.nameB ?? "") })
    }

    /// Unified-style listing diff of one matched pair, with addresses stripped so only real instruction changes show.
    public static func listingDiff(_ a: FunctionRecord, _ b: FunctionRecord) -> [String] {
        let left = REListing.parse(a.assembly).map { normalize($0.text) }, right = REListing.parse(b.assembly).map { normalize($0.text) }
        let difference = right.difference(from: left)
        var removals: [Int: String] = [:], insertions: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, let element, _): removals[offset] = element
            case .insert(let offset, let element, _): insertions[offset] = element
            }
        }
        var out: [String] = []; var i = 0, j = 0
        while i < left.count || j < right.count {
            if i < left.count, let removed = removals[i] { out.append("- " + removed); i += 1 }
            else if j < right.count, let inserted = insertions[j] { out.append("+ " + inserted); j += 1 }
            else { if i < left.count { out.append("  " + left[i]) }; i += 1; j += 1 }
        }
        return out
    }

    struct Signature {
        let address: String, name: String
        let normalized: Int
        let normalizedCode: Int
        let grams: Set<String>
        let callees: Set<String>
        let count: Int
        var hasMeaningfulName: Bool {
            !(name.hasPrefix("FUN_") || name.hasPrefix("sub_") || name.hasPrefix("thunk_") || name.hasPrefix("LAB_") || name.isEmpty)
        }
        init(_ function: FunctionRecord, names: [String: String]) {
            address = function.address; name = function.name
            let instructions = REListing.parse(function.assembly)
            count = instructions.count
            let mnemonics = instructions.map(\.mnemonic)
            normalized = mnemonics.joined(separator: ",").hashValue
            normalizedCode = instructions.map { REDiff.normalize($0.text) }.joined(separator: "\n").hashValue
            var g = Set<String>()
            if mnemonics.count >= 3 { for k in 0...(mnemonics.count - 3) { g.insert(mnemonics[k...k + 2].joined(separator: " ")) } }
            else if !mnemonics.isEmpty { g.insert(mnemonics.joined(separator: " ")) }
            grams = g
            callees = Set(function.callees.map { names[ProjectStore.normalizedAddress($0)] ?? "?" })
        }
    }

    /// Replaces address-looking literals with `ADDR` so relocated code compares equal.
    static func normalize(_ text: String) -> String {
        var result = text
        for token in REListing.addressTokens(in: text).reversed() { result.replaceSubrange(token.range, with: "ADDR") }
        return result
    }

    static func jaccard<T: Hashable>(_ x: Set<T>, _ y: Set<T>) -> Double {
        if x.isEmpty && y.isEmpty { return 1 }
        let union = x.union(y).count
        return union == 0 ? 0 : Double(x.intersection(y).count) / Double(union)
    }
}
