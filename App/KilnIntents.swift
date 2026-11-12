import AppIntents

enum KilnDestination: String, AppEnum {
    case home, agent, swarm, develop, analyze, lab, audit, browser, devices, media, images, maps, news, mail, calendar, contacts, messages, github, research, drives, notes

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Kiln Activity"
    static let caseDisplayRepresentations: [KilnDestination: DisplayRepresentation] = [
        .home: "Home", .agent: "Agent", .swarm: "Swarm", .develop: "Develop",
        .analyze: "Analyze", .lab: "Lab", .audit: "Audit", .browser: "Browser",
        .devices: "Devices", .media: "Media", .images: "Images", .maps: "Maps", .news: "News",
        .mail: "Mail", .calendar: "Calendar", .contacts: "Contacts", .messages: "Messages", .github: "GitHub", .research: "Research", .drives: "Cloud Drives", .notes: "Notes"
    ]
}

struct OpenKilnActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Kiln Activity"
    static let description = IntentDescription("Open an activity in your Kiln workstation.")
    static let openAppWhenRun = true

    @Parameter(title: "Activity") var destination: KilnDestination
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        app.requestedActivity = Activity(destination.rawValue)
        return .result()
    }
}

/// Puts a prompt in Kiln's message box (and, only if the shortcut says so, sends it). Sending runs the current agent profile, so tool
/// approvals still appear in Kiln; nothing is approved by the shortcut itself.
struct AskKilnIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Kiln"
    static let description = IntentDescription("Open Kiln's chat with your question ready in the message box, or send it right away.")
    static let openAppWhenRun = true

    @Parameter(title: "Question") var prompt: String
    @Parameter(title: "Send immediately", default: false) var sendNow: Bool
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .result(dialog: "Enter a question for Kiln.") }
        guard let session = app.chatSession else { return .result(dialog: "Kiln is still starting. Try again in a moment.") }
        app.requestedActivity = .agent
        if sendNow {
            Task { await session.send(text) }
            return .result(dialog: "Sent to Kiln. Approve any tool requests in the app.")
        }
        session.composerText = text
        return .result(dialog: "Your question is ready in Kiln.")
    }
}

struct OpenWebsiteInKilnIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Website in Kiln"
    static let description = IntentDescription("Open an HTTP or HTTPS address in Kiln's browser.")
    static let openAppWhenRun = true

    @Parameter(title: "Website") var address: URL
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard BrowserURL.resolveStrict(address.absoluteString) != nil else {
            return .result(dialog: "Enter an HTTP or HTTPS website address.")
        }
        app.openWebURL(address)
        return .result(dialog: "Opening the website in Kiln.")
    }
}

struct KilnShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenKilnActivityIntent(),
            phrases: ["Open \(\.$destination) in \(.applicationName)", "Open an activity in \(.applicationName)"],
            shortTitle: "Open Activity",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: AskKilnIntent(),
            phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
            shortTitle: "Ask Kiln",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: OpenWebsiteInKilnIntent(),
            phrases: ["Open a website in \(.applicationName)", "Browse in \(.applicationName)"],
            shortTitle: "Open Website",
            systemImageName: "globe"
        )
    }
}
