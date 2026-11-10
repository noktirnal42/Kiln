import SwiftUI
import AxiomCore

/// Graph tab: control-flow graph of the selected function (with minimap and zoom) or the call graph around it.
struct REGraphView: View {
    let module: REModule
    let projectID: String
    let function: FunctionRecord?
    let onSelectFunction: (String) -> Void
    @State private var mode = 0
    @State private var cfg: ControlFlowGraph?
    @State private var calls: CallGraph?
    @State private var depth = 2
    @State private var zoom = 1.0
    @State private var error: String?
    @State private var selectedBlock: UInt64?
    @State private var scroll = ScrollPosition(x: 0, y: 0)

    var body: some View {
        VStack(spacing: 0) {
            SSPaneHeader(title: function.map { "Graph · \($0.name)" } ?? "Graph") {
                Picker("", selection: $mode) { Text("Control flow").tag(0); Text("Call graph").tag(1) }
                    .pickerStyle(.segmented).frame(width: 220).labelsHidden()
                if mode == 1 { Stepper("Depth \(depth)", value: $depth, in: 1...5).controlSize(.small).labelsHidden().help("Call depth \(depth)") }
                Slider(value: $zoom, in: 0.4...2).frame(width: 90).controlSize(.small).help("Zoom")
                Button { exportDOT() } label: { Label("Export DOT", systemImage: "square.and.arrow.up") }.help("Export Graphviz DOT")
            }
            if function == nil {
                SSEmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "No function selected", message: "Pick a function in the Functions tab to see its graph.")
            } else if let error {
                SSEmptyState(symbol: "exclamationmark.triangle", title: "No graph", message: error)
            } else if mode == 0, let cfg {
                if cfg.nodes.isEmpty { SSEmptyState(symbol: "square.dashed", title: "No instructions", message: "This function has no listing, so no blocks can be drawn.") }
                else { cfgCanvas(cfg) }
            } else if mode == 1, let calls {
                callCanvas(calls)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: "\(function?.address ?? "")|\(mode)|\(depth)") { await load() }
    }

    private func load() async {
        guard let function else { return }
        error = nil
        do {
            if mode == 0 { cfg = try await module.controlFlowGraph(projectID: projectID, function: function.address) }
            else { calls = try await module.callGraph(projectID: projectID, function: function.address, depth: depth) }
        } catch { self.error = error.localizedDescription }
    }

    private func exportDOT() {
        let text = mode == 0 ? cfg?.dot() : calls?.dot()
        guard let text else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = (function?.name ?? "graph") + ".dot"
        if panel.runModal() == .OK, let url = panel.url { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }

    // MARK: Control flow

    private func cfgCanvas(_ graph: ControlFlowGraph) -> some View {
        let pad: CGFloat = 24
        return ZStack(alignment: .bottomTrailing) {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        let frames = Dictionary(graph.nodes.map { ($0.address, $0.frame) }, uniquingKeysWith: { a, _ in a })
                        for edge in graph.edges {
                            guard let a = frames[edge.from], let b = frames[edge.to] else { continue }
                            var path = Path()
                            let start = CGPoint(x: a.midX + pad, y: a.maxY + pad), end = CGPoint(x: b.midX + pad, y: b.minY + pad)
                            path.move(to: start)
                            if end.y > start.y { path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + 30), control2: CGPoint(x: end.x, y: end.y - 30)) }
                            else { // back edge: route around the right side
                                let side = max(a.maxX, b.maxX) + pad + 30
                                path.addCurve(to: end, control1: CGPoint(x: side, y: start.y + 20), control2: CGPoint(x: side, y: end.y - 20))
                            }
                            let color: Color = edge.kind == .taken ? SSColor.success : edge.kind == .sequential ? SSColor.danger : edge.kind == .back ? SSColor.accent : .secondary
                            context.stroke(path, with: .color(color), lineWidth: 1.4)
                            context.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)), with: .color(color))
                        }
                    }
                    .frame(width: graph.size.width + pad * 2 + 60, height: graph.size.height + pad * 2)
                    ForEach(graph.nodes) { node in
                        blockView(node, isEntry: node.address == graph.entry)
                            .frame(width: node.frame.width, height: node.frame.height, alignment: .topLeading)
                            .offset(x: node.frame.minX + pad, y: node.frame.minY + pad)
                    }
                }
                .frame(width: (graph.size.width + pad * 2 + 60) * zoom, height: (graph.size.height + pad * 2) * zoom, alignment: .topLeading)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: (graph.size.width + pad * 2 + 60) * zoom, height: (graph.size.height + pad * 2) * zoom, alignment: .topLeading)
            }
            .scrollPosition($scroll)
            .background(SSColor.canvas)
            minimap(graph, pad: pad).padding(SSSpacing.s)
            VStack { Spacer(); HStack { Text("\(graph.nodes.count) blocks · \(graph.edges.count) edges · complexity \(graph.complexity) · \(graph.source)")
                .font(SSTypography.caption()).foregroundStyle(.secondary).padding(6).background(.ultraThinMaterial, in: Capsule()); Spacer() } }.padding(SSSpacing.s)
        }
    }

    private func blockView(_ node: CFGNode, isEntry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("0x" + REListing.hex(node.address)).font(SSTypography.mono(10).weight(.semibold))
                if isEntry { SSBadge(text: "entry") }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: CFGBuilder.nodeHeaderHeight)
            .background(SSColor.accent.opacity(0.18))
            ForEach(node.instructions) { instruction in
                Text("\(REListing.hex(instruction.address))  \(instruction.text)")
                    .font(SSTypography.mono(10)).lineLimit(1)
                    .frame(height: CFGBuilder.nodeLineHeight, alignment: .leading).padding(.horizontal, 8)
            }
        }
        .background(SSColor.surface)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selectedBlock == node.address ? SSColor.accent : SSColor.hairline, lineWidth: selectedBlock == node.address ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture { selectedBlock = node.address }
        .contextMenu {
            ForEach(Array(Set(node.calls)).sorted(), id: \.self) { name in Button("Go to \(name)") { onSelectFunction(name) } }
        }
    }

    private func minimap(_ graph: ControlFlowGraph, pad: CGFloat) -> some View {
        let box = CGSize(width: 150, height: 110)
        let scale = min(box.width / max(graph.size.width + 60, 1), box.height / max(graph.size.height, 1))
        return Canvas { context, _ in
            for edge in graph.edges {
                guard let a = graph.nodes.first(where: { $0.address == edge.from }), let b = graph.nodes.first(where: { $0.address == edge.to }) else { continue }
                var p = Path(); p.move(to: CGPoint(x: a.frame.midX * scale, y: a.frame.maxY * scale)); p.addLine(to: CGPoint(x: b.frame.midX * scale, y: b.frame.minY * scale))
                context.stroke(p, with: .color(.secondary.opacity(0.6)), lineWidth: 0.7)
            }
            for node in graph.nodes {
                let r = CGRect(x: node.frame.minX * scale, y: node.frame.minY * scale, width: max(node.frame.width * scale, 2), height: max(node.frame.height * scale, 2))
                context.fill(Path(r), with: .color(node.address == selectedBlock ? SSColor.accent : SSColor.accent.opacity(0.55)))
            }
        }
        .frame(width: box.width, height: box.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(SSColor.hairline))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            scroll.scrollTo(x: max(0, (value.location.x / scale - 120) * zoom), y: max(0, (value.location.y / scale - 80) * zoom))
        })
        .help("Minimap: click or drag to move")
    }

    // MARK: Call graph

    private func callCanvas(_ graph: CallGraph) -> some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let frames = Dictionary(graph.nodes.map { ($0.address, $0.frame) }, uniquingKeysWith: { a, _ in a })
                    for edge in graph.edges {
                        guard let a = frames[edge.from], let b = frames[edge.to] else { continue }
                        var p = Path(); p.move(to: CGPoint(x: a.midX + 20, y: a.maxY + 20))
                        p.addCurve(to: CGPoint(x: b.midX + 20, y: b.minY + 20), control1: CGPoint(x: a.midX + 20, y: a.maxY + 40), control2: CGPoint(x: b.midX + 20, y: b.minY))
                        context.stroke(p, with: .color(.secondary), lineWidth: 1.2)
                    }
                }.frame(width: graph.size.width + 40, height: graph.size.height + 40)
                ForEach(graph.nodes) { node in
                    Button { onSelectFunction(node.address) } label: {
                        Text(node.name).font(SSTypography.mono(11)).lineLimit(1).padding(.horizontal, 10)
                            .frame(width: node.frame.width, height: node.frame.height)
                            .background(node.address == graph.root ? SSColor.accent.opacity(0.3) : SSColor.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(node.address == graph.root ? SSColor.accent : SSColor.hairline))
                    }.buttonStyle(.plain).offset(x: node.frame.minX + 20, y: node.frame.minY + 20)
                        .help(node.depth < 0 ? "Caller" : node.depth > 0 ? "Callee" : "Selected")
                }
            }
            .frame(width: (graph.size.width + 40) * zoom, height: (graph.size.height + 40) * zoom, alignment: .topLeading)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: (graph.size.width + 40) * zoom, height: (graph.size.height + 40) * zoom, alignment: .topLeading)
        }
        .background(SSColor.canvas)
        .overlay(alignment: .bottomLeading) {
            Text("\(graph.nodes.count) functions · callers above, callees below" + (graph.truncated ? " · truncated" : ""))
                .font(SSTypography.caption()).foregroundStyle(.secondary).padding(6).background(.ultraThinMaterial, in: Capsule()).padding(SSSpacing.s)
        }
    }
}
