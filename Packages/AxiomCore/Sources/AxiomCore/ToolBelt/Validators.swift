import Foundation

// Structural validators (docs/DECRYPTION_TOOLING.md stage 3, capability 2): every decryption
// candidate is judged by recognizable structure, never by assuming success. Results always name
// the evidence; a bare "decrypted" claim without evidence is never produced.

public struct ValidatorResult: Codable, Sendable, Equatable {
    public let name: String
    public let passed: Bool
    public let detail: String
}

public enum Validators {
    /// Runs every validator and returns all results, pass or fail, so the analyst can see why a
    /// candidate ranked the way it did.
    public static func assess(_ data: Data) -> [ValidatorResult] {
        guard !data.isEmpty else { return [ValidatorResult(name: "empty", passed: false, detail: "no output produced")] }
        var out: [ValidatorResult] = []
        // Rebase so offset slices from the orchestrator behave like fresh data, then probe the head.
        let probe = Data(data).prefix(4096)
        let first = probe.first
        let formatNames = FormatIdentifier.scan(Data(probe)).filter { $0.offset == 0 }.map(\.format)
        out.append(ValidatorResult(name: "magic", passed: !formatNames.isEmpty, detail: formatNames.isEmpty ? "no known format magic at offset 0" : formatNames.joined(separator: ", ")))
        if first == 0x7b || first == 0x5b {
            if let object = try? JSONSerialization.jsonObject(with: Data(probe), options: [.fragmentsAllowed]) {
                out.append(ValidatorResult(name: "json", passed: true, detail: "parsed as \(type(of: object))"))
            } else {
                out.append(ValidatorResult(name: "json", passed: false, detail: "starts like JSON but does not parse"))
            }
        }
        if probe.starts(with: Data("bplist00".utf8)),
           (try? PropertyListSerialization.propertyList(from: Data(probe), options: [], format: nil)) != nil {
            out.append(ValidatorResult(name: "plist", passed: true, detail: "parses as a property list"))
        }
        let ratio = printableRatio(probe)
        out.append(ValidatorResult(name: "text", passed: ratio > 0.85, detail: String(format: "%.0f%% printable bytes", ratio * 100)))
        let entropy = EntropyScanner.score(probe)
        if entropy > 7.9 {
            out.append(ValidatorResult(name: "entropy", passed: false, detail: String(format: "%.2f bits/byte — output is still high-entropy (another layer of encryption or compression?)", entropy)))
        } else {
            out.append(ValidatorResult(name: "entropy", passed: true, detail: String(format: "%.2f bits/byte", entropy)))
        }
        return out
    }

    /// Aggregate ranking score in 0...1. Structural evidence weights highest; a magic match alone
    /// can carry a candidate, noise never scores above the gate.
    public static func score(_ results: [ValidatorResult]) -> Double {
        var score = 0.0
        for result in results where result.passed {
            switch result.name {
            case "magic": score += 0.5
            case "json", "plist": score += 0.35
            case "text": score += 0.2
            case "entropy": score += 0.15
            default: score += 0.1
            }
        }
        return min(score, 1.0)
    }

    public static func printableRatio(_ data: Data) -> Double {
        guard !data.isEmpty else { return 0 }
        var printable = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<raw.count where (32...126).contains(raw[index]) || raw[index] == 9 || raw[index] == 10 || raw[index] == 13 { printable += 1 }
        }
        return Double(printable) / Double(data.count)
    }
}
