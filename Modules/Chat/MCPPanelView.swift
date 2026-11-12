import SwiftUI

struct MCPPanelView: View {
    let service: MCPClientService
    @State private var statuses: [MCPServerStatus] = []
    @State private var tools: [MCPTool] = []
    @State private var resources: [MCPResource] = []
    @State private var prompts: [MCPPrompt] = []
    @State private var toolResult: String?
    @State private var toolError: String?
    @State private var callTarget: MCPTool?
    @State private var argumentsJSON = "{}"

    var body: some View {
        VStack(spacing: 0) {
            SSPaneHeader(title: "MCP servers") {
                Button("Rescan") { Task { await loadAll() } }
                if hiddenCount > 0 {
                    Button("Show \(hiddenCount) hidden") { Task { await service.unhideAllServers(); await loadAll() } }
                }
            }
            HSplitView {
                serverList
                    .frame(minWidth: 260, idealWidth: 340)
                toolPalette
                    .frame(minWidth: 260)
            }
        }
        .frame(minHeight: 320)
        .task { await loadAll() }
    }

    private var serverList: some View {
        VStack(spacing: 0) {
            List(statuses) { status in
                VStack(alignment: .leading, spacing: SSSpacing.xs) {
                    HStack(spacing: SSSpacing.xs) {
                        Image(systemName: status.connected ? "circle.fill" : status.approved ? "circle.dashed" : "lock.fill")
                            .foregroundStyle(status.connected ? SSColor.success : status.approved ? SSColor.warning : .secondary)
                            .font(SSTypography.caption())
                        Text(status.config.id).font(SSTypography.body())
                        Spacer()
                        Text(status.config.transport.displayName)
                            .font(SSTypography.caption())
                            .foregroundStyle(.secondary)
                    }
                    Text(status.config.command)
                        .font(SSTypography.mono(11))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    if !status.sources.isEmpty {
                        Text("From " + status.sources.joined(separator: " · "))
                            .font(SSTypography.caption())
                            .foregroundStyle(.tertiary)
                    }
                    if let error = status.lastError {
                        Text(error)
                            .font(SSTypography.caption())
                            .foregroundStyle(SSColor.danger)
                            .lineLimit(2)
                    }
                    HStack(spacing: SSSpacing.s) {
                        if !status.approved {
                            Button("Approve & Connect") {
                                Task {
                                    await service.approve(status.config)
                                    try? await service.connect(status.config.id)
                                    await loadAll()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("Deny") {
                                Task {
                                    await service.revokeApproval(serverID: status.config.id)
                                    await loadAll()
                                }
                            }
                            .controlSize(.small)
                        } else if !status.connected {
                            Button("Connect") {
                                Task {
                                    do {
                                        try await service.connect(status.config.id)
                                    } catch {
                                        // surfaced through loadAll error map
                                    }
                                    await loadAll()
                                }
                            }
                            .controlSize(.small)
                        } else {
                            Button("Disconnect") {
                                Task {
                                    await service.disconnect(status.config.id)
                                    await loadAll()
                                }
                            }
                            .controlSize(.small)
                        }
                        if !status.sources.isEmpty {
                            Button("Hide") {
                                Task {
                                    await service.disconnect(status.config.id)
                                    await service.hideServer(status.config.id)
                                    await loadAll()
                                }
                            }
                            .controlSize(.small)
                            .help("Stop listing this imported server. Show hidden servers again with Rescan → Show hidden.")
                        }
                        Button("Revoke Approval") {
                            Task {
                                await service.revokeApproval(serverID: status.config.id)
                                await service.disconnect(status.config.id)
                                await loadAll()
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .overlay {
                if statuses.isEmpty {
                    SSEmptyState(symbol: "puzzlepiece.extension", title: "No MCP servers yet",
                                 message: "Servers you add to Kiln's MCP configuration appear here, each approved before it connects.")
                        .padding(SSSpacing.m)
                }
            }
        }
    }

    private var toolPalette: some View {
        VStack(spacing: 0) {
            Picker("Registry", selection: Binding(
                get: { registryTab },
                set: { registryTab = $0 }
            )) {
                Text("Tools (\(tools.count))").tag("tools")
                Text("Resources (\(resources.count))").tag("resources")
                Text("Prompts (\(prompts.count))").tag("prompts")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(SSSpacing.m)
            Divider()
            if registryTab == "tools" {
                List(tools) { tool in
                    Button {
                        callTarget = tool
                        argumentsJSON = "{}"
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name).font(SSTypography.mono(12))
                            if !tool.description.isEmpty {
                                Text(tool.description).font(SSTypography.caption()).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text(tool.serverID).font(SSTypography.caption()).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else if registryTab == "resources" {
                List(resources) { resource in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(resource.name).font(SSTypography.body())
                        Text(resource.uri).font(SSTypography.mono(11)).foregroundStyle(.secondary)
                    }
                }
            } else {
                List(prompts) { prompt in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prompt.name).font(SSTypography.body())
                        if !prompt.description.isEmpty {
                            Text(prompt.description).font(SSTypography.caption()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let callTarget {
                Divider()
                VStack(alignment: .leading, spacing: SSSpacing.s) {
                    HStack {
                        Text("Call \(callTarget.serverID):\(callTarget.name)").font(SSTypography.headline())
                        Spacer()
                        Button("Run") { runTool() }
                    }
                    TextEditor(text: $argumentsJSON)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: SSCornerRadius.small).stroke(Color(nsColor: .separatorColor)))
                    if let toolError {
                        Text(toolError).font(SSTypography.caption()).foregroundStyle(SSColor.danger)
                    }
                    if let toolResult {
                        ScrollView {
                            Text(toolResult).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                    }
                }
                .padding(SSSpacing.m)
            }
        }
    }

    @State private var registryTab = "tools"
    private var hiddenCount: Int { UserDefaults.standard.stringArray(forKey: "mcp.hiddenServers")?.count ?? 0 }

    private func loadAll() async {
        await service.discoverServers()
        statuses = await service.statuses()
        tools = await service.allTools()
        resources = await service.allResources()
        prompts = await service.allPrompts()
    }

    private func runTool() {
        guard let callTarget else { return }
        let arguments: [String: ProviderJSON]
        do {
            let decoded = try JSONDecoder().decode(ProviderJSON.self, from: Data(argumentsJSON.utf8))
            guard case .object(let object) = decoded.value else {
                toolError = "Arguments must be a JSON object"
                return
            }
            arguments = object
        } catch {
            toolError = "Invalid JSON: \(error.localizedDescription)"
            return
        }
        Task {
            do {
                let result = try await service.callTool(qualifiedName: callTarget.id, arguments: arguments)
                toolResult = result.text
                toolError = result.isError ? "Tool reported an error" : nil
            } catch {
                toolError = String(describing: error)
                toolResult = nil
            }
        }
    }
}
