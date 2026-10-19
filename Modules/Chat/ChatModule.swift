import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
public final class ChatModule: @preconcurrency Module, @preconcurrency ModuleDefinition, ModuleUI {
    public nonisolated static let identifier = "com.kiln.chat"
    public nonisolated static let displayName = "Agentic Chat"
    public nonisolated static let version = "1.0.0"
    public nonisolated static let dependencies: [String] = []
    public nonisolated static let requiredCapabilities: ModuleCapabilities = [.networkClient]

    private var context: ModuleContext?
    private var session: ChatSession?
    private(set) var unavailableReason: String?

    public nonisolated init() {}

    public func initialize(context: ModuleContext) async throws {
        self.context = context
        guard let registry = await context.serviceRegistry.resolve(ModelRegistry.self) else {
            unavailableReason = "ModelRegistry is not registered in the shared service registry."
            context.logger.error("chat module init: missing ModelRegistry")
            return
        }
        guard let store = await context.serviceRegistry.resolve(ConversationStore.self) else {
            unavailableReason = "ConversationStore is not registered in the shared service registry."
            context.logger.error("chat module init: missing ConversationStore")
            return
        }
        guard let artifacts = await context.serviceRegistry.resolve(ArtifactStore.self) else {
            unavailableReason = "ArtifactStore is not registered in the shared service registry."
            context.logger.error("chat module init: missing ArtifactStore")
            return
        }
        let ptyManager = await context.serviceRegistry.resolve(PTYManager.self)
        let mcpService = await context.serviceRegistry.resolve(MCPClientService.self)
        let gitService = await context.serviceRegistry.resolve(GitService.self)
        let fileIndexService = await context.serviceRegistry.resolve(FileIndexService.self)
        session = ChatSession(
            registry: registry,
            conversations: store,
            artifacts: artifacts,
            ptyManager: ptyManager ?? PTYManager(),
            mcpService: mcpService ?? MCPClientService(),
            gitService: gitService ?? GitService(),
            fileIndexService: fileIndexService ?? FileIndexService(),
            workspaceRoot: context.workspace?.rootPath
        )
        context.logger.info("chat module initialized")
    }

    public func activate() async throws {
        context?.logger.info("chat module activated")
    }

    public func deactivate() async throws {
        session?.stopStreaming()
    }

    public func shutdown() async throws {
        session?.stopStreaming()
        session = nil
        context = nil
    }

    public func makeRootView() -> AnyView {
        guard let session else {
            return AnyView(ContentUnavailableView {
                Label("Chat Unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
            } description: {
                Text(unavailableReason ?? "Chat session could not be created.")
            })
        }
        return AnyView(ChatRootView(session: session))
    }
}
