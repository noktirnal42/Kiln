import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct MediaRootView: View {
    @Bindable var module: MediaModule
    @State private var section: Section = .viewer

    enum Section: String, CaseIterable, Identifiable {
        case viewer = "Viewer", gallery = "Gallery", image = "Image", voice = "Voice"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Media", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if let busy = module.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(SSTypography.caption()).foregroundStyle(.secondary)
                }
                Button { openPanel() } label: { Label("Open…", systemImage: "folder") }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            .padding(SSSpacing.s)
            Divider()
            Group {
                switch section {
                case .viewer: ViewerPane(module: module)
                case .gallery: GalleryPane(module: module, showViewer: { section = .viewer })
                case .image: ImagePane(module: module, showViewer: { section = .viewer })
                case .voice: VoicePane(module: module, showViewer: { section = .viewer })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onChange(of: module.openRequests) { _, _ in section = .viewer }
        .onAppear { module.reloadGallery(); Task { await module.refreshProviders() } }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image, .audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try module.open(url); section = .viewer } catch { module.setMessage(error.localizedDescription) }
    }
}

private struct ViewerPane: View {
    @Bindable var module: MediaModule

    var body: some View {
        VStack(spacing: 0) {
            if let target = module.current {
                HStack {
                    Image(systemName: target.kind.symbol)
                    Text(target.title).lineLimit(1).font(SSTypography.headline())
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([target.url]) } label: { Label("Reveal", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, SSSpacing.m).padding(.vertical, SSSpacing.xs)
                Divider()
                MediaViewer(target: target).id(target.url)
            } else {
                ContentUnavailableView {
                    Label("Nothing open", systemImage: "play.rectangle")
                } description: {
                    Text(module.message ?? "Open a video, image or audio file, or pick something from the Gallery. The agent can open files here with media_open.")
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            do { try module.open(url); return true } catch { module.setMessage(error.localizedDescription); return false }
        }
    }
}

private struct GalleryPane: View {
    @Bindable var module: MediaModule
    let showViewer: () -> Void

    var body: some View {
        if module.items.isEmpty {
            ContentUnavailableView("Nothing generated yet", systemImage: "photo.on.rectangle.angled",
                                   description: Text("Images and spoken audio you or the agent generate are kept here, under Application Support/Kiln/Media."))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: SSSpacing.m)], spacing: SSSpacing.m) {
                    ForEach(module.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                                if item.kind == .image, let image = NSImage(contentsOf: module.gallery.fileURL(for: item)) {
                                    Image(nsImage: image).resizable().scaledToFill()
                                } else {
                                    Image(systemName: item.kind.symbol).font(.largeTitle).foregroundStyle(.secondary)
                                }
                            }
                            .frame(height: 130).clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(item.title).font(SSTypography.caption()).lineLimit(2)
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { module.openItem(item); showViewer() }
                        .contextMenu {
                            Button("Open") { module.openItem(item); showViewer() }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([module.gallery.fileURL(for: item)]) }
                            Button("Delete", role: .destructive) { module.deleteItem(item) }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(item.kind.title): \(item.title)")
                    }
                }
                .padding(SSSpacing.m)
            }
        }
    }
}

private struct ImagePane: View {
    @Bindable var module: MediaModule
    let showViewer: () -> Void
    @State private var prompt = ""
    @State private var model = UserDefaults.standard.string(forKey: MediaModule.imageModelKey) ?? ""
    @State private var error: String?

    var body: some View {
        Form {
            Section("Providers") {
                if module.providerStatuses.isEmpty { Text("Checking…").foregroundStyle(.secondary) }
                ForEach(module.providerStatuses, id: \.id) { status in
                    HStack(alignment: .top) {
                        Image(systemName: status.availability == .available ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(status.availability == .available ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(status.name)
                            if case .unavailable(let why) = status.availability {
                                Text(why).font(SSTypography.caption()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                TextField("Custom endpoint image model", text: $model, prompt: Text("e.g. an OpenAI-compatible image model name"))
                    .onSubmit { save() }
                Text("Image generation only runs on a provider that is really available. Nothing is faked when none is.")
                    .font(SSTypography.caption()).foregroundStyle(.secondary)
            }
            Section("Generate") {
                TextEditor(text: $prompt).frame(minHeight: 70).font(.system(size: 14))
                    .accessibilityLabel("Image prompt")
                HStack {
                    Button("Generate") { generate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || module.busy != nil)
                    if let error { Text(error).foregroundStyle(SSColor.danger).font(SSTypography.caption()) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        UserDefaults.standard.set(model, forKey: MediaModule.imageModelKey)
        Task { await module.refreshProviders() }
    }

    private func generate() {
        save(); error = nil
        Task {
            do { _ = try await module.generateImages(prompt: prompt); showViewer() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct VoicePane: View {
    @Bindable var module: MediaModule
    let showViewer: () -> Void
    @State private var text = ""
    @State private var voiceID = ""
    @State private var rate: Double = Double(AVSpeechUtteranceDefaultSpeechRate)
    @State private var error: String?
    @State private var transcript = ""

    var body: some View {
        Form {
            Section("Text to speech") {
                TextEditor(text: $text).frame(minHeight: 70).font(.system(size: 14)).accessibilityLabel("Text to speak")
                Picker("Voice", selection: $voiceID) {
                    Text("Best for this language").tag("")
                    ForEach(SpeechFileSynthesizer.voices(), id: \.identifier) { Text("\($0.name) (\($0.language))").tag($0.identifier) }
                }
                HStack {
                    Text("Rate"); Slider(value: $rate, in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate))
                }
                HStack {
                    Button("Speak aloud") {
                        do { try module.speech.speakAloud(text, voiceID: voiceID.isEmpty ? nil : voiceID, rate: Float(rate)) }
                        catch { self.error = error.localizedDescription }
                    }
                    Button("Save as audio") {
                        error = nil
                        Task {
                            do { _ = try await module.speak(text, voiceID: voiceID.isEmpty ? nil : voiceID, rate: Float(rate)); showViewer() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(module.busy != nil)
                    Button("Stop") { module.speech.stop() }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Speech to text") {
                HStack {
                    Button("Transcribe a file…") { transcribeFile() }.disabled(module.busy != nil)
                    Button { module.voice.toggleListening() } label: {
                        Label(module.voice.phase == .listening ? "Stop dictating" : "Dictate", systemImage: module.voice.phase == .listening ? "mic.fill" : "mic")
                    }
                }
                if module.voice.phase == .listening { Text(module.voice.partial.isEmpty ? "Listening…" : module.voice.partial).foregroundStyle(.secondary) }
                if let voiceError = module.voice.errorText { Text(voiceError).foregroundStyle(SSColor.danger).font(SSTypography.caption()) }
                TextEditor(text: $transcript).frame(minHeight: 90).font(.system(size: 14)).accessibilityLabel("Transcript")
                HStack {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(transcript, forType: .string) }
                        .disabled(transcript.isEmpty)
                    Button("Use as text to speak") { text = transcript }.disabled(transcript.isEmpty)
                }
            }
            if let error { Text(error).foregroundStyle(SSColor.danger).font(SSTypography.caption()) }
        }
        .formStyle(.grouped)
        .onAppear { module.voice.onUtterance = { heard in transcript += (transcript.isEmpty ? "" : " ") + heard } }
    }

    private func transcribeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        Task {
            do { transcript = try await module.transcribe(url) } catch { self.error = error.localizedDescription }
        }
    }
}
