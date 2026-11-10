import AppIntents

enum KilnDestination: String, AppEnum {
    case home, agent, swarm, develop, analyze, lab, audit, browser, devices, media

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Kiln Activity"
    static let caseDisplayRepresentations: [KilnDestination: DisplayRepresentation] = [
        .home: "Home", .agent: "Agent", .swarm: "Swarm", .develop: "Develop",
        .analyze: "Analyze", .lab: "Lab", .audit: "Audit", .browser: "Browser",
        .devices: "Devices", .media: "Media"
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
            intent: OpenWebsiteInKilnIntent(),
            phrases: ["Open a website in \(.applicationName)", "Browse in \(.applicationName)"],
            shortTitle: "Open Website",
            systemImageName: "globe"
        )
    }
}
