import Foundation
import Testing
@testable import Kiln

/// Runs the real agent loop against a hosted model using the keys saved in Settings. Off unless
/// `TEST_RUNNER_KILN_LIVE=1` is set for xcodebuild, because it spends network calls (and, for a paid
/// model, money). The prompts never name a tool: the model has to choose from the tool list.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE"] == "1"))
struct LiveHostedModelTests {
    private struct Target {
        let label: String
        let provider: any ModelProvider
        /// Candidate models from what the provider reports, best first; empty means skip.
        let pick: @Sendable ([ModelDescriptor]) -> [String]
    }

    private func targets() -> [Target] {
        let keychain = KeychainService()
        return [
            Target(label: "openrouter",
                   provider: OpenRouterProvider(secretProvider: keychain.secretProvider(module: providersKeychainModule, key: "openrouter")),
                   pick: { models in Array(models.filter { $0.supportsTools && $0.id.hasSuffix(":free") }.prefix(4).map(\.id)) }),
            Target(label: "nvidia-nim",
                   provider: NVIDIANIMProvider(secretProvider: keychain.secretProvider(module: providersKeychainModule, key: "nvidia-nim")),
                   pick: { models in
                       let glm = models.filter { $0.id.lowercased().contains("glm") && $0.id.contains("5.3") }.map(\.id)
                       print("LIVE nvidia-nim GLM candidates: \(glm)")
                       return glm + models.filter { $0.id.hasSuffix("meta/llama-3.3-70b-instruct") }.map(\.id)
                   }),
        ]
    }

    private func workspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "Kiln agent test file.\nThe secret word is \"marmalade\".\n".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    private func run(_ target: Target, model: String, profileName: String, prompt: String, root: URL,
                     autoApprove: Bool) async throws -> (text: String, tools: [String]) {
        let (center, watcher) = try makeTestApprovalCenter(autoResolve: autoApprove ? .approveOnce : .deny)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(approvalCenter: center)
        var profile = try #require(AgentProfile.builtIns.first { $0.name == profileName })
        // Catalog ids are "<provider>-<model>"; the provider itself wants the bare model name.
        let prefix = "\(target.provider.id)-"
        profile.modelID = model.hasPrefix(prefix) ? String(model.dropFirst(prefix.count)) : model
        let provider = target.provider
        var text = "", tools: [String] = []
        for try await event in orchestrator.run(profile: profile, prompt: prompt, workspaceRoot: root,
                                                chat: { request in try await provider.streamChat(request, reasoning: nil) }) {
            switch event {
            case .toolCallFinished(let record) where record.status == .succeeded: tools.append(record.toolName)
            case .finished(let summary): text = summary.finalText
            default: break
            }
        }
        return (text, tools)
    }

    @Test func aHostedModelChoosesToReadAFileWithoutBeingToldTheTool() async throws {
        for target in targets() {
            guard let models = try? await target.provider.fetchModels() else {
                print("LIVE \(target.label): skipped (no key, or models did not load)"); continue
            }
            let root = try workspace()
            defer { try? FileManager.default.removeItem(at: root) }
            var outcome: (model: String, text: String, tools: [String])?
            for model in target.pick(models) {
                do {
                    let result = try await run(target, model: model, profileName: "Research Assistant",
                                               prompt: "What is the secret word in notes.txt?", root: root, autoApprove: false)
                    outcome = (model, result.text, result.tools); break
                } catch { print("LIVE \(target.label) \(model): \(String(describing: error).prefix(120))") }
            }
            guard let result = outcome else { print("LIVE \(target.label): no model worked"); continue }
            print("LIVE \(target.label) \(result.model): tools=\(result.tools) answer=\(result.text.prefix(120))")
            // Any way of reading the file is fine (read_file, grep_files, ...): the point is that the model chose.
            let reads: Set<String> = ["read_file", "grep_files", "search_workspace", "list_directory", "glob_files"]
            #expect(!reads.isDisjoint(with: result.tools), "\(target.label) never looked at the file")
            #expect(result.text.lowercased().contains("marmalade"), "\(target.label) did not answer from the file")
        }
    }

    @Test func aHostedModelWritesAFileOnlyAfterApproval() async throws {
        for target in targets() {
            guard let models = try? await target.provider.fetchModels() else {
                print("LIVE \(target.label): skipped (no key, or models did not load)"); continue
            }
            let root = try workspace()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("hello.txt")
            let prompt = "Please create hello.txt containing: hello from kiln"

            // Without approval nothing may be written, whatever the model tries.
            // Then, with approval, find a model that is up (free tiers come and go) and confirm the write.
            var usedModel: String?
            for model in target.pick(models) {
                do {
                    _ = try await run(target, model: model, profileName: "Coding Agent", prompt: prompt, root: root, autoApprove: false)
                    #expect(!FileManager.default.fileExists(atPath: file.path), "\(target.label) wrote without approval")
                    let approved = try await run(target, model: model, profileName: "Coding Agent", prompt: prompt, root: root, autoApprove: true)
                    print("LIVE \(target.label) \(model) write: tools=\(approved.tools)")
                    usedModel = model; break
                } catch { print("LIVE \(target.label) \(model): \(String(describing: error).prefix(120))") }
            }
            guard usedModel != nil else { print("LIVE \(target.label): no model worked"); continue }
            #expect(FileManager.default.fileExists(atPath: file.path), "\(target.label) did not write after approval")
        }
    }
}
