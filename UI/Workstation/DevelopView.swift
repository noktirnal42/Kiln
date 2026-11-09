import SwiftUI

/// Develop: the working tools that used to hide behind chat toolbar sheets, in one place. There is
/// source editor (no language server, debugger or previews yet), terminal, git, workspace search and MCP servers.
struct DevelopView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case editor = "Editor", terminal = "Terminal", git = "Git", search = "Search", mcp = "MCP"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .editor: "chevron.left.forwardslash.chevron.right"
            case .terminal: "terminal"
            case .git: "arrow.triangle.branch"
            case .search: "magnifyingglass"
            case .mcp: "puzzlepiece.extension"
            }
        }
    }

    @Environment(AppModel.self) private var app
    @State private var tool: Tool = .editor
    @State private var terminalModel: TerminalDockModel?
    @State private var gitModel: GitPanelModel?

    var body: some View {
        VStack(spacing: 0) {
            SSActivityHeader(title: "Develop", symbol: "chevron.left.forwardslash.chevron.right", tabs: {
                SSTabStrip(tabs: Tool.allCases, selection: $tool, title: { $0.rawValue }, symbol: { $0.symbol })
            })
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear(perform: prepare)
    }

    @ViewBuilder
    private var content: some View {
        switch tool {
        case .editor:
            EditorView()
        case .terminal:
            if let terminalModel { TerminalDockView(model: terminalModel) }
        case .git:
            if let gitModel {
                GitPanelView(model: gitModel)
                    .task(id: app.chatSession?.workspaceRoot) {
                        if let root = app.chatSession?.workspaceRoot, gitModel.repositoryPath != root {
                            await gitModel.openRepository(at: root, quiet: true)
                        }
                    }
            }
        case .search:
            SearchPanelView(service: app.fileIndexService, projectRoot: app.chatSession?.workspaceRoot)
        case .mcp:
            VStack(spacing: 0) {
                if let listener = app.mcpListener { MCPServerCard(listener: listener) }
                if let remote = app.remoteServer { RemoteControlCard(server: remote) }
                MCPPanelView(service: app.mcpService)
            }
        }
    }

    private func prepare() {
        if terminalModel == nil {
            terminalModel = TerminalDockModel(manager: app.ptyManager,
                                              workspaceRoot: app.chatSession?.workspaceRoot ?? NSHomeDirectory())
        }
        if gitModel == nil { gitModel = GitPanelModel(service: app.gitService) }
    }
}

/// Renders a module's own root view inside an activity, or says plainly why it cannot.
struct ModuleActivityView: View {
    let identifier: String
    @Environment(AppModel.self) private var app

    var body: some View {
        if let ui = app.uiModules[identifier] {
            ui.makeRootView()
        } else if let error = app.bootstrapError {
            ContentUnavailableView("Unavailable", systemImage: "externaldrive.badge.exclamationmark",
                                   description: Text(error))
        } else {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The audit panel as a full activity rather than a sheet.
struct AuditActivityView: View {
    @Environment(AppModel.self) private var app
    @State private var model: AuditPanelModel?

    var body: some View {
        Group {
            if let model {
                AuditPanelView(model: model, embedded: true)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil {
                model = AuditPanelModel(chain: app.auditChain, health: app.auditHealth, settings: app.settings)
            }
        }
    }
}


/// Starts and stops Kiln's own MCP endpoint, so outside agents (Claude Code, Codex, scripts) can use Kiln's tools.
struct MCPServerCard: View {
    let listener: KilnMCPListener

    var body: some View {
        HStack(alignment: .top, spacing: SSSpacing.m) {
            SSStatusDot(color: listener.isRunning ? SSColor.success : .secondary)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kiln as an MCP server").font(SSTypography.headline())
                if listener.isRunning, let port = listener.port {
                    Text("http://127.0.0.1:\(port)/mcp · loopback only · bearer token in Application Support/Kiln/mcp-server.json")
                        .font(SSTypography.caption()).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text("Off. When on, outside agents can list and call Kiln's tools. Reads run freely; writes, commands and network calls wait for your approval here.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                }
                if let error = listener.lastError {
                    Text(error).font(SSTypography.caption()).foregroundStyle(SSColor.danger)
                }
            }
            Spacer()
            Button(listener.isRunning ? "Stop" : "Start") {
                listener.isRunning ? listener.stop() : listener.start()
            }
        }
        .padding(SSSpacing.m)
        .overlay(alignment: .bottom) { Divider() }
    }
}


/// Turns on remote control and shows the code a phone or watch scans to pair.
struct RemoteControlCard: View {
    let server: RemoteServer
    @State private var confirmUnpair = false
    @State private var relayText = ""

    var body: some View {
        HStack(alignment: .top, spacing: SSSpacing.m) {
            SSStatusDot(color: server.isRunning ? SSColor.success : .secondary)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote control").font(SSTypography.headline())
                if server.isRunning {
                    Text("\(server.deviceCount) device\(server.deviceCount == 1 ? "" : "s") connected · local network only · encrypted with the key in this code")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                    if let image = QRCode.image(for: server.pairing.url.absoluteString) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 150, height: 150)
                            .accessibilityLabel("Pairing code for the Kiln Remote app")
                    }
                    if !server.directAddresses.isEmpty {
                        Text("Direct address (same network or Tailscale): " + server.directAddresses.joined(separator: " · "))
                            .font(SSTypography.caption()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(server.relayConnected ? "Internet relay connected: devices can reach this Mac from anywhere."
                         : server.relayURL == nil ? "No internet relay set: devices can only connect on this network or over a VPN."
                         : "Internet relay set but not connected" + (server.relayError.map { " (\($0))" } ?? "") + ".")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                    Text(server.push.status.isEmpty ? "Phone alerts: no phone registered yet. Open Kiln Remote on your iPhone and allow notifications." : "Phone alerts: " + server.push.status)
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                    Toggle("Include the start of the command in phone alerts (it passes through Apple's servers)", isOn: Binding(
                        get: { server.push.includesPreview }, set: { server.push.includesPreview = $0 }))
                        .font(SSTypography.caption())
                    HStack {
                        TextField("Internet relay, e.g. wss://kiln-relay.example.workers.dev", text: $relayText)
                            .textFieldStyle(.roundedBorder).font(SSTypography.caption())
                        Button("Set") { server.setRelay(URL(string: relayText.trimmingCharacters(in: .whitespaces))) }
                        if server.relayURL != nil { Button("Clear") { relayText = ""; server.setRelay(nil) } }
                    }
                    Text("Scan with Kiln Remote on your iPhone. Anyone who sees this code can pair, so do not share your screen with it open.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                    Button("Unpair all devices…") { confirmUnpair = true }
                } else {
                    Text("Off. When on, a paired iPhone or Apple Watch can read this conversation, send messages by voice or text, and allow or deny approvals. It cannot grant standing access.")
                        .font(SSTypography.caption()).foregroundStyle(.secondary)
                }
                if let error = server.lastError {
                    Text(error).font(SSTypography.caption()).foregroundStyle(SSColor.danger)
                }
            }
            Spacer()
            Button(server.isRunning ? "Stop" : "Start") { server.isRunning ? server.stop() : server.start() }
        }
        .padding(SSSpacing.m)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { relayText = server.relayURL?.absoluteString ?? "" }
        .confirmationDialog("Unpair every device?", isPresented: $confirmUnpair) {
            Button("Unpair all", role: .destructive) { server.unpairAll() }
        } message: { Text("A new code is made. Each phone and watch has to scan it again.") }
    }
}
