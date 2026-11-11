import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import Kiln

@Suite("Composer context: mentions, attachments, expansion")
struct ComposerContextTests {
    @Test func preparedImageIsBoundedAndStripsSourceMetadata() throws {
        let root = try makeProject(["photo.png": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("photo.png")
        let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "private metadata"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let prepared = try ImageAttachmentPreparer.prepare(url, maxDimension: 20)
        #expect(prepared.mimeType == "image/png")
        let source = try #require(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 20 && decoded.height == 10)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        #expect(png?[kCGImagePropertyPNGDescription] == nil)
        let expansion = ContextExpander.expand(prompt: "describe @photo.png", attachments: [ComposerAttachment(url: url)], workspaceRoot: root, includeImages: true)
        #expect(expansion.images.count == 1, "a mention and attachment of the same file must not duplicate it")
        #expect(expansion.imageFailures.isEmpty)
        #expect(expansion.text.contains("image supplied separately"))
        #expect(!expansion.text.contains(url.path))
        #expect(throws: ImageAttachmentPreparer.Failure.tooLarge) { try ImageAttachmentPreparer.prepare(url, maxOutputBytes: 1) }
    }

    @Test func imagePreparationRejectsInvalidAndOversizedFiles() throws {
        let root = try makeProject(["bad.png": "not an image"])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bad.png")
        #expect(throws: ImageAttachmentPreparer.Failure.invalidImage) { try ImageAttachmentPreparer.prepare(url) }
        #expect(throws: ImageAttachmentPreparer.Failure.tooLarge) { try ImageAttachmentPreparer.prepare(url, maxSourceBytes: 2) }
        #expect(throws: ImageAttachmentPreparer.Failure.unreadable) { try ImageAttachmentPreparer.prepare(root.appendingPathComponent("missing.png")) }
        let result = ContextExpander.expand(prompt: "see @missing.png", attachments: [ComposerAttachment(url: url)], workspaceRoot: root, includeImages: true)
        #expect(result.imageFailures.count == 2)
        #expect(result.images.isEmpty)
    }

    // MARK: Mentions

    @Test func theActiveMentionIsTheLastWordWhenItStartsWithAt() {
        #expect(MentionParser.activeQuery(in: "look at @src/ma") == "src/ma")
        #expect(MentionParser.activeQuery(in: "@") == "")
        #expect(MentionParser.activeQuery(in: "look at @src/main.swift and") == nil)
        #expect(MentionParser.activeQuery(in: "mail me at a@b.com") == nil, "an email address is not a mention")
        #expect(MentionParser.activeQuery(in: "trailing space ") == nil)
        #expect(MentionParser.activeQuery(in: "") == nil)
    }

    @Test func completingReplacesOnlyTheTypedMention() {
        #expect(MentionParser.completing("fix @Pag", with: "Sources/Pagination.swift") == "fix @Sources/Pagination.swift ")
        #expect(MentionParser.completing("no mention here", with: "x") == "no mention here")
        #expect(MentionParser.completing("@a", with: "b/c.swift") == "@b/c.swift ")
    }

    @Test func mentionsNeedAPathShapeAndAreDeduplicated() {
        let found = MentionParser.mentions(in: "see @a/b.swift, then @a/b.swift and @c.md; ignore @someone and a@b.com")
        #expect(found == ["a/b.swift", "c.md"])
    }

    // MARK: Search ranking

    @Test func fileNameMatchesBeatPathMatches() throws {
        let exact = try #require(WorkspaceFileSearch.score(path: "Sources/Pagination.swift", query: "pagination.swift"))
        let prefix = try #require(WorkspaceFileSearch.score(path: "Sources/Pagination.swift", query: "pagin"))
        let inPath = try #require(WorkspaceFileSearch.score(path: "Pagination/Other.swift", query: "pagin"))
        let fuzzy = try #require(WorkspaceFileSearch.score(path: "Sources/Pagination.swift", query: "pgn"))
        #expect(exact > prefix && prefix > inPath && inPath > fuzzy)
        #expect(WorkspaceFileSearch.score(path: "a.swift", query: "zzz") == nil)
    }

    @Test func searchFindsFilesAndSkipsBuildFolders() throws {
        let root = try makeProject(["Sources/Pagination.swift": "x", "Sources/Other.swift": "y", "node_modules/pagination/index.js": "z", ".hidden/pagination.txt": "h"])
        defer { try? FileManager.default.removeItem(at: root) }
        let hits = WorkspaceFileSearch.matches(query: "pagin", root: root)
        #expect(hits == ["Sources/Pagination.swift"])
        #expect(WorkspaceFileSearch.matches(query: "", root: root).contains("Sources/") )
    }

    // MARK: Expansion

    @Test func aMentionedFileIsAppendedAndSplitBackIntoAChip() throws {
        let root = try makeProject(["Sources/A.swift": "let a = 1\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = ContextExpander.expand(prompt: "explain @Sources/A.swift", attachments: [], workspaceRoot: root)
        #expect(result.included == ["Sources/A.swift"])
        #expect(result.text.contains("let a = 1"))
        let parts = ContextExpander.split(result.text)
        #expect(parts.visible == "explain @Sources/A.swift")
        #expect(parts.attached == ["Sources/A.swift"])
    }

    @Test func mentionsOutsideTheProjectAndMissingFilesAreReportedNotRead() throws {
        let root = try makeProject(["A.swift": "a"])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = ContextExpander.expand(prompt: "read @../secret.txt and @nope.swift", attachments: [], workspaceRoot: root)
        #expect(result.included.isEmpty)
        #expect(result.skipped.count == 2)
        #expect(result.skipped.contains { $0.contains("outside the project") })
        #expect(result.text == "read @../secret.txt and @nope.swift", "nothing is appended when nothing was read")
    }

    @Test func attachedFilesFoldersAndImagesBecomeContextBlocks() throws {
        let root = try makeProject(["docs/readme.md": "# Title\n", "docs/pic.png": "not really a png", "docs/b.bin": ""])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2, 0]).write(to: root.appendingPathComponent("docs/b.bin"))
        let attachments = ["docs/readme.md", "docs/pic.png", "docs/b.bin", "docs"].map { ComposerAttachment(url: root.appendingPathComponent($0)) }
        #expect(attachments.map(\.kind) == [.file, .image, .file, .folder])
        let result = ContextExpander.expand(prompt: "look", attachments: attachments, workspaceRoot: nil)
        #expect(result.included == ["readme.md", "pic.png", "docs/"])
        #expect(result.skipped == ["b.bin (binary)"])
        #expect(result.text.contains("# Title"))
        #expect(result.text.contains("its pixels are not sent"), "images are named, and the text says why they are not decoded")
    }

    @Test func largeFilesAreTruncatedWithAnHonestNote() throws {
        let root = try makeProject(["big.txt": String(repeating: "x", count: 5_000)])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = ContextExpander.expand(prompt: "@big.txt", attachments: [], workspaceRoot: root, maxFileBytes: 1_000, maxTotalBytes: 10_000)
        #expect(result.text.contains("truncated: 5000 bytes in the file, 1000 shown"))
    }

    @Test func headingsInsideAFileAreNotMistakenForAttachmentNames() throws {
        let root = try makeProject(["notes.md": "### Not an attachment\ntext\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = ContextExpander.expand(prompt: "@notes.md", attachments: [], workspaceRoot: root)
        #expect(ContextExpander.split(result.text).attached == ["notes.md"])
    }

    @Test func plainMessagesAreUntouched() {
        let parts = ContextExpander.split("just a message")
        #expect(parts.visible == "just a message" && parts.attached.isEmpty)
    }

    // MARK: Helpers

    private func makeProject(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-composer-\(UUID().uuidString)", isDirectory: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
}


/// The queue, with a provider that holds its first reply until the test lets it go.
@MainActor
@Suite("Composer queue")
struct ComposerQueueTests {
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private var calls = 0
        func firstCall() -> Bool { lock.lock(); defer { lock.unlock() }; calls += 1; return calls == 1 }
        func release() { lock.lock(); open = true; lock.unlock() }
        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    }

    struct Held: ModelProvider {
        let id = "held"
        let name = "Held"
        let providerType: ProviderType = .customEndpoint
        let capabilities: ProviderCapabilities = [.streaming]
        let gate: Gate
        func fetchModels() async throws -> [ModelDescriptor] {
            [ModelDescriptor(id: "held-m", name: "m", providerID: id, providerType: providerType, contextWindow: 14_000)]
        }
        func streamChat(_ request: ChatRequest, reasoning: ReasoningConfig?) async throws -> AsyncThrowingStream<ChatChunk, Error> {
            let first = gate.firstCall()
            let gate = gate
            return AsyncThrowingStream { c in
                Task {
                    if first { while !gate.isOpen { try? await Task.sleep(for: .milliseconds(10)) } }
                    c.yield(ChatChunk(delta: ChatMessage(role: .assistant, content: "ok"), finishReason: .stop))
                    c.finish()
                }
            }
        }
        func checkAvailability() async -> ProviderAvailability { .available() }
    }

    private func makeSession(gate: Gate) async throws -> ChatSession {
        let schema = Schema([Conversation.self, Message.self, Artifact.self, ArtifactVersion.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let session = ChatSession(registry: ModelRegistry(eventBus: ModuleEventBus()), conversations: ConversationStore(container: container),
                                  artifacts: ArtifactStore(container: container), compactionDefaults: nil)
        await session.registry.register(Held(gate: gate))
        await session.newConversation()
        session.selectedModelID = "held-m"
        return session
    }

    private func wait(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aMessageTypedDuringARunWaitsAndIsSentWhenItEnds() async throws {
        let gate = Gate()
        let session = try await makeSession(gate: gate)
        let first = Task { await session.send("one") }
        await wait { session.isStreaming }
        #expect(session.isStreaming)

        await session.send("two")
        #expect(session.queuedMessages.map(\.text) == ["two"], "queued, not dropped and not sent yet")
        #expect(session.messages.filter { $0.role == .user }.count == 1)

        gate.release()
        await first.value
        await wait { session.messages.filter { $0.role == .user }.count == 2 && !session.isStreaming }
        #expect(session.messages.filter { $0.role == .user }.map(\.content) == ["one", "two"])
        #expect(session.queuedMessages.isEmpty)
    }

    @Test func stoppingPausesTheQueueUntilThePersonSendsIt() async throws {
        let gate = Gate()
        let session = try await makeSession(gate: gate)
        let first = Task { await session.send("one") }
        await wait { session.isStreaming }
        await session.send("two")
        session.stopStreaming()
        gate.release()
        await first.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.queuedMessages.count == 1, "a stopped run does not send what was queued behind it")
        #expect(session.queuePaused)

        await session.sendNextQueued()
        #expect(session.queuedMessages.isEmpty)
        #expect(session.messages.contains { $0.role == .user && $0.content == "two" })
    }

    @Test func attachmentsAreReadWhenTheMessageIsSentAndShownAsChips() async throws {
        let gate = Gate()
        gate.release()
        let session = try await makeSession(gate: gate)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-attach-\(UUID().uuidString).txt")
        try "hello file".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        session.attach([file, file])
        #expect(session.attachments.count == 1, "the same file is attached once")
        await session.send("summarise")
        #expect(session.attachments.isEmpty)
        let sent = try #require(session.messages.first { $0.role == .user })
        #expect(sent.content.contains("hello file"))
        #expect(ContextExpander.split(sent.content).visible == "summarise")
        #expect(session.conversationTitle == "summarise", "the title comes from what was typed, not the attached text")
    }
}
