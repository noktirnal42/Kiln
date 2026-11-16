import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// How much of a conversation Spotlight may see. Spotlight is searchable by everyone who uses this Mac account and its index is kept by
/// macOS, so the default is Off, and the text mode redacts secrets first.
public enum SpotlightMode: String, CaseIterable, Identifiable, Sendable {
    case off, titles, full
    public static let defaultsKey = "spotlight.mode"
    public var id: String { rawValue }
    public var label: String {
        switch self { case .off: "Off"; case .titles: "Titles only"; case .full: "Titles and text" }
    }
    public static func current(_ defaults: UserDefaults = .standard) -> SpotlightMode { SpotlightMode(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .off }
}

/// One conversation as Spotlight will store it.
public struct SpotlightEntry: Equatable, Sendable {
    public var identifier: String
    public var title: String
    public var summary: String
    public var text: String          // empty in titles-only mode
    public var modified: Date
    public var keywords: [String]
}

public enum ConversationSpotlight {
    public static let domain = "com.kiln.conversation"
    static let idPrefix = "kiln.conversation."
    static let textLimit = 20_000
    static let summaryLimit = 200

    public static func identifier(for id: UUID) -> String { idPrefix + id.uuidString }

    /// The conversation id inside a Spotlight identifier, or nil if it is not one of ours.
    public static func conversationID(from identifier: String) -> UUID? {
        identifier.hasPrefix(idPrefix) ? UUID(uuidString: String(identifier.dropFirst(idPrefix.count))) : nil
    }

    /// Builds the entry for a conversation, or nil when the mode is off or there is nothing worth indexing.
    public static func entry(for summary: ConversationSummary, messages: [MessageSnapshot], mode: SpotlightMode) -> SpotlightEntry? {
        guard mode != .off else { return nil }
        let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != ConversationTitle.placeholder else { return nil }
        guard mode == .full else {
            return SpotlightEntry(identifier: identifier(for: summary.id), title: title, summary: "Kiln conversation", text: "", modified: summary.updatedAt, keywords: ["Kiln", "chat"])
        }
        let spoken = messages.filter { $0.role == .user || $0.role == .assistant }.map(\.content)
        var text = SecretRedactor.redact(spoken.joined(separator: "\n\n")).text
        if text.count > textLimit { text = String(text.prefix(textLimit)) }
        let lastReply = messages.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content ?? messages.last?.content ?? ""
        let blurb = String(SecretRedactor.redact(lastReply).text.replacingOccurrences(of: "\n", with: " ").prefix(summaryLimit))
        return SpotlightEntry(identifier: identifier(for: summary.id), title: title, summary: blurb.isEmpty ? "Kiln conversation" : blurb, text: text, modified: summary.updatedAt, keywords: ["Kiln", "chat"])
    }
}

/// Where entries go. The real one is Core Spotlight; tests record calls.
public protocol SpotlightIndexing: Sendable {
    func index(_ entries: [SpotlightEntry]) async
    func remove(identifiers: [String]) async
    func removeAll() async
}

public struct CoreSpotlightIndexer: SpotlightIndexing {
    public init() {}

    public func index(_ entries: [SpotlightEntry]) async {
        guard !entries.isEmpty else { return }
        let items = entries.map { e -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = e.title
            attributes.contentDescription = e.summary
            if !e.text.isEmpty { attributes.textContent = e.text }
            attributes.contentModificationDate = e.modified
            attributes.keywords = e.keywords
            let item = CSSearchableItem(uniqueIdentifier: e.identifier, domainIdentifier: ConversationSpotlight.domain, attributeSet: attributes)
            item.expirationDate = .distantFuture
            return item
        }
        try? await CSSearchableIndex.default().indexSearchableItems(items)
    }

    public func remove(identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        try? await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers)
    }

    public func removeAll() async {
        try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [ConversationSpotlight.domain])
    }
}

/// Keeps the Spotlight index in step with the conversations, according to the chosen mode.
public actor SpotlightSync {
    private let store: ConversationStore
    private let indexer: any SpotlightIndexing
    private let defaults: UserDefaults
    static let reindexLimit = 200

    /// `suiteName` selects another preferences domain (tests); nil uses the app's own.
    public init(store: ConversationStore, indexer: any SpotlightIndexing = CoreSpotlightIndexer(), suiteName: String? = nil) {
        self.store = store; self.indexer = indexer
        self.defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    private var mode: SpotlightMode { SpotlightMode.current(defaults) }

    /// Rebuilds the whole index for the current mode: Off clears everything Kiln put there.
    public func rebuild() async {
        await indexer.removeAll()
        guard mode != .off, let all = try? await store.conversations(limit: Self.reindexLimit) else { return }
        var entries: [SpotlightEntry] = []
        for summary in all {
            let messages = mode == .full ? ((try? await store.messages(conversationID: summary.id).messages) ?? []) : []
            if let e = ConversationSpotlight.entry(for: summary, messages: messages, mode: mode) { entries.append(e) }
        }
        await indexer.index(entries)
    }

    /// One conversation changed (a run finished, it was renamed).
    public func update(_ id: UUID) async {
        guard mode != .off, let summary = (try? await store.conversations(limit: Self.reindexLimit))?.first(where: { $0.id == id }) else { return }
        let messages = mode == .full ? ((try? await store.messages(conversationID: id).messages) ?? []) : []
        if let e = ConversationSpotlight.entry(for: summary, messages: messages, mode: mode) { await indexer.index([e]) }
    }

    public func remove(_ id: UUID) async {
        await indexer.remove(identifiers: [ConversationSpotlight.identifier(for: id)])
    }
}
