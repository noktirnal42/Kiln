import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DevicesRootView: View {
    let module: DevicesModule

    var body: some View {
        VStack(spacing: 0) {
            SSActivityHeader(title: "Devices", subtitle: "Apple simulators and Android emulators", symbol: "iphone.gen3", trailing: {
                if module.isRefreshing { ProgressView().controlSize(.small) }
                Button { Task { await module.refresh() } } label: { Label("Refresh the device list", systemImage: "arrow.clockwise") }
                    .help("Refresh the device list")
            })
            HStack(spacing: 0) {
                DeviceListPane(module: module).frame(width: 260)
                Divider()
                DeviceDetailPane(module: module).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await module.refresh() }
        .onAppear { module.startLive() }
        .onDisappear { module.stopLive() }
    }
}

private struct DeviceListPane: View {
    let module: DevicesModule

    var body: some View {
        VStack(spacing: 0) {
            SSPaneHeader("Simulators and emulators", count: module.devices.filter { $0.isAvailable || $0.platform == .android }.count)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    if let setup = module.setup { SetupBanner(setup: setup) }
                    ForEach(module.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12) }
                    section("Apple simulators", module.devices.filter { $0.platform == .apple && $0.isAvailable })
                    section("Android", module.devices.filter { $0.platform == .android })
                    if module.devices.isEmpty && !module.isRefreshing && module.setup != nil {
                        Text("No devices found yet.").font(.callout).foregroundStyle(.secondary).padding(12)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ devices: [DeviceInfo]) -> some View {
        if !devices.isEmpty {
            SSSectionLabel(title).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
            ForEach(devices) { device in row(device) }
        }
    }

    private func row(_ device: DeviceInfo) -> some View {
        let isSelected = module.selectedID == device.id
        let busy = module.busyIDs.contains(device.id)
        return HStack(spacing: 8) {
            Button {
                module.selectedID = device.id
                Task { await module.captureFrame() }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(color(device.state)).frame(width: 8, height: 8)
                    Image(systemName: device.symbol).frame(width: 18).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.system(size: 13, weight: isSelected ? .semibold : .regular)).lineLimit(1)
                        Text("\(device.runtime) · \(device.state.rawValue)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(device.name), \(device.runtime), \(device.state.rawValue)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if busy { ProgressView().controlSize(.small) }
            else if device.canBoot {
                Button { Task { await module.boot(device) } } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless).help("Boot \(device.name)").accessibilityLabel("Boot \(device.name), \(device.runtime)")
            } else if device.canShutdown {
                Button { Task { await module.shutdown(device) } } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.borderless).help("Shut down \(device.name)").accessibilityLabel("Shut down \(device.name), \(device.runtime)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private func color(_ state: DeviceInfo.State) -> Color {
        switch state {
        case .booted: .green
        case .booting, .shuttingDown: .orange
        case .unauthorized, .offline: .red
        default: .secondary.opacity(0.5)
        }
    }
}

/// Shown when a platform's tools are missing: what is missing and exactly how to get it. Nothing is downloaded.
private struct SetupBanner: View {
    let setup: DeviceSetup

    var body: some View {
        let missing = [setup.simctl, setup.adb, setup.emulator].filter { !$0.isAvailable }
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Setup needed", systemImage: "wrench.and.screwdriver").font(.caption.weight(.semibold))
                ForEach(missing, id: \.name) { tool in
                    Text("**\(tool.name)** not found. \(tool.detail)").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8).padding(.top, 6)
        }
    }
}

private struct DeviceDetailPane: View {
    let module: DevicesModule
    @State private var urlText = ""
    @State private var appID = ""
    @State private var typeText = ""
    @State private var showInstaller = false
    @State private var showLogs = false
    @State private var logText = ""
    @State private var recordSeconds = 10
    @State private var dragStart: CGPoint?

    var body: some View {
        if let device = module.selected {
            VStack(spacing: 0) {
                header(device)
                Divider()
                content(device)
                Divider()
                controls(device)
            }
            .fileImporter(isPresented: $showInstaller, allowedContentTypes: [.applicationBundle, .data]) { result in
                if case .success(let url) = result { Task { await module.install(device, path: url.path) } }
            }
            .sheet(isPresented: $showLogs) { logsSheet }
        } else {
            SSEmptyState(symbol: "iphone.gen3", title: "Select a device",
                         message: "Boot a simulator or emulator, or pick a running one, to see its screen here. The agent uses the same devices through device_* tools.")
        }
    }

    private func header(_ device: DeviceInfo) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(device.name).font(.headline)
                Text("\(device.runtime) · \(device.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if let message = module.message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 320, alignment: .trailing) }
        }
        .padding(12)
    }

    @ViewBuilder
    private func content(_ device: DeviceInfo) -> some View {
        if device.state == .booted {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image = module.frame {
                    GeometryReader { geo in
                        let fit = fitted(module.frameSize, in: geo.size)
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: fit.width, height: fit.height)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(radius: 6, y: 2)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                            .gesture(device.platform == .android ? inputGesture(device, fit: fit) : nil)
                            .help(device.platform == .android ? "Click to tap, drag to swipe" : "Touch forwarding is not available for Apple simulators (simctl has no input commands)")
                    }
                    .padding(16)
                } else if let error = module.frameError {
                    Text(error).font(.callout).foregroundStyle(.secondary).padding()
                } else {
                    ProgressView("Capturing screen…")
                }
            }
        } else {
            ContentUnavailableView {
                Label(device.state == .shutdown ? "Not running" : device.state.rawValue.capitalized, systemImage: "power")
            } description: {
                Text(device.detail ?? (device.canBoot ? "Boot this device to see its screen." : "This device is not available."))
            } actions: {
                if device.canBoot { Button("Boot") { Task { await module.boot(device) } }.buttonStyle(.borderedProminent) }
            }
        }
    }

    private func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(box.width / size.width, box.height / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Maps a point in the displayed image to device pixels (the screenshot's own pixel grid).
    private func inputGesture(_ device: DeviceInfo, fit: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard fit.width > 0 else { return }
                let scale = module.frameSize.width / fit.width
                func pixel(_ p: CGPoint) -> (Int, Int) { (max(0, Int(p.x * scale)), max(0, Int(p.y * scale))) }
                let start = pixel(value.startLocation), end = pixel(value.location)
                let moved = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                Task {
                    if moved < 6 { await module.send(device, input: .tap(x: start.0, y: start.1)) }
                    else { await module.send(device, input: .swipe(x1: start.0, y1: start.1, x2: end.0, y2: end.1, durationMs: 300)) }
                }
            }
    }

    private func controls(_ device: DeviceInfo) -> some View {
        let booted = device.state == .booted
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
              HStack {
                Toggle("Live", isOn: Binding(get: { module.liveRefresh }, set: { module.liveRefresh = $0 })).toggleStyle(.switch).controlSize(.small)
                Button("Screenshot") {
                    Task { if let url = await module.saveScreenshot(device) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                }.disabled(!booted)
                Menu("Record") {
                    ForEach([5, 10, 30], id: \.self) { s in
                        Button("\(s) seconds") { Task { if let url = await module.record(device, seconds: s) { NSWorkspace.shared.activateFileViewerSelecting([url]) } } }
                    }
                }.disabled(!booted).fixedSize()
                Button("Install…") { showInstaller = true }.disabled(!booted)
                Button("Logs") { Task { logText = await module.logs(device); showLogs = true } }.disabled(!booted)
                Spacer()
                if device.platform == .android && booted {
                    Button { Task { await module.send(device, input: .key("KEYCODE_BACK")) } } label: { Image(systemName: "chevron.backward") }.help("Back")
                    Button { Task { await module.send(device, input: .key("KEYCODE_HOME")) } } label: { Image(systemName: "circle") }.help("Home")
                    Button { Task { await module.send(device, input: .key("KEYCODE_APP_SWITCH")) } } label: { Image(systemName: "square") }.help("Recent apps")
                }
              }.fixedSize(horizontal: true, vertical: false)
            }
            HStack {
                TextField(device.platform == .apple ? "Bundle id, e.g. com.apple.mobilesafari" : "Package name, e.g. com.android.chrome", text: $appID)
                    .textFieldStyle(.roundedBorder)
                Button("Launch") { Task { await module.launch(device, app: appID) } }.disabled(!booted || appID.isEmpty)
            }
            HStack {
                TextField("URL to open, e.g. https://example.com", text: $urlText).textFieldStyle(.roundedBorder)
                Button("Open") { Task { await module.openURL(device, url: urlText) } }.disabled(!booted || urlText.isEmpty)
            }
            if device.platform == .android && booted {
                HStack {
                    TextField("Type into the focused field", text: $typeText).textFieldStyle(.roundedBorder)
                        .onSubmit { sendText(device) }
                    Button("Type") { sendText(device) }.disabled(typeText.isEmpty)
                }
            } else if booted {
                Text("Touch and keyboard forwarding is Android-only for now: simctl has no input commands.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func sendText(_ device: DeviceInfo) {
        let text = typeText
        typeText = ""
        Task { await module.send(device, input: .text(text)) }
    }

    private var logsSheet: some View {
        VStack(alignment: .leading) {
            HStack { Text("Device log").font(.headline); Spacer(); Button("Done") { showLogs = false }.keyboardShortcut(.cancelAction) }
            ScrollView { Text(logText.isEmpty ? "No log lines." : logText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding().frame(minWidth: 640, minHeight: 420)
    }
}
