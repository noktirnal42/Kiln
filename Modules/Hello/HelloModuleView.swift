import SwiftUI

struct HelloModuleView: View {
    let module: HelloModule
    @State private var message = "ping"
    @State private var systemInfo: String?
    @State private var infoError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SSSpacing.m) {
            Text("Hello from a dynamically loaded module")
                .font(SSTypography.title())

            Text("This module was discovered from its module manifest, loaded by ModuleManager, and granted the capabilities it declared. Events it publishes are delivered cross-module over the ModuleEventBus.")
                .font(SSTypography.body())
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: SSSpacing.m) {
                TextField("Ping message", text: $message)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Button("Publish Ping") {
                    Task {
                        try? await module.publishPing(message: message)
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            LabeledContent("Published pings", value: "\(module.publishedPings)")
            LabeledContent("Received pings", value: "\(module.receivedPings)")
            if let last = module.lastReceivedPing {
                LabeledContent("Last received", value: last)
            }
            if let notice = module.lastLifecycleNotice {
                LabeledContent("Kernel event", value: notice)
            }

            Divider()

            HStack(spacing: SSSpacing.m) {
                Button("Read System Info (requires systemInfo capability)") {
                    Task {
                        do {
                            systemInfo = try module.systemInfoSummary()
                            infoError = nil
                        } catch {
                            systemInfo = nil
                            infoError = String(describing: error)
                        }
                    }
                }
            }
            if let systemInfo {
                Text(systemInfo).font(SSTypography.mono())
            }
            if let infoError {
                Text(infoError)
                    .font(SSTypography.caption())
                    .foregroundStyle(SSColor.danger)
            }

            Spacer()
        }
        .padding(SSSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
