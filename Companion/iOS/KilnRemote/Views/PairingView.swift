import AVFoundation
import KilnRemoteKit
import SwiftUI

struct PairingView: View {
    @Environment(RemoteSession.self) private var session
    @State private var pastedLink = ""
    @State private var message: String?
    @State private var cameraDenied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "flame.fill").font(.system(size: 44)).foregroundStyle(.orange).accessibilityHidden(true)
                    Text("Pair with Kiln on your Mac").font(.title2.bold()).multilineTextAlignment(.center)
                    Text("On your Mac open Kiln, go to Settings → Remote control, and scan the code you see there.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    if cameraDenied {
                        Text("Camera access is off. Turn it on in Settings, or paste the pairing link below.")
                            .font(.footnote).foregroundStyle(.red)
                    } else {
                        QRScannerView { code in handle(code) } onDenied: { cameraDenied = true }
                            .frame(height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.secondary.opacity(0.4)))
                            .accessibilityLabel("Camera viewfinder. Point it at the pairing code on your Mac.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or paste the pairing link").font(.subheadline.bold())
                        HStack {
                            TextField("kiln-remote://pair?…", text: $pastedLink)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Pairing link")
                            Button("Pair") { handle(pastedLink) }
                                .buttonStyle(.borderedProminent)
                                .disabled(pastedLink.isEmpty)
                                .accessibilityLabel("Pair with this link")
                        }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.red).accessibilityLabel("Pairing problem: \(message)") }
                }
                .padding()
            }
            .navigationTitle("Kiln Remote")
        }
    }

    private func handle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let payload = PairingPayload(url: url) else {
            message = "That is not a Kiln pairing code."
            return
        }
        message = nil
        session.pair(with: payload)
    }
}

/// Camera preview that reports the first QR code it reads.
struct QRScannerView: UIViewRepresentable {
    var onCode: (String) -> Void
    var onDenied: () -> Void

    func makeUIView(context: Context) -> ScannerUIView {
        let view = ScannerUIView()
        view.onCode = onCode
        view.onDenied = onDenied
        view.start()
        return view
    }

    func updateUIView(_ uiView: ScannerUIView, context: Context) {}
    static func dismantleUIView(_ uiView: ScannerUIView, coordinator: ()) { uiView.stop() }
}

final class ScannerUIView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (String) -> Void = { _ in }
    var onDenied: () -> Void = {}
    private let captureSession = AVCaptureSession()
    private var reported = false

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    func start() {
        Task { @MainActor in
            guard await AVCaptureDevice.requestAccess(for: .video) else { onDenied(); return }
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  captureSession.canAddInput(input) else { return }   // no camera (Simulator): the paste field remains
            captureSession.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(output) else { return }
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            previewLayer.session = captureSession
            previewLayer.videoGravity = .resizeAspectFill
            let session = captureSession
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }
    }

    func stop() {
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async { if session.isRunning { session.stopRunning() } }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let code = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        MainActor.assumeIsolated {
            guard !reported else { return }
            reported = true
            onCode(code)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reported = false }
        }
    }
}
