import Foundation
import AxiomCore

/// One reference from an instruction (or a function) to an address, string or symbol.
public struct REReference: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case call, jump, data, string }
    public var id: String { "\(REListing.hex(from))>\(REListing.hex(to))#\(kind.rawValue)" }
    public let from: UInt64
    public let fromFunction: String?
    public let fromFunctionAddress: String?
    public let to: UInt64
    public let toName: String?
    public let kind: Kind
    public let context: String

    public var json: [String: Any] {
        var row: [String: Any] = ["from": REListing.hex(from), "to": REListing.hex(to), "kind": kind.rawValue, "context": context]
        if let fromFunction { row["from_function"] = fromFunction }
        if let toName { row["to_name"] = toName }
        return row
    }
}

/// What a clicked token resolves to.
public enum RETarget: Sendable, Equatable {
    case function(address: String, name: String)
    case address(UInt64, label: String?)
    case string(offset: Int, value: String)
}

/// Project-wide cross-reference index, built once from the functions' listings. Every address, string and symbol in the UI
/// resolves through it, and the agent's `re_get_references` returns the same rows.
public struct REXrefIndex: Sendable {
    public let references: [REReference]
    private let byTarget: [UInt64: [REReference]]
    private let bySource: [UInt64: [REReference]]
    private let byFunction: [String: [REReference]]
    private let byStringValue: [String: [REReference]]
    public let functionStarts: [UInt64: String]
    public let functionNames: [String: UInt64]
    public let labels: [UInt64: String]
    public let strings: [StringRecord]

    public static func build(_ analysis: Analysis) -> REXrefIndex {
        var starts: [UInt64: String] = [:]
        var names: [String: UInt64] = [:]
        var sortedFunctions: [(UInt64, FunctionRecord)] = []
        for function in analysis.functions {
            guard let address = REListing.address(function.address) else { continue }
            starts[address] = function.name; names[function.name] = address
            if let engine = function.engineName { names[engine] = address }
            sortedFunctions.append((address, function))
        }
        var labels: [UInt64: String] = [:]
        for (key, value) in analysis.addressLabels ?? [:] { if let address = REListing.address(key) { labels[address] = value } }
        let stringValues = Dictionary(analysis.strings.map { ($0.value, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [REReference] = []
        var seen = Set<String>()
        func add(_ reference: REReference) { if seen.insert(reference.id + "@" + reference.context).inserted { found.append(reference) } }

        for (functionAddress, function) in sortedFunctions {
            let instructions = REListing.parse(function.assembly)
            let functionKey = REListing.hex(functionAddress)
            var targetsHere = Set<UInt64>()
            for instruction in instructions {
                let kind = REListing.branchKind(instruction.mnemonic)
                let target = REListing.branchTarget(instruction, symbols: names)
                if let target, kind == .call || kind == .jump || kind == .conditional {
                    targetsHere.insert(target)
                    add(REReference(from: instruction.address, fromFunction: function.name, fromFunctionAddress: functionKey, to: target,
                                    toName: starts[target] ?? labels[target], kind: kind == .call ? .call : .jump, context: instruction.text))
                }
                // Address literals in operands that point at known functions or labelled data are data references.
                for token in REListing.addressTokens(in: instruction.operands) where token.value != target {
                    guard starts[token.value] != nil || labels[token.value] != nil else { continue }
                    add(REReference(from: instruction.address, fromFunction: function.name, fromFunctionAddress: functionKey, to: token.value,
                                    toName: starts[token.value] ?? labels[token.value], kind: .data, context: instruction.text))
                }
                // Symbolic operands (Ghidra and radare2 print names) refer to functions by name.
                if let target = names[symbolToken(in: instruction)], target != (REListing.branchTarget(instruction, symbols: names) ?? 0),
                   !targetsHere.contains(target) {
                    add(REReference(from: instruction.address, fromFunction: function.name, fromFunctionAddress: functionKey, to: target,
                                    toName: starts[target], kind: .data, context: instruction.text))
                }
                if let comment = instruction.comment {
                    for quoted in REListing.quotedStrings(in: comment) {
                        guard let record = stringValues[quoted] else { continue }
                        add(REReference(from: instruction.address, fromFunction: function.name, fromFunctionAddress: functionKey, to: UInt64(record.offset),
                                        toName: quoted, kind: .string, context: instruction.text + " ; " + comment))
                    }
                }
            }
            // Engine-recorded edges not visible in the listing (calls truncated away, indirect calls Ghidra resolved).
            for callee in function.callees {
                guard let target = REListing.address(callee), !targetsHere.contains(target) else { continue }
                add(REReference(from: functionAddress, fromFunction: function.name, fromFunctionAddress: functionKey, to: target,
                                toName: starts[target], kind: .call, context: "call recorded by the analysis engine"))
            }
        }
        var byTarget: [UInt64: [REReference]] = [:], bySource: [UInt64: [REReference]] = [:], byFunction: [String: [REReference]] = [:]
        var byString: [String: [REReference]] = [:]
        for reference in found {
            byTarget[reference.to, default: []].append(reference)
            bySource[reference.from, default: []].append(reference)
            if let function = reference.fromFunctionAddress { byFunction[function, default: []].append(reference) }
            if reference.kind == .string, let name = reference.toName { byString[name, default: []].append(reference) }
        }
        return REXrefIndex(references: found, byTarget: byTarget, bySource: bySource, byFunction: byFunction, byStringValue: byString,
                           functionStarts: starts, functionNames: names, labels: labels, strings: analysis.strings)
    }

    private static func symbolToken(in instruction: REInstruction) -> String {
        instruction.operands.split(separator: ",").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " *[]")) } ?? ""
    }

    // MARK: Queries

    /// Everything that refers to `address`: calls, jumps and data references.
    public func references(to address: UInt64) -> [REReference] { byTarget[address] ?? [] }
    /// References made by the instruction at `address`.
    public func references(from address: UInt64) -> [REReference] { bySource[address] ?? [] }
    /// References made by anything inside one function.
    public func references(inFunction address: String) -> [REReference] {
        byFunction[REListing.address(address).map(REListing.hex) ?? address] ?? []
    }
    /// Code that uses a string (by value) or an offset.
    public func references(toString value: String) -> [REReference] {
        if let direct = byStringValue[value] { return direct }
        let needle = value.lowercased()
        return byStringValue.filter { $0.key.lowercased().contains(needle) }.flatMap(\.value)
    }

    public func callers(of address: UInt64) -> [REReference] { references(to: address).filter { $0.kind == .call } }

    /// Resolves what the user clicked: a function name, an address inside the listing, a hex literal or a string value.
    public func resolve(_ token: String) -> RETarget? {
        let text = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let address = functionNames[text] ?? REListing.address(text).flatMap({ functionStarts[$0] != nil ? $0 : nil }) {
            return .function(address: REListing.hex(address), name: functionStarts[address] ?? text)
        }
        if let record = strings.first(where: { $0.value == text }) { return .string(offset: record.offset, value: record.value) }
        if let address = REListing.address(text) { return .address(address, label: labels[address]) }
        return nil
    }

    /// The function whose listing contains `address`.
    public func functionContaining(_ analysis: Analysis, address: UInt64) -> FunctionRecord? {
        var best: FunctionRecord?
        var bestStart: UInt64 = 0
        for function in analysis.functions {
            guard let start = REListing.address(function.address), start <= address, start >= bestStart else { continue }
            best = function; bestStart = start
        }
        guard let best else { return nil }
        let last = REListing.parse(best.assembly).last?.address ?? bestStart
        return address <= last ? best : nil
    }

    /// A readable summary for a reference panel: counts per kind plus the rows.
    public func summary(of references: [REReference]) -> [String: Int] {
        Dictionary(grouping: references, by: { $0.kind.rawValue }).mapValues(\.count)
    }
}
