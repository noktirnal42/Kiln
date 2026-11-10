import Foundation
import AxiomCore

/// One line of a disassembly listing, parsed out of the text the engines produce (otool, Ghidra, radare2).
public struct REInstruction: Sendable, Equatable, Identifiable {
    public var id: UInt64 { address }
    public let address: UInt64
    public let mnemonic: String
    public let operands: String
    /// Trailing engine comment (`; symbol stub for: _puts`, `; literal pool for: "text"`), without the marker.
    public let comment: String?
    /// The line as the engine printed it, address included.
    public let raw: String

    public var text: String { operands.isEmpty ? mnemonic : mnemonic + " " + operands }
}

public enum REBranchKind: String, Sendable, Equatable {
    case none, jump, conditional, call, indirectJump, ret
    /// True when execution cannot continue to the next instruction.
    public var endsBlock: Bool { self == .jump || self == .indirectJump || self == .ret }
}

public enum REListing {
    // MARK: Parsing

    /// Parses `ADDR  mnemonic operands ; comment` lines. Non-instruction lines (headers, `; file:line` source markers,
    /// truncation notes) are skipped. Accepts tab- or space-separated text.
    public static func parse(_ assembly: String) -> [REInstruction] {
        var result: [REInstruction] = []
        result.reserveCapacity(assembly.count / 24)
        for line in assembly.split(separator: "\n", omittingEmptySubsequences: true) {
            if let instruction = parseLine(String(line)) { result.append(instruction) }
        }
        return result
    }

    public static func parseLine(_ line: String) -> REInstruction? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let split = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let token = String(trimmed[trimmed.startIndex..<split])
        let bare = token.hasSuffix(":") ? String(token.dropLast()) : token
        guard bare.count >= 4, let address = UInt64(bare.replacingOccurrences(of: "0x", with: ""), radix: 16) else { return nil }
        var body = trimmed[split...].trimmingCharacters(in: .whitespaces)
        // Raw instruction bytes some engines print between the address and the mnemonic are not part of the text.
        var comment: String?
        for marker in [" ; ", "\t; ", " ## ", "\t## ", " // "] {
            if let range = body.range(of: marker) {
                comment = body[range.upperBound...].trimmingCharacters(in: .whitespaces)
                body = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard !body.isEmpty else { return nil }
        let parts = body.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        let mnemonic = String(parts[0]).lowercased()
        let operands = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return REInstruction(address: address, mnemonic: mnemonic, operands: operands, comment: comment, raw: trimmed)
    }

    public static func hex(_ value: UInt64) -> String { String(value, radix: 16) }
    public static func address(_ text: String) -> UInt64? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "0x", with: "")
        return value.isEmpty ? nil : UInt64(value, radix: 16)
    }

    // MARK: Branches

    public static func branchKind(_ mnemonic: String) -> REBranchKind {
        let m = mnemonic.lowercased()
        switch m {
        case "ret", "retn", "retf", "retab", "retaa", "eret", "hlt", "ud2", "iret", "iretq", "sysret", "brk": return .ret
        case "b", "jmp", "ljmp": return .jump
        case "bl", "blr", "blraa", "blrab", "call", "lcall": return .call
        case "br", "braa", "brab": return .indirectJump
        case "cbz", "cbnz", "tbz", "tbnz": return .conditional
        default: break
        }
        if m.hasPrefix("b.") || m.hasPrefix("bc.") { return .conditional }
        // x86 conditional jumps: jcc, jecxz, loop. Excludes jmp, handled above.
        if m.hasPrefix("j") || m.hasPrefix("loop") { return .conditional }
        return .none
    }

    /// The branch's destination when it is spelled in the operands (an address literal) or names a known symbol.
    public static func branchTarget(_ instruction: REInstruction, symbols: [String: UInt64] = [:]) -> UInt64? {
        let kind = branchKind(instruction.mnemonic)
        guard kind == .jump || kind == .conditional || kind == .call else { return nil }
        // Indirect forms (`blr x8`, `call rax`, `call [rax+8]`) have no static target.
        guard let last = instruction.operands.split(separator: ",").last.map({ $0.trimmingCharacters(in: .whitespaces) }) else { return nil }
        if let tokenRange = addressTokens(in: last).first { return tokenRange.value }
        let symbol = last.trimmingCharacters(in: CharacterSet(charactersIn: " *"))
        if let value = symbols[symbol] { return value }
        // Ghidra prints `FUN_00100470`, `LAB_001004b0`, `thunk_FUN_...`: the address is in the name.
        for prefix in ["FUN_", "LAB_", "SUB_", "sub_", "loc_", "thunk_FUN_"] where symbol.hasPrefix(prefix) {
            if let value = UInt64(symbol.dropFirst(prefix.count), radix: 16) { return value }
        }
        return nil
    }

    // MARK: Links

    public struct AddressToken: Sendable, Equatable {
        public let range: Range<String.Index>
        public let value: UInt64
    }

    /// Hexadecimal address literals inside a line: `0x100000470`, or 6 or more bare hex digits next to a word boundary.
    /// Stack offsets (`#0x10`, `[sp, #-0x10]`) and small immediates are excluded so only plausible addresses become links.
    public static func addressTokens(in text: String, minimumDigits: Int = 5) -> [AddressToken] {
        var tokens: [AddressToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character.isHexDigit || character == "x" else { index = text.index(after: index); continue }
            // A token starts at a word boundary only.
            if index > text.startIndex {
                let previous = text[text.index(before: index)]
                if previous.isLetter || previous.isNumber || previous == "_" || previous == "-" || previous == "#" { 
                    // Skip the rest of this word.
                    var skip = index
                    while skip < text.endIndex, text[skip].isLetter || text[skip].isNumber || text[skip] == "_" { skip = text.index(after: skip) }
                    index = skip == index ? text.index(after: index) : skip
                    continue
                }
            }
            var end = index
            var digitsStart = index
            if text[index...].hasPrefix("0x") || text[index...].hasPrefix("0X") { end = text.index(index, offsetBy: 2); digitsStart = end }
            while end < text.endIndex, text[end].isHexDigit { end = text.index(after: end) }
            let digits = text[digitsStart..<end]
            let followedByWord = end < text.endIndex && (text[end].isLetter || text[end] == "_")
            let hasPrefix = digitsStart != index
            let hasLetterOrLong = digits.count >= minimumDigits
            if !followedByWord, hasLetterOrLong, !digits.isEmpty, digits.count <= 16,
               hasPrefix || digits.count >= 8,
               let value = UInt64(digits, radix: 16) {
                tokens.append(AddressToken(range: index..<end, value: value))
            }
            index = end == index ? text.index(after: index) : end
        }
        return tokens
    }

    /// Every quoted string in an instruction comment (`literal pool for: "text"`, `@"text"`).
    public static func quotedStrings(in comment: String) -> [String] {
        var result: [String] = []
        var current: String?
        var escaped = false
        for character in comment {
            if current != nil {
                if escaped { current?.append(character); escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { result.append(current ?? ""); current = nil }
                else { current?.append(character) }
            } else if character == "\"" { current = "" }
        }
        return result
    }

    /// Size in bytes of the instruction at `index`, from the distance to the next one (nil for the last).
    public static func length(of instructions: [REInstruction], at index: Int) -> Int? {
        guard index + 1 < instructions.count else { return nil }
        return Int(instructions[index + 1].address &- instructions[index].address)
    }

    /// Instruction set the analysis was made for, from the `file` description.
    public static func architecture(format: String, slice: String? = nil) -> String {
        let text = (slice ?? format).lowercased()
        if text.contains("arm64e") { return "arm64e" }
        if text.contains("arm64") || text.contains("aarch64") { return "arm64" }
        if text.contains("x86_64") || text.contains("x86-64") || text.contains("amd64") { return "x86_64" }
        if text.contains("i386") || text.contains("80386") || text.contains("intel 80386") { return "i386" }
        if text.contains("arm") { return "arm" }
        return "unknown"
    }
}
