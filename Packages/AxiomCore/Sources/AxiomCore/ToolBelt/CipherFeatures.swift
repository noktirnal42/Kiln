import Foundation

// Feature extraction for the cipher classifier (docs/ML_MODELS_PLAN.md §1, v1): a fixed-length
// statistical vector over raw bytes — byte histogram, windowed-entropy summary, hashed byte
// 4-grams, the existing CryptoIdentifier signature families as boolean evidence, and a length
// bucket. Deterministic, allocation-bounded, and identical at training and inference time,
// which is the property that makes a classical model reproducible.

public struct FeatureLayout: Codable, Sendable, Equatable {
    public var histogramBins = 256
    public var entropyStats = 8
    public var gramBuckets = 512
    /// 2-gram buckets: on machine code these capture opcode+modrm pairs that 4-grams miss.
    public var twoGramBuckets = 256
    /// Names of the CryptoIdentifier families folded into the vector, in fixed order.
    public var signatureFamilies: [String] = ["AES", "SHA-2", "SHA-1", "MD5", "SHA-512", "Keccak/SHA-3", "Blowfish", "ChaCha/Salsa", "CRC-32", "RSA"]
    public var tailFeatures = 2   // length bucket + high-byte ratio
    public var dimension: Int { histogramBins + entropyStats + gramBuckets + twoGramBuckets + signatureFamilies.count + tailFeatures }
    public init() {}
}

public enum FeatureExtractor {
    /// Feature window: everything past this is statistically redundant for a few-KB classifier.
    static let maxWindow = 8192
    static let gramOrder = 4
    /// FNV-1a mixing for the n-gram buckets, fixed so training and inference agree forever.
    static let gramSeed: UInt64 = 0xcbf29ce484222325

    public static func extract(_ data: Data, layout: FeatureLayout = FeatureLayout()) -> [Double] {
        var features = [Double](repeating: 0, count: layout.dimension)
        let window = [UInt8](data.prefix(maxWindow))
        guard !window.isEmpty else { return features }

        // 1. Byte histogram, normalized to a probability distribution.
        var histogram = [Int](repeating: 0, count: 256)
        for byte in window { histogram[Int(byte)] += 1 }
        let total = Double(window.count)
        for bin in 0..<256 { features[bin] = Double(histogram[bin]) / total }

        // 2. Entropy summary over 256-byte windows: overall, mean, variance, min, max,
        //    first-window, last-window, and the fraction of windows above 7.0.
        let windowSize = 256
        var entropies: [Double] = []
        if window.count >= windowSize {
            var bins = [Int](repeating: 0, count: 256)
            var base = 0
            while base + windowSize <= window.count {
                for index in 0..<256 { bins[index] = 0 }
                for index in base..<(base + windowSize) { bins[Int(window[index])] += 1 }
                var entropy = 0.0
                for count in bins where count > 0 {
                    let p = Double(count) / Double(windowSize)
                    entropy -= p * log2(p)
                }
                entropies.append(entropy)
                base += windowSize
            }
        }
        let overall = shannon(histogram, total: total)
        let stats: [Double]
        if entropies.isEmpty {
            stats = [overall, overall, 0, overall, overall, overall, overall, overall > 7.0 ? 1 : 0]
        } else {
            let mean = entropies.reduce(0, +) / Double(entropies.count)
            let variance = entropies.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(entropies.count)
            stats = [overall, mean, variance, entropies.min()!, entropies.max()!, entropies.first!, entropies.last!,
                     Double(entropies.filter { $0 > 7.0 }.count) / Double(entropies.count)]
        }
        for (index, value) in stats.enumerated() where index < layout.entropyStats { features[256 + index] = value }

        // 3. Hashed byte 4-grams, L2-normalized counts.
        let gramBase = 256 + layout.entropyStats
        if window.count >= gramOrder {
            var gramCounts = [Double](repeating: 0, count: layout.gramBuckets)
            var rolling: UInt64 = gramSeed
            for index in 0..<window.count {
                rolling = (rolling ^ UInt64(window[index])) &* 0x100000001b3
                if index >= gramOrder - 1 {
                    gramCounts[Int(rolling % UInt64(layout.gramBuckets))] += 1
                    rolling = gramSeed   // re-seed per window: order-4 non-overlapping hashing stays position-independent
                }
            }
            let gramTotal = Double(window.count - gramOrder + 1)
            for bucket in 0..<layout.gramBuckets { features[gramBase + bucket] = gramCounts[bucket] / gramTotal }
        }

        // 3b. Hashed byte 2-grams: opcode+modrm pairs on machine code; the strongest cheap
        // addition found while iterating on the evaluation gate (docs/ML_MODELS_PLAN.md).
        let twoGramBase = gramBase + layout.gramBuckets
        if window.count >= 2 {
            var pairCounts = [Double](repeating: 0, count: layout.twoGramBuckets)
            for index in 0..<(window.count - 1) {
                var pair: UInt64 = gramSeed
                pair = (pair ^ UInt64(window[index])) &* 0x100000001b3
                pair = (pair ^ UInt64(window[index + 1])) &* 0x100000001b3
                pairCounts[Int(pair % UInt64(layout.twoGramBuckets))] += 1
            }
            let pairTotal = Double(window.count - 1)
            for bucket in 0..<layout.twoGramBuckets { features[twoGramBase + bucket] = pairCounts[bucket] / pairTotal }
        }

        // 4. Crypto-constant signature families as booleans (a partial constant match is strong
        //    evidence; this reuses the stage-2 scanner as a feature, not a competing path).
        let signatureBase = twoGramBase + layout.twoGramBuckets
        let hits = CryptoIdentifier.scan(data)
        for (index, family) in layout.signatureFamilies.enumerated() {
            features[signatureBase + index] = hits.contains { $0.algorithm == family } ? 1 : 0
        }

        // 5. Tail: log-scaled length bucket and the high-byte (≥ 0x80) ratio.
        let tailBase = signatureBase + layout.signatureFamilies.count
        features[tailBase] = min(log2(Double(max(data.count, 1))) / 16.0, 1.0)
        features[tailBase + 1] = Double(window.filter { $0 >= 0x80 }.count) / total
        return features
    }

    static func shannon(_ bins: [Int], total: Double) -> Double {
        guard total > 0 else { return 0 }
        var result = 0.0
        for count in bins where count > 0 {
            let p = Double(count) / total
            result -= p * log2(p)
        }
        return result
    }
}
