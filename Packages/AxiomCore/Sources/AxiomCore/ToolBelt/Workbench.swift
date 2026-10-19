import Foundation

// Exploit-development workbench core (docs/KALI_METASPLOIT_PARITY.md T9): the analysis-side
// primitives an author needs while building a chain against a device they are authorized to
// research — cyclic offset patterns (pattern_create/pattern_offset equivalents) and ROP/JOP
// gadget search over the engines' disassembly output. This is analysis tooling: it reads and
// searches; it does not assemble payloads or talk to targets.

public enum CyclicPattern {
    static let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let lower = Array("abcdefghijklmnopqrstuvwxyz")
    static let digits = Array("0123456789")
    /// One full period of the triplet generator: 26 × 26 × 10 triplets × 3 bytes.
    static let period = 3 * 26 * 26 * 10

    /// The classic cyclic pattern: triplets Aa0, Aa1, … Aa9, Ab0, … — every 4-byte window is
    /// unique within one period, which is what makes offset lookup exact.
    public static func generate(_ length: Int) -> String {
        let bounded = min(max(length, 0), 8_388_608)   // 8 MiB cap; larger patterns serve no offset-finding purpose
        var out = [UInt8](); out.reserveCapacity(bounded)
        var index = 0
        while out.count < bounded {
            for byte in [upper[(index / 260) % 26].asciiValue!, lower[(index / 10) % 26].asciiValue!, digits[index % 10].asciiValue!] where out.count < bounded {
                out.append(byte)
            }
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Offset of an ASCII fragment (typically the register-overwrite bytes from a crash) inside
    /// the pattern, computed by searching one full period plus the query length. Queries that
    /// start mid-triplet work like any other position.
    public static func offset(of query: String) -> Int? {
        let bytes = Array(query.utf8)
        guard !bytes.isEmpty, bytes.count <= 16 else { return nil }
        let generated = generate(period + bytes.count)
        guard let range = generated.range(of: query) else { return nil }
        return generated.distance(from: generated.startIndex, to: range.lowerBound)
    }

    /// Accepts the raw register bytes as they appear in a crash dump (e.g. EIP = 0x41326941).
    /// Tries the byte sequence and its reverse, because endianness trips everyone once.
    public static func offset(ofBytes bytes: [UInt8]) -> Int? {
        if let direct = offset(of: String(decoding: bytes, as: UTF8.self)) { return direct }
        return offset(of: String(decoding: bytes.reversed(), as: UTF8.self))
    }
}

public struct Gadget: Codable, Sendable, Equatable {
    /// Address of the gadget's entry (the first instruction that will execute).
    public let address: String
    /// Instructions in execution order; the last element is the terminating instruction.
    public let instructions: [String]
}

public enum GadgetSearch {
    static func mnemonic(_ instruction: String) -> String {
        instruction.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
    }

    /// Searches disassembly text (engine output: one instruction per line, address first) for
    /// instruction sequences ending in the given mnemonic — the raw material of ROP/JOP chains.
    /// `depth` bounds how many instructions precede the terminator; control transfers break a
    /// chain; results are deduplicated and bounded by `limit`.
    public static func search(assembly: String, depth: Int = 5, ending: String = "ret", limit: Int = 1024) -> [Gadget] {
        let boundedDepth = min(max(depth, 1), 16)
        let endingMnemonic = ending.lowercased()
        var lines: [(address: String, instruction: String)] = []
        for rawLine in assembly.split(separator: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Engines format addresses differently (otool uses tabs, radare2 uses spaces);
            // accept any whitespace run between the address and the instruction.
            let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = parts.first, !first.isEmpty else { continue }
            let address = first.hasSuffix(":") ? String(first.dropLast()) : first
            let hex = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
            guard hex.count >= 4, UInt64(hex, radix: 16) != nil else { continue }
            lines.append((address, parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""))
        }
        var results: [Gadget] = []
        var seen = Set<[String]>()
        for index in lines.indices {
            guard mnemonic(lines[index].instruction).hasPrefix(endingMnemonic) else { continue }
            var chain = [lines[index].instruction]
            var back = index
            while chain.count <= boundedDepth, back > 0 {
                let previousMnemonic = mnemonic(lines[back - 1].instruction)
                if previousMnemonic.hasPrefix("ret") || previousMnemonic.hasPrefix("j") || previousMnemonic.hasPrefix("b") { break }
                chain.insert(lines[back - 1].instruction, at: 0)
                back -= 1
            }
            guard seen.insert(chain).inserted else { continue }
            results.append(Gadget(address: lines[back].address, instructions: chain))
            if results.count >= limit { break }
        }
        return results
    }

    /// Searches the disassembly of every function in a loaded project.
    public static func search(functions: [FunctionRecord], depth: Int = 5, ending: String = "ret", limit: Int = 1024) -> [Gadget] {
        search(assembly: functions.map(\.assembly).joined(separator: "\n"), depth: depth, ending: ending, limit: limit)
    }
}
