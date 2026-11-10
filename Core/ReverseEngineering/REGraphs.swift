import Foundation
import CoreGraphics
import AxiomCore

// Control-flow and call graphs. Pure data and layout: the GUI draws what these produce and the agent tools return the same
// structure as JSON, so a screenshot and a tool call describe one graph.

public struct CFGEdge: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case sequential = "fallthrough", taken, jump, back }
    public var id: String { "\(from)->\(to)" }
    public let from: UInt64
    public let to: UInt64
    public let kind: Kind
}

public struct CFGNode: Sendable, Equatable, Identifiable {
    public var id: UInt64 { address }
    public let address: UInt64
    public let instructions: [REInstruction]
    /// Layout, in graph coordinates (top-left origin).
    public var frame: CGRect = .zero
    public var layer = 0
    public var end: UInt64 { instructions.last?.address ?? address }
    /// Names of the functions this block calls, for the block header.
    public var calls: [String] = []
}

public struct ControlFlowGraph: Sendable, Equatable {
    public let function: String
    public let entry: UInt64
    public var nodes: [CFGNode]
    public var edges: [CFGEdge]
    public var size: CGSize
    /// `engine` when basic blocks came from Ghidra or radare2, `derived` when rebuilt from branch instructions.
    public let source: String

    public func node(containing address: UInt64) -> CFGNode? {
        nodes.first { address >= $0.address && address <= $0.end }
    }

    /// Cyclomatic complexity: edges − nodes + 2.
    public var complexity: Int { max(1, edges.count - nodes.count + 2) }

    /// Graphviz DOT, for export and for opening in other tools.
    public func dot() -> String {
        var out = "digraph \"\(function)\" {\n  node [shape=box, fontname=Menlo, fontsize=9];\n"
        for node in nodes {
            let label = node.instructions.map { "\(REListing.hex($0.address))  \($0.text)" }.joined(separator: "\\l")
                .replacingOccurrences(of: "\"", with: "\\\"")
            out += "  b\(REListing.hex(node.address)) [label=\"\(label)\\l\"];\n"
        }
        for edge in edges {
            let color = edge.kind == .taken ? "green" : edge.kind == .sequential ? "red" : edge.kind == .back ? "blue" : "black"
            out += "  b\(REListing.hex(edge.from)) -> b\(REListing.hex(edge.to)) [color=\(color)];\n"
        }
        return out + "}\n"
    }

    public func json() -> [String: Any] {
        ["function": function, "entry": REListing.hex(entry), "source": source, "complexity": complexity,
         "blocks": nodes.map { node -> [String: Any] in
            ["address": REListing.hex(node.address), "end": REListing.hex(node.end), "instructions": node.instructions.count,
             "calls": node.calls, "listing": node.instructions.map(\.raw)]
         },
         "edges": edges.map { ["from": REListing.hex($0.from), "to": REListing.hex($0.to), "kind": $0.kind.rawValue] }]
    }
}

public enum CFGBuilder {
    public static let nodeLineHeight: CGFloat = 14
    public static let nodeHeaderHeight: CGFloat = 20
    public static let characterWidth: CGFloat = 6.8
    public static let horizontalGap: CGFloat = 36
    public static let verticalGap: CGFloat = 40

    /// Builds and lays out the graph of one function. `symbols` maps names to addresses so symbolic branch targets
    /// (`bl _helper`) become calls; `names` maps addresses to display names.
    public static func build(function: FunctionRecord, symbols: [String: UInt64] = [:], names: [UInt64: String] = [:]) -> ControlFlowGraph {
        let instructions = REListing.parse(function.assembly)
        let entry = REListing.address(function.address) ?? instructions.first?.address ?? 0
        guard !instructions.isEmpty else {
            return ControlFlowGraph(function: function.name, entry: entry, nodes: [], edges: [], size: .zero, source: "derived")
        }
        let byAddress = Dictionary(instructions.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        var leaders: Set<UInt64> = [instructions[0].address]
        var engineDestinations: [UInt64: [UInt64]] = [:]
        var source = "derived"
        if let blocks = function.blocks, !blocks.isEmpty {
            source = "engine"
            for block in blocks {
                guard let start = REListing.address(block.address) else { continue }
                leaders.insert(start)
                engineDestinations[start] = block.destinations.compactMap(REListing.address)
            }
        } else {
            for (index, instruction) in instructions.enumerated() {
                let kind = REListing.branchKind(instruction.mnemonic)
                guard kind == .jump || kind == .conditional || kind == .ret || kind == .indirectJump else { continue }
                if index + 1 < instructions.count { leaders.insert(instructions[index + 1].address) }
                if kind == .jump || kind == .conditional,
                   let target = REListing.branchTarget(instruction, symbols: symbols), byAddress[target] != nil { leaders.insert(target) }
            }
        }
        // Split the instruction stream at leaders.
        var groups: [[REInstruction]] = []
        for instruction in instructions {
            if leaders.contains(instruction.address) || groups.isEmpty { groups.append([instruction]) }
            else { groups[groups.count - 1].append(instruction) }
        }
        let nodes = groups.map { group -> CFGNode in
            var node = CFGNode(address: group[0].address, instructions: group)
            node.calls = group.compactMap { instruction in
                guard REListing.branchKind(instruction.mnemonic) == .call,
                      let target = REListing.branchTarget(instruction, symbols: symbols) else { return nil }
                return names[target] ?? "0x" + REListing.hex(target)
            }
            return node
        }
        let starts = Set(nodes.map(\.address))
        var edges: [CFGEdge] = []
        func add(_ from: UInt64, _ to: UInt64, _ kind: CFGEdge.Kind) {
            guard starts.contains(to), !edges.contains(where: { $0.from == from && $0.to == to }) else { return }
            edges.append(CFGEdge(from: from, to: to, kind: to <= from && kind != .sequential ? .back : kind))
        }
        for (index, node) in nodes.enumerated() {
            let last = node.instructions[node.instructions.count - 1]
            let kind = REListing.branchKind(last.mnemonic)
            let next = index + 1 < nodes.count ? nodes[index + 1].address : nil
            if source == "engine", let destinations = engineDestinations[node.address], !destinations.isEmpty {
                for destination in destinations {
                    if destination == next { add(node.address, destination, kind == .conditional || kind == .none ? .sequential : .jump) }
                    else { add(node.address, destination, kind == .conditional ? .taken : .jump) }
                }
                continue
            }
            switch kind {
            case .ret, .indirectJump: break
            case .jump:
                if let target = REListing.branchTarget(last, symbols: symbols) { add(node.address, target, .jump) }
            case .conditional:
                if let target = REListing.branchTarget(last, symbols: symbols) { add(node.address, target, .taken) }
                if let next { add(node.address, next, .sequential) }
            case .call, .none:
                if let next { add(node.address, next, .sequential) }
            }
        }
        var graph = ControlFlowGraph(function: function.name, entry: entry, nodes: nodes, edges: edges, size: .zero, source: source)
        layout(&graph)
        return graph
    }

    /// Layered layout: back edges are ignored for ranking, blocks go on the longest-path layer, and each layer is ordered by
    /// the average position of its predecessors so most edges run straight down.
    static func layout(_ graph: inout ControlFlowGraph) {
        let nodes = graph.nodes
        guard !nodes.isEmpty else { return }
        let forward = graph.edges.filter { $0.kind != .back }
        var layer: [UInt64: Int] = [:]
        // Longest path from the entry over forward edges (a DAG once back edges are removed).
        var changed = true; var rounds = 0
        for node in nodes { layer[node.address] = 0 }
        while changed, rounds < nodes.count + 1 {
            changed = false; rounds += 1
            for edge in forward where (layer[edge.to] ?? 0) < (layer[edge.from] ?? 0) + 1 {
                layer[edge.to] = (layer[edge.from] ?? 0) + 1; changed = true
            }
        }
        var layers: [[UInt64]] = []
        for node in nodes {
            let l = layer[node.address] ?? 0
            while layers.count <= l { layers.append([]) }
            layers[l].append(node.address)
        }
        func width(_ node: CFGNode) -> CGFloat {
            let longest = max(node.instructions.map { "\(REListing.hex($0.address))  \($0.text)".count }.max() ?? 8, 18)
            return CGFloat(longest) * characterWidth + 20
        }
        func height(_ node: CFGNode) -> CGFloat { nodeHeaderHeight + CGFloat(node.instructions.count) * nodeLineHeight + 10 }
        let lookup = Dictionary(nodes.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        var position: [UInt64: Int] = [:]
        for (index, address) in (layers.first ?? []).enumerated() { position[address] = index }
        for l in 1..<max(layers.count, 1) {
            let predecessors = Dictionary(grouping: forward.filter { (layer[$0.to] ?? 0) == l }, by: \.to)
            layers[l].sort { a, b in
                func score(_ x: UInt64) -> Double {
                    let ps = predecessors[x]?.compactMap { position[$0.from] } ?? []
                    return ps.isEmpty ? Double(x % 1000) : Double(ps.reduce(0, +)) / Double(ps.count)
                }
                let (sa, sb) = (score(a), score(b))
                return sa == sb ? a < b : sa < sb
            }
            for (index, address) in layers[l].enumerated() { position[address] = index }
        }
        let rowWidths = layers.map { row in row.reduce(CGFloat(0)) { $0 + width(lookup[$1]!) + horizontalGap } - horizontalGap }
        let canvasWidth = max(rowWidths.max() ?? 0, 1)
        var y: CGFloat = 0
        var placed: [UInt64: CGRect] = [:]
        for (l, row) in layers.enumerated() {
            var x = (canvasWidth - rowWidths[l]) / 2
            var rowHeight: CGFloat = 0
            for address in row {
                let node = lookup[address]!
                let frame = CGRect(x: x, y: y, width: width(node), height: height(node))
                placed[address] = frame; x += frame.width + horizontalGap; rowHeight = max(rowHeight, frame.height)
            }
            y += rowHeight + verticalGap
        }
        graph.nodes = nodes.map { node in
            var copy = node; copy.frame = placed[node.address] ?? .zero; copy.layer = layer[node.address] ?? 0; return copy
        }
        graph.size = CGSize(width: canvasWidth, height: max(y - verticalGap, 1))
    }
}

// MARK: Call graph

public struct CallGraphNode: Sendable, Equatable, Identifiable {
    public var id: String { address }
    public let address: String
    public let name: String
    /// Distance from the root: negative for callers, positive for callees, 0 for the root.
    public let depth: Int
    public var frame: CGRect = .zero
}

public struct CallGraphEdge: Sendable, Equatable, Identifiable {
    public var id: String { from + "->" + to }
    public let from: String
    public let to: String
}

public struct CallGraph: Sendable, Equatable {
    public var root: String
    public var nodes: [CallGraphNode]
    public var edges: [CallGraphEdge]
    public var size: CGSize
    public var truncated: Bool

    public enum Direction: String, Sendable { case callers, callees, both }

    public func dot() -> String {
        var out = "digraph callgraph {\n  node [shape=box, fontname=Menlo, fontsize=10];\n"
        for node in nodes { out += "  n\(node.address) [label=\"\(node.name.replacingOccurrences(of: "\"", with: "\\\""))\"\(node.address == root ? ", style=filled, fillcolor=orange" : "")];\n" }
        for edge in edges { out += "  n\(edge.from) -> n\(edge.to);\n" }
        return out + "}\n"
    }

    public func json() -> [String: Any] {
        ["root": root, "truncated": truncated,
         "nodes": nodes.map { ["address": $0.address, "name": $0.name, "depth": $0.depth] },
         "edges": edges.map { ["from": $0.from, "to": $0.to] }]
    }

    /// Neighbourhood of `root` to `depth` levels. `limit` bounds the node count so a hub function cannot flood the view.
    public static func build(analysis: Analysis, root: String, direction: Direction = .both, depth: Int = 2, limit: Int = 120) -> CallGraph? {
        let key = ProjectStore.normalizedAddress(root)
        var byKey: [String: FunctionRecord] = [:]
        for function in analysis.functions { byKey[ProjectStore.normalizedAddress(function.address)] = function }
        guard byKey[key] != nil else { return nil }
        // Callers are recomputed from callees so a project with only one side recorded still draws both.
        var incoming: [String: [String]] = [:]
        for function in analysis.functions {
            let from = ProjectStore.normalizedAddress(function.address)
            for callee in function.callees { incoming[ProjectStore.normalizedAddress(callee), default: []].append(from) }
            for caller in function.callers { incoming[from, default: []].append(ProjectStore.normalizedAddress(caller)) }
        }
        var depths: [String: Int] = [key: 0]
        var edges: [CallGraphEdge] = []
        var seenEdges = Set<String>()
        var truncated = false
        func addEdge(_ from: String, _ to: String) {
            let id = from + "->" + to
            if seenEdges.insert(id).inserted { edges.append(CallGraphEdge(from: from, to: to)) }
        }
        func walk(sign: Int) {
            var frontier = [key]
            for level in 1...max(depth, 1) {
                var next: [String] = []
                for node in frontier {
                    let neighbours: [String] = sign > 0
                        ? Array(NSOrderedSet(array: (byKey[node]?.callees ?? []).map(ProjectStore.normalizedAddress))).compactMap { $0 as? String }
                        : Array(NSOrderedSet(array: incoming[node] ?? [])).compactMap { $0 as? String }
                    for neighbour in neighbours where byKey[neighbour] != nil || sign > 0 {
                        if depths[neighbour] == nil {
                            guard depths.count < limit else { truncated = true; continue }
                            depths[neighbour] = sign * level; next.append(neighbour)
                        }
                        if depths[neighbour] != nil { sign > 0 ? addEdge(node, neighbour) : addEdge(neighbour, node) }
                    }
                }
                frontier = next
                if frontier.isEmpty { break }
            }
        }
        if direction != .callers { walk(sign: 1) }
        if direction != .callees { walk(sign: -1) }
        func name(_ address: String) -> String { byKey[address]?.name ?? "0x" + address }
        var nodes = depths.map { CallGraphNode(address: $0.key, name: name($0.key), depth: $0.value) }
        nodes.sort { ($0.depth, $0.name) < ($1.depth, $1.name) }
        var graph = CallGraph(root: key, nodes: nodes, edges: edges, size: .zero, truncated: truncated)
        graph.layout()
        return graph
    }

    /// Callers on top, the root in the middle, callees below; rows are centred.
    mutating func layout() {
        let rows = Dictionary(grouping: nodes, by: \.depth)
        let ordered = rows.keys.sorted()
        func width(_ node: CallGraphNode) -> CGFloat { CGFloat(max(node.name.count, 8)) * 7.2 + 24 }
        let rowWidths = ordered.map { depth in (rows[depth] ?? []).reduce(CGFloat(0)) { $0 + width($1) + 24 } - 24 }
        let canvas = max(rowWidths.max() ?? 0, 1)
        var placed: [String: CGRect] = [:]
        var y: CGFloat = 0
        for (rowIndex, depth) in ordered.enumerated() {
            var x = (canvas - rowWidths[rowIndex]) / 2
            for node in rows[depth] ?? [] {
                placed[node.address] = CGRect(x: x, y: y, width: width(node), height: 28); x += width(node) + 24
            }
            y += 28 + 44
        }
        nodes = nodes.map { var copy = $0; copy.frame = placed[$0.address] ?? .zero; return copy }
        size = CGSize(width: canvas, height: max(y - 44, 1))
    }

    /// Most called and most calling functions: the first places to look in an unknown binary.
    public static func hubs(analysis: Analysis, limit: Int = 10) -> (fanIn: [(FunctionRecord, Int)], fanOut: [(FunctionRecord, Int)]) {
        var fanIn: [String: Int] = [:]
        for function in analysis.functions { for callee in Set(function.callees.map(ProjectStore.normalizedAddress)) { fanIn[callee, default: 0] += 1 } }
        let ins = analysis.functions.compactMap { f -> (FunctionRecord, Int)? in
            let count = max(fanIn[ProjectStore.normalizedAddress(f.address)] ?? 0, f.callers.count); return count > 0 ? (f, count) : nil
        }.sorted { $0.1 > $1.1 }.prefix(limit)
        let outs = analysis.functions.compactMap { f -> (FunctionRecord, Int)? in
            let count = Set(f.callees).count; return count > 0 ? (f, count) : nil
        }.sorted { $0.1 > $1.1 }.prefix(limit)
        return (Array(ins), Array(outs))
    }
}
