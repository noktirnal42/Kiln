import AppKit
import SwiftUI

/// The viewer for whatever is selected: video, image (zoomable) or audio (waveform).
struct MediaViewer: View {
    let target: MediaModule.Target

    var body: some View {
        switch target.kind {
        case .video: VideoViewer(url: target.url)
        case .audio: AudioViewer(url: target.url)
        case .image: ImageViewer(url: target.url)
        }
    }
}

struct VideoViewer: View {
    let url: URL
    @State private var playback = MediaPlayback()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                PlayerSurface(player: playback.player)
                if let error = playback.loadError {
                    Text(error).foregroundStyle(.white).padding().multilineTextAlignment(.center)
                }
            }
            Divider()
            TransportBar(playback: playback)
        }
        .onAppear { playback.load(url) }
        .onChange(of: url) { _, new in playback.load(new) }
        .onDisappear { playback.stop() }
    }
}

struct AudioViewer: View {
    let url: URL
    @State private var playback = MediaPlayback()
    @State private var peaks: [Float] = []

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    WaveformCanvas(peaks: peaks, progress: playback.duration > 0 ? playback.time / playback.duration : 0)
                    if peaks.isEmpty {
                        Text(playback.loadError ?? "Reading waveform…").foregroundStyle(.secondary).font(SSTypography.caption())
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard playback.duration > 0 else { return }
                    playback.seek(to: playback.duration * max(0, min(1, value.location.x / geo.size.width)))
                })
            }
            .padding(SSSpacing.l)
            .accessibilityLabel("Waveform")
            Divider()
            TransportBar(playback: playback)
        }
        .task(id: url) {
            playback.load(url)
            peaks = []
            peaks = await Waveform.peaks(of: url)
        }
        .onDisappear { playback.stop() }
    }
}

struct WaveformCanvas: View {
    let peaks: [Float]
    let progress: Double

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let width = size.width / CGFloat(peaks.count)
            let mid = size.height / 2
            for (i, peak) in peaks.enumerated() {
                let x = CGFloat(i) * width
                let h = max(1.5, CGFloat(peak) * size.height * 0.9)
                let played = Double(i) / Double(peaks.count) <= progress
                context.fill(Path(CGRect(x: x, y: mid - h / 2, width: max(1, width - 0.5), height: h)),
                             with: .color(played ? SSColor.accent : Color.secondary.opacity(0.45)))
            }
            let px = size.width * CGFloat(progress)
            context.fill(Path(CGRect(x: px, y: 0, width: 1.5, height: size.height)), with: .color(.primary.opacity(0.7)))
        }
    }
}

struct ImageViewer: View {
    let url: URL
    @State private var image: NSImage?
    @State private var zoom: Double = 1
    @State private var fit = true
    @State private var pinchBase: Double?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                if let image {
                    let fitScale = min(geo.size.width / max(image.size.width, 1), geo.size.height / max(image.size.height, 1))
                    let scale = fit ? fitScale : zoom
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                    .gesture(MagnifyGesture().onChanged { value in
                        if pinchBase == nil { pinchBase = fit ? fitScale : zoom; fit = false }
                        zoom = max(0.05, min(16, (pinchBase ?? 1) * value.magnification))
                    }.onEnded { _ in pinchBase = nil })
                    .onChange(of: fit) { _, isFit in if isFit { zoom = fitScale } }
                    .background(Color(nsColor: .underPageBackgroundColor))
                } else {
                    ContentUnavailableView("Can't read this image", systemImage: "photo.badge.exclamationmark")
                }
            }
            Divider()
            HStack(spacing: SSSpacing.s) {
                Button { fit = true } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                Button { fit = false; zoom = 1 } label: { Text("100%") }
                Button { fit = false; zoom = max(0.05, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("Zoom out")
                Slider(value: Binding(get: { log2(zoom) }, set: { fit = false; zoom = pow(2, $0) }), in: -4...4).frame(maxWidth: 220)
                    .accessibilityLabel("Zoom")
                Button { fit = false; zoom = min(16, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("Zoom in")
                Text(fit ? "Fit" : "\(Int(zoom * 100))%").monospacedDigit().font(SSTypography.caption()).foregroundStyle(.secondary)
                Spacer()
                if let image { Text("\(Int(image.size.width)) × \(Int(image.size.height))").font(SSTypography.caption()).foregroundStyle(.secondary) }
            }
            .buttonStyle(.borderless).padding(SSSpacing.s)
        }
        .task(id: url) { image = NSImage(contentsOf: url); fit = true }
    }
}
