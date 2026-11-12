import Foundation

/// How Home groups the activity cards. An activity that is not listed here still appears, under "More", so a newly
/// registered activity is never missing from Home.
enum HomeSections {
    struct Section: Equatable {
        let title: String
        let activities: [Activity]
    }

    private static let layout: [(title: String, ids: [String])] = [
        ("Work", ["agent", "swarm", "develop", "analyze", "lab", "audit", "browser", "devices", "media", "images", "maps", "news"]),
        ("Communication", ["mail", "messages", "contacts", "calendar"]),
        ("Files and knowledge", ["notes", "drives", "research", "github"]),
    ]

    static func grouped(_ activities: [Activity]) -> [Section] {
        var remaining = activities
        var sections: [Section] = []
        for (title, ids) in layout {
            let members = ids.compactMap { id in activities.first { $0.id == id } }
            if !members.isEmpty { sections.append(Section(title: title, activities: members)) }
            remaining.removeAll { activity in ids.contains(activity.id) }
        }
        if !remaining.isEmpty { sections.append(Section(title: "More", activities: remaining)) }
        return sections
    }
}
