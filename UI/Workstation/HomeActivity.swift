import SwiftUI

extension Activity { static let home = Activity("home") }

/// Overview of the workstation. Built into the shell; it owns no module and no tools.
enum HomeActivity {
    static let descriptor = ActivityDescriptor(
        id: "home", title: "Home", symbol: "square.grid.2x2", summary: "Overview of your workstation",
        moduleIdentifier: nil,
        content: .custom { workstation in AnyView(HomeView(workstation: workstation)) },
        showsInSidebar: false,
        starterPrompts: { hasProject in StarterPrompts.project(hasProject) + [StarterPrompts.binary, StarterPrompts.hardware] })
}
