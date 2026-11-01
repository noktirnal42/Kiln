import Foundation
import Observation

enum HistoryBucket: Int, CaseIterable {
    case today, yesterday, previousWeek, older

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .previousWeek: "Previous 7 days"
        case .older: "Older"
        }
    }
}

/// Groups the chat history the way the apps it sits beside do. Pure, so it is tested without a window.
enum HistoryGrouping {
    static func bucket(for date: Date, now: Date, calendar: Calendar = .current) -> HistoryBucket {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return .previousWeek
        }
        return .older
    }

    /// Newest first within each group; empty groups are left out. A conversation with no messages is not history
    /// yet (it is just "New chat" waiting for its first message), so it is hidden unless it is the open one.
    static func group(_ items: [ConversationSummary], openID: UUID?, now: Date = Date(),
                      calendar: Calendar = .current) -> [(bucket: HistoryBucket, items: [ConversationSummary])] {
        let visible = items.filter { $0.messageCount > 0 || $0.id == openID }
        let byBucket = Dictionary(grouping: visible) { bucket(for: $0.updatedAt, now: now, calendar: calendar) }
        return HistoryBucket.allCases.compactMap { bucket in
            guard let rows = byBucket[bucket], !rows.isEmpty else { return nil }
            return (bucket, rows.sorted { $0.updatedAt > $1.updatedAt })
        }
    }
}

@MainActor
@Observable
final class ChatHistoryModel {
    private(set) var items: [ConversationSummary] = []
    private var retitled = false

    func refresh(_ session: ChatSession) async {
        if !retitled {
            retitled = true
            await session.retitleUntitledConversations()
        }
        items = await session.conversations()
    }
}
