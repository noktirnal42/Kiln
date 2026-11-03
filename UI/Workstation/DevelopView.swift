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
            HStack {
                Picker("Tool", selection: $tool) {
                    ForEach(Tool.allCases) { tool in
                        Label(tool.rawValue, systemImage: tool.symbol).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                Spacer()
            }
            .padding(SSSpacing.s)
            Divider()
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
