import SwiftUI

/// The legal texts that ship inside the app. MIT and Apache-2.0 require their notices to travel with the
/// binary, so these files are bundled (see `project.yml`) rather than only living in the repository.
enum LegalDocument: String, CaseIterable, Identifiable {
    case license = "LICENSE"
    case commercial = "COMMERCIAL-LICENSE"
    case history = "LICENSE-HISTORY"
    case notices = "THIRD-PARTY-NOTICES"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .license: "License"
        case .commercial: "Commercial use"
        case .history: "License history"
        case .notices: "Third-party notices"
        }
    }

    /// The bundled file's text, or nil when the resource is missing from the build.
    func text(in bundle: Bundle = .main) -> String? {
        let ext: String? = self == .license ? nil : "md"
        guard let url = bundle.url(forResource: rawValue, withExtension: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Version, who licenses Kiln and on what terms, with the full texts one click away.
struct AboutKilnView: View {
    @State private var shown: LegalDocument?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.s) {
            Text("About Kiln").font(SSTypography.title())
            Text("Version \(version) · © 2026 FreeRange Labs")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            Text("Kiln is source-available under the PolyForm Noncommercial License 1.0.0: free for personal, research, educational and charitable use. Using it for work or for a business needs a commercial license (freerangelabs@drumnbus.com). Releases up to 0.1.1 were published under MIT.")
                .font(SSTypography.caption()).foregroundStyle(.secondary)
            HStack {
                ForEach(LegalDocument.allCases) { document in
                    Button(document.title) { shown = document }
                        .disabled(document.text() == nil)
                }
            }
            .controlSize(.small)
        }
        .sheet(item: $shown) { document in
            VStack(spacing: 0) {
                HStack {
                    Text(document.title).font(SSTypography.headline())
                    Spacer()
                    Button("Done") { shown = nil }.keyboardShortcut(.cancelAction)
                }
                .padding(SSSpacing.m)
                Divider()
                ScrollView {
                    Text(document.text() ?? "This document is missing from the app bundle.")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SSSpacing.m)
                }
            }
            .frame(width: 640, height: 520)
        }
    }
}
