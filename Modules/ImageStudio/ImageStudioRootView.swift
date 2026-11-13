import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageStudioRootView: View {
    @Bindable var module: ImageStudioModule
    @State private var tab: Tab = .create

    enum Tab: String, CaseIterable, Identifiable {
        case create = "Create", models = "Models", history = "History"
        var id: String { rawValue }
        var symbol: String { switch self { case .create: "wand.and.stars"; case .models: "square.and.arrow.down"; case .history: "photo.on.rectangle" } }
    }

    var body: some View {
        VStack(spacing: 0) {
            SSActivityHeader(title: "Images", subtitle: "Generate, edit and upscale pictures; download the models", symbol: "photo.artframe", tabs: {
                SSTabStrip(tabs: Tab.allCases, selection: $tab, title: { $0.rawValue }, symbol: { $0.symbol })
            }, trailing: {
                if let ready = module.reports.first(where: { $0.status.isReady }) {
                    Text(ready.name).font(SSTypography.caption()).foregroundStyle(.secondary)
                        .lineLimit(1).frame(maxWidth: 110).help(ready.name)
                } else {
                    Text("No engine ready").font(SSTypography.caption()).foregroundStyle(.orange)
                }
                Button { Task { await module.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            })
            Group {
                switch tab {
                case .create: CreateView(module: module, showModels: { tab = .models })
                case .models: ModelsView(module: module)
                case .history: HistoryGrid(module: module, open: { module.selected = $0; tab = .create })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, minHeight: 520)
        .task { await module.start(); await module.refresh() }
        .onChange(of: module.openRequests) { _, _ in tab = .create }
    }
}

// MARK: - Create

private struct CreateView: View {
    @Bindable var module: ImageStudioModule
    let showModels: () -> Void

    var body: some View {
        HSplitView {
            Inspector(module: module, showModels: showModels).frame(minWidth: 260, idealWidth: 280, maxWidth: 340)
            CanvasPane(module: module).frame(minWidth: 300)
        }
    }
}

private struct Inspector: View {
    @Bindable var module: ImageStudioModule
    let showModels: () -> Void
    @State private var loraName = ""
    private let sizes: [(String, Int, Int)] = [("1:1", 1, 1), ("4:3", 4, 3), ("3:2", 3, 2), ("16:9", 16, 9), ("3:4", 3, 4), ("2:3", 2, 3), ("9:16", 9, 16)]

    private var caps: ImageEngineCapabilities { module.capabilities ?? .none }
    private var models: [EngineModel] {
        let report = module.draft.engine.flatMap { id in module.reports.first { $0.id == id } } ?? module.reports.first { $0.status.isReady }
        return (report?.models ?? []).filter { $0.kind == .checkpoint }
    }
    private var loras: [EngineModel] {
        (module.reports.first { $0.id == module.draft.engine }?.models ?? []).filter { $0.kind == .lora }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SSSpacing.m) {
                if module.reports.contains(where: { $0.status.isReady && !$0.models.isEmpty }) == false {
                    setupCard
                }
                SSPaneHeader(title: "Prompt") { EmptyView() }
                TextEditor(text: $module.draft.prompt).font(.body).frame(height: 84).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SSColor.hairline))
                    .accessibilityLabel("Image prompt")
                if caps.supports(.negativePrompt) {
                    TextField("Negative prompt", text: $module.draft.negativePrompt, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
                }
                styles
                SSPaneHeader(title: "Model") { EmptyView() }
                Picker("Engine", selection: Binding(get: { module.draft.engine ?? "" }, set: { module.draft.engine = $0.isEmpty ? nil : $0; module.draft.model = "" })) {
                    Text("Automatic").tag("")
                    ForEach(module.reports.filter { $0.status.isReady }, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Model", selection: $module.draft.model) {
                    if module.draft.model.isEmpty { Text("Choose…").tag("") }
                    ForEach(models) { Text($0.name).tag($0.id) }
                }
                .onChange(of: module.draft.model) { _, _ in module.applyModelDefaults() }
                taskPicker
                if module.draft.task != .textToImage { sourceImage }
                SSPaneHeader(title: "Settings") { EmptyView() }
                sizeControls
                Stepper("Steps: \(module.draft.steps)", value: $module.draft.steps, in: 1...150)
                HStack { Text("Guidance \(module.draft.guidance, specifier: "%.1f")"); Slider(value: $module.draft.guidance, in: 0...20) }
                if module.draft.task != .textToImage {
                    HStack { Text("Strength \(module.draft.strength, specifier: "%.2f")"); Slider(value: $module.draft.strength, in: 0.05...1) }
                }
                Stepper("Images: \(module.draft.count)", value: $module.draft.count, in: 1...max(1, caps.maxBatch))
                HStack {
                    TextField("Seed (random)", text: Binding(get: { module.draft.seed.map(String.init) ?? "" }, set: { module.draft.seed = Int64($0) })).textFieldStyle(.roundedBorder)
                    Button { module.draft.seed = Int64.random(in: 0..<Int64(Int32.max)) } label: { Image(systemName: "dice") }.help("New random seed")
                    Button { module.draft.seed = nil } label: { Image(systemName: "xmark.circle") }.help("Random every time")
                }
                if caps.supports(.samplers) {
                    Picker("Sampler", selection: Binding(get: { module.draft.sampler ?? "" }, set: { module.draft.sampler = $0.isEmpty ? nil : $0 })) {
                        Text("Default").tag("")
                        ForEach(caps.samplers) { Text($0.name).tag($0.id) }
                    }
                } else if let why = caps.whyNot(.samplers) { Text(why).font(.caption2).foregroundStyle(.tertiary) }
                loraSection
                Button { Task { _ = await module.enqueue(module.draft) } } label: { Label("Generate", systemImage: "sparkles").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: .command)
                    .disabled(module.draft.prompt.trimmingCharacters(in: .whitespaces).isEmpty || module.draft.model.isEmpty)
                if let message = module.message { Text(message).font(.caption).foregroundStyle(.red) }
                queueList
            }
            .padding(SSSpacing.m)
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: SSSpacing.xs) {
            Text("No image model is ready").font(SSTypography.headline())
            Text("Download SD-Turbo (2.6 GB) in Models to generate on this Mac, or start Draw Things, ComfyUI or Forge.").font(SSTypography.caption()).foregroundStyle(.secondary)
            Button("Open Models", action: showModels).controlSize(.small)
        }
        .padding(SSSpacing.s).frame(maxWidth: .infinity, alignment: .leading)
        .background(SSColor.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var styles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(module.service.prompts.styles()) { style in
                    let on = module.selectedStyles.contains(style.name)
                    Button(style.name) { if on { module.selectedStyles.remove(style.name) } else { module.selectedStyles.insert(style.name) } }
                        .buttonStyle(.bordered).controlSize(.small).tint(on ? SSColor.accent : nil)
                }
            }
        }
    }

    private var taskPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker("Task", selection: $module.draft.task) {
                ForEach(ImageTask.allCases, id: \.self) { task in
                    Text(task.title).tag(task)
                }
            }
            if let why = caps.whyNot(module.draft.task) { Text(why).font(.caption2).foregroundStyle(.orange) }
        }
    }

    private var sourceImage: some View {
        VStack(alignment: .leading, spacing: SSSpacing.xs) {
            HStack {
                Text(module.draft.initImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No source image").font(.caption).lineLimit(1)
                Spacer()
                Button("Choose…") { choose { module.draft.initImagePath = $0.path } }.controlSize(.small)
            }
            if module.draft.task == .inpaint {
                HStack {
                    Text(module.draft.maskPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No mask (white = repaint)").font(.caption).lineLimit(1)
                    Spacer()
                    Button("Mask…") { choose { module.draft.maskPath = $0.path } }.controlSize(.small)
                }
            }
            if module.draft.task == .outpaint {
                let pad = Binding(get: { module.draft.outpaint ?? OutpaintPadding() }, set: { module.draft.outpaint = $0 })
                Stepper("Left \(pad.wrappedValue.left)", value: pad.left, in: 0...512, step: 64)
                Stepper("Right \(pad.wrappedValue.right)", value: pad.right, in: 0...512, step: 64)
                Stepper("Top \(pad.wrappedValue.top)", value: pad.top, in: 0...512, step: 64)
                Stepper("Bottom \(pad.wrappedValue.bottom)", value: pad.bottom, in: 0...512, step: 64)
            }
        }
    }

    private var sizeControls: some View {
        VStack(alignment: .leading, spacing: SSSpacing.xs) {
            HStack {
                ForEach(sizes, id: \.0) { label, w, h in
                    Button(label) {
                        let base = max(512, min(1024, (module.draft.width + module.draft.height) / 2))
                        let long = base * 5 / 4
                        let scale = Double(long) / Double(max(w, h))
                        module.draft.width = Int((Double(w) * scale / 64).rounded()) * 64
                        module.draft.height = Int((Double(h) * scale / 64).rounded()) * 64
                    }.controlSize(.mini).buttonStyle(.bordered)
                }
            }
            Stepper("Width: \(module.draft.width)", value: $module.draft.width, in: caps.minSide...caps.maxSide, step: max(8, caps.sideMultiple))
            Stepper("Height: \(module.draft.height)", value: $module.draft.height, in: caps.minSide...caps.maxSide, step: max(8, caps.sideMultiple))
        }
    }

    private var loraSection: some View {
        VStack(alignment: .leading, spacing: SSSpacing.xs) {
            SSPaneHeader(title: "LoRA", count: module.draft.loras.count) { EmptyView() }
            if let why = caps.whyNot(.lora) {
                Text(why).font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(module.draft.loras.enumerated()), id: \.offset) { index, lora in
                    HStack {
                        Text(lora.name).font(.caption).lineLimit(1)
                        Slider(value: Binding(get: { module.draft.loras[index].weight }, set: { module.draft.loras[index].weight = $0 }), in: -1...2)
                        Text("\(lora.weight, specifier: "%.2f")").font(.caption.monospacedDigit())
                        Button { module.draft.loras.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    if loras.isEmpty { TextField("LoRA name", text: $loraName).textFieldStyle(.roundedBorder) }
                    else { Picker("Add", selection: $loraName) { Text("Add LoRA…").tag(""); ForEach(loras) { Text($0.name).tag($0.id) } } }
                    Button("Add") { if !loraName.isEmpty { module.draft.loras.append(LoRAWeight(name: loraName)); loraName = "" } }.controlSize(.small)
                }
            }
        }
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: SSSpacing.xs) {
            if !module.queue.isEmpty { SSPaneHeader(title: "Queue", count: module.queue.count) { Button("Clear") { module.clearFinishedJobs() }.controlSize(.small).buttonStyle(.borderless) } }
            ForEach(module.queue.suffix(6).reversed()) { job in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(job.request.prompt).font(.caption).lineLimit(1)
                        Spacer()
                        switch job.state {
                        case .queued: Button("Cancel") { module.cancel(job.id) }.controlSize(.mini)
                        case .running: ProgressView().controlSize(.small); Button("Stop") { module.cancel(job.id) }.controlSize(.mini)
                        case .done: Image(systemName: "checkmark.circle").foregroundStyle(.green)
                        case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                        }
                    }
                    if case .running = job.state { ProgressView(value: job.fraction); Text(job.phase).font(.caption2).foregroundStyle(.secondary) }
                    if case .failed(let why) = job.state { Text(why).font(.caption2).foregroundStyle(.red) }
                }
            }
        }
    }

    private func choose(_ apply: (URL) -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { apply(url) }
    }
}

private struct CanvasPane: View {
    @Bindable var module: ImageStudioModule

    var body: some View {
        VStack(spacing: 0) {
            if let item = module.selected ?? module.history.first {
                ZStack {
                    Color.black.opacity(0.04)
                    if let image = NSImage(contentsOf: item.url) { Image(nsImage: image).resizable().scaledToFit().padding(SSSpacing.m) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    module.draft.initImagePath = url.path; if module.draft.task == .textToImage { module.draft.task = .imageToImage }
                    return true
                }
                detail(item)
                Divider()
                strip
            } else {
                SSEmptyState(symbol: "photo.artframe", title: "Nothing generated yet", message: "Write a prompt, pick a model and press ⌘↩. Every picture keeps its settings inside the file so it can be re-run.")
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func detail(_ item: ImageHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: SSSpacing.xs) {
            if let r = item.record {
                Text(r.request.prompt).font(.callout).lineLimit(2)
                Text("\(r.engine) · \(r.modelName) · \(r.request.width)×\(r.request.height) · \(r.request.steps) steps · guidance \(r.request.guidance, specifier: "%.1f") · seed \(r.seed) · \(r.seconds, specifier: "%.1f") s")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            // Labels and icons when they fit, icons alone when they do not: no action hides off the edge (Delete used to).
            ViewThatFits(in: .horizontal) {
                actionRow(item).labelStyle(.titleAndIcon)
                actionRow(item).labelStyle(.iconOnly)
            }
            .controlSize(.small)
        }
        .padding(SSSpacing.s)
    }

    private func actionRow(_ item: ImageHistoryItem) -> some View {
        HStack {
            Button { Task { await module.rerun(item) } } label: { Label("Re-run", systemImage: "arrow.clockwise") }
            Button { module.loadSettings(from: item) } label: { Label("Load settings", systemImage: "slider.horizontal.3") }
            Button { module.useAsReference(item) } label: { Label("Use as reference", systemImage: "photo.badge.arrow.down") }
            Menu { Button("×2") { module.upscale(item, factor: 2) }; Button("×4") { module.upscale(item, factor: 4) } } label: { Label("Upscale", systemImage: "arrow.up.left.and.arrow.down.right") }
                .help("Lanczos resampling: a bigger picture, not an AI-sharpened one")
            Button { module.sendToMedia(item) } label: { Label("Send to Media", systemImage: "play.rectangle") }
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Label("Reveal", systemImage: "magnifyingglass") }
            Button(role: .destructive) { module.delete(item) } label: { Label("Delete", systemImage: "trash") }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var strip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: SSSpacing.xs) {
                ForEach(module.history.prefix(40)) { item in
                    Button { module.selected = item } label: {
                        if let image = NSImage(contentsOf: item.url) {
                            Image(nsImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(module.selected?.id == item.id ? SSColor.accent : .clear, lineWidth: 2))
                        }
                    }.buttonStyle(.plain)
                        .accessibilityLabel(item.record?.request.prompt ?? "Generated image")
                        .accessibilityAddTraits(module.selected?.id == item.id ? .isSelected : [])
                }
            }.padding(SSSpacing.xs)
        }
        .frame(height: 72)
    }
}

// MARK: - History

private struct HistoryGrid: View {
    @Bindable var module: ImageStudioModule
    let open: (ImageHistoryItem) -> Void

    var body: some View {
        if module.history.isEmpty {
            SSEmptyState(symbol: "photo.on.rectangle", title: "No history yet", message: "Pictures you generate are kept under Application Support/Kiln/ImageStudio/History with their settings embedded.")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: SSSpacing.m)], spacing: SSSpacing.m) {
                    ForEach(module.history) { item in
                        Button { open(item) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                if let image = NSImage(contentsOf: item.url) { Image(nsImage: image).resizable().scaledToFill().frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 8)) }
                                Text(item.record?.request.prompt ?? "Untitled").font(.caption).lineLimit(2)
                            }
                        }.buttonStyle(.plain)
                    }
                }.padding(SSSpacing.m)
            }
        }
    }
}

// MARK: - Models

private struct ModelsView: View {
    @Bindable var module: ImageStudioModule
    @State private var source: ImageStudioModule.CatalogSource = .curated
    @State private var query = ""
    @State private var confirming: ImageModelEntry?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                SSPaneHeader(title: "Engines") { EmptyView() }
                ScrollView {
                    VStack(alignment: .leading, spacing: SSSpacing.s) {
                        ForEach(module.reports, id: \.id) { engine in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Circle().fill(engine.status.isReady ? Color.green : Color.orange).frame(width: 8, height: 8); Text(engine.name).font(SSTypography.headline()) }
                                Text(engine.status.summary).font(.caption).foregroundStyle(.secondary)
                                if case .setup(_, let steps) = engine.status { ForEach(steps, id: \.self) { Text("• \($0)").font(.caption2).foregroundStyle(.tertiary) } }
                                if engine.status.isReady {
                                    let off = ImageFeature.allCases.filter { engine.capabilities.whyNot($0) != nil && [.inpaint, .lora, .controlNet].contains($0) }
                                    if !off.isEmpty { Text("Not available here: " + off.map(\.rawValue).joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary) }
                                }
                            }
                        }
                        if !module.downloads.isEmpty {
                            SSPaneHeader(title: "Downloads", count: module.downloads.count) { EmptyView() }
                            ForEach(module.downloads) { job in downloadRow(job) }
                        }
                    }.padding(SSSpacing.s)
                }
            }.frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
            VStack(spacing: 0) {
                HStack {
                    Picker("Source", selection: $source) { ForEach(ImageStudioModule.CatalogSource.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.menu).labelsHidden().frame(maxWidth: 160)
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await module.showCatalog(source, query: query) } }
                    if module.catalogBusy { ProgressView().controlSize(.small) }
                }.padding(SSSpacing.s)
                .onChange(of: source) { _, new in Task { await module.showCatalog(new, query: query) } }
                if let note = module.catalogMessage { Text(note).font(.caption).foregroundStyle(.orange).padding(.horizontal, SSSpacing.s) }
                Divider()
                List(module.catalogRows) { entry in row(entry) }.listStyle(.plain)
            }.frame(minWidth: 320)
        }
        .confirmationDialog("Download \(confirming?.name ?? "")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { entry in
            Button("Download") { Task { await module.download(entry) } }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(entry.termsNotice + (entry.sizeBytes > 0 ? " Size: \(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))." : "")
                 + (entry.isLargeDownload ? " This is a very large download." : ""))
        }
    }

    private func row(_ entry: ImageModelEntry) -> some View {
        let installed = module.installedIDs.contains(entry.id)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.name).font(ThemeRuntime.font(13, .semibold))
                    Text(entry.kind.title).font(.caption2).padding(.horizontal, 4).background(SSColor.surface, in: Capsule())
                    Text(entry.family.title).font(.caption2).foregroundStyle(.secondary)
                    if entry.gating != .open { Image(systemName: "lock").help("Needs a token and accepted terms") }
                    if entry.commercialUse == false { Image(systemName: "dollarsign.circle").foregroundStyle(.orange).help("Non-commercial licence") }
                }
                Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text([entry.sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file) : "size shown at download", entry.license, entry.engines.isEmpty ? "download only" : "for " + entry.engines.joined(separator: ", ")].joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer()
            if installed { Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            else { Button("Download…") { confirming = entry }.controlSize(.small) }
        }
        .padding(.vertical, 2)
    }

    private func downloadRow(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(job.title).font(.caption).lineLimit(1); Spacer()
                if [.queued, .resolving, .downloading, .verifying].contains(job.state) { Button("Stop") { module.cancelDownload(job.id) }.controlSize(.mini) }
            }
            switch job.state {
            case .failed(let why): Text(why).font(.caption2).foregroundStyle(.red)
            case .finished: Text("Done").font(.caption2).foregroundStyle(.green)
            case .cancelled: Text("Stopped. Download again to resume.").font(.caption2).foregroundStyle(.secondary)
            default:
                ProgressView(value: job.fraction)
                Text("\(ByteCountFormatter.string(fromByteCount: job.bytesDone, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: job.bytesTotal, countStyle: .file))\(job.currentFile.map { " · \($0)" } ?? "")")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
