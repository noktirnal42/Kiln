import SwiftUI
import SwiftTerm

/// NSViewRepresentable binding a SwiftTerm TerminalView to a live PTYSession.
struct SwiftTermContainer: NSViewRepresentable {
    let session: PTYSession
    let onInput: (Data) -> Void

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = NSColor.textBackgroundColor
        view.nativeForegroundColor = NSColor.textColor
        let weakView = WeakTerminalHolder(base: view)
        session.onData { data in
            DispatchQueue.main.async {
                weakView.base?.feed(byteArray: ArraySlice([UInt8](data)))
            }
        }
        context.coordinator.session = session
        context.coordinator.onInput = onInput
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.onInput = onInput
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, TerminalViewDelegate {
        weak var session: PTYSession?
        var onInput: (Data) -> Void = { _ in }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onInput(Data(data))
        }

        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard let session else { return }
            let rows = UInt16(newRows)
            let cols = UInt16(newCols)
            Task { try? session.resize(rows: rows, columns: cols) }
        }
        func setTerminalIconTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
        func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { nil }
        func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { nil }
        func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .unsupported }
        func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

final class WeakTerminalHolder: @unchecked Sendable {
    weak var base: TerminalView?
    init(base: TerminalView?) { self.base = base }
}

@MainActor
@Observable
public final class TerminalDockModel {
    public private(set) var sessions: [TerminalSessionInfo] = []
    public var activeSessionID: UUID? {
        didSet {
            if let activeSessionID, let info = sessions.first(where: { $0.id == activeSessionID }) {
                activePTY = sessionCache[info.id]
            } else if activeSessionID == nil {
                activePTY = nil
            }
        }
    }
    public private(set) var workspaceRoot: String
    public private(set) var activePTY: PTYSession?

    private let manager: PTYManager
    private var sessionCache: [UUID: PTYSession] = [:]

    public init(manager: PTYManager, workspaceRoot: String) {
        self.manager = manager
        self.workspaceRoot = workspaceRoot
    }

    public func setWorkspaceRoot(_ root: String) {
        workspaceRoot = root
    }

    public func refresh() async {
        sessions = await manager.allSessions()
        for info in sessions {
            if sessionCache[info.id] == nil {
                sessionCache[info.id] = await manager.session(info.id)
            }
        }
        if activeSessionID == nil || !sessions.contains(where: { $0.id == activeSessionID }) {
            activeSessionID = sessions.first?.id
            activePTY = activeSessionID.flatMap { sessionCache[$0] }
        }
    }

    public func createSession() async {
        _ = try? await manager.createSession(workspaceRoot: workspaceRoot)
        await refresh()
    }

    public func closeSession(_ id: UUID) async {
        await manager.closeSession(id)
        sessionCache[id] = nil
        await refresh()
    }

    public var activeSession: PTYSession? {
        activePTY
    }

    public func history() async -> [CommandHistoryEntry] {
        await manager.history(workspaceRoot: workspaceRoot)
    }

    public func recordInput(_ line: String) async {
        await manager.recordInput(line, workspaceRoot: workspaceRoot)
    }
}

struct TerminalDockView: View {
    let model: TerminalDockModel
    @State private var showHistory = false
    @State private var history: [CommandHistoryEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SSSpacing.xs) {
                ForEach(model.sessions) { info in
                    HStack(spacing: SSSpacing.xs) {
                        Button {
                            model.activeSessionID = info.id
                        } label: {
                            Text(info.title)
                                .font(SSTypography.caption())
                                .padding(.horizontal, SSSpacing.s)
                                .padding(.vertical, 3)
                                .background(model.activeSessionID == info.id ? Color.accentColor.opacity(0.2) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: SSCornerRadius.small))
                        }
                        .buttonStyle(.plain)
                        Button {
                            Task { await model.closeSession(info.id) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(SSTypography.caption())
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    Task { await model.createSession() }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New terminal tab")
                Spacer()
                Button {
                    Task {
                        history = await model.history()
                        showHistory = true
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Command history for this workspace")
            }
            .padding(.horizontal, SSSpacing.m)
            .padding(.vertical, SSSpacing.xs)
            Divider()
            if let session = model.activeSession {
                SwiftTermContainer(session: session) { data in
                    session.write(data)
                    if let text = String(data: data, encoding: .utf8), text.contains("\n") {
                        Task {
                            for line in text.split(separator: "\n") {
                                await model.recordInput(String(line))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Terminal Sessions", systemImage: "terminal")
                } description: {
                    Text("Create a tab to open a shell in \(model.workspaceRoot)")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showHistory) {
            VStack(spacing: 0) {
                HStack {
                    Text("Command History").font(SSTypography.title())
                    Spacer()
                    Button("Done") { showHistory = false }.keyboardShortcut(.defaultAction)
                }
                .padding(SSSpacing.m)
                Divider()
                List(history.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.line).font(SSTypography.mono(12))
                        Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                            .font(SSTypography.caption())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 420)
        }
    }
}
