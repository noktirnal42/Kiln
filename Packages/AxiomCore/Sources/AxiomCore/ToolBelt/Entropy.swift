import Foundation

// Ciphertext discovery (docs/DECRYPTION_TOOLING.md stage 1): a sliding-window entropy profile
// over raw file bytes. High, flat entropy is the signature of encryption or compression; the
// loader's own knowledge of already-parsed compressed sections is applied upstream of this scan.

/// One contiguous region whose windows averaged at or above the entropy threshold.
public struct EntropyRegion: Codable, Sendable, Equatable {
    public let offset: Int
    public let length: Int
    public let meanEntropy: Double
}

public enum EntropyScanner {
    /// Shannon entropy of the byte distribution, in bits per byte (0...8).
    public static func score(_ data: Data) -> Double {
        guard !data.isEmpty else { return 0 }
        var bins = [Int](repeating: 0, count: 256)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<raw.count { bins[Int(raw[index])] += 1 }
        }
        return shannon(bins: bins, total: data.count)
    }

    static func shannon(bins: [Int], total: Int) -> Double {
        guard total > 0 else { return 0 }
        var result = 0.0
        let totalDouble = Double(total)
        for count in bins where count > 0 {
            let p = Double(count) / totalDouble
            result -= p * log2(p)
        }
        return result
    }

    /// Clusters consecutive high-entropy windows into regions. `gapTolerance` merges regions
    /// separated by a short low-entropy stretch (headers, block separators).
    public static func regions(in data: Data, window: Int = 256, threshold: Double = 7.0, minLength: Int = 4096, gapTolerance: Int = 1024) -> [EntropyRegion] {
        guard window > 0, data.count >= window else { return [] }
        let windowCount = data.count / window
        var entropies = [Double](repeating: 0, count: windowCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var bins = [Int](repeating: 0, count: 256)
            for w in 0..<windowCount {
                for index in 0..<256 { bins[index] = 0 }
                let base = w * window
                for index in base..<(base + window) { bins[Int(raw[index])] += 1 }
                entropies[w] = shannon(bins: bins, total: window)
            }
        }
        var regions: [EntropyRegion] = []
        var start: Int?; var lowRun = 0
        for (index, entropy) in entropies.enumerated() {
            if entropy >= threshold {
                if start == nil { start = index }
                lowRun = 0
            } else if let current = start {
                lowRun += 1
                if lowRun > max(1, gapTolerance / window) {
                    close(&regions, from: current, through: index - lowRun, entropies: entropies, window: window, minLength: minLength)
                    start = nil; lowRun = 0
                }
            }
        }
        if let current = start { close(&regions, from: current, through: windowCount - 1, entropies: entropies, window: window, minLength: minLength) }
        return regions
    }

    private static func close(_ regions: inout [EntropyRegion], from firstWindow: Int, through lastWindow: Int, entropies: [Double], window: Int, minLength: Int) {
        let windows = lastWindow - firstWindow + 1
        guard windows > 0, windows * window >= minLength else { return }
        let mean = entropies[firstWindow...lastWindow].reduce(0, +) / Double(windows)
        regions.append(EntropyRegion(offset: firstWindow * window, length: windows * window, meanEntropy: (mean * 100).rounded() / 100))
    }
}
