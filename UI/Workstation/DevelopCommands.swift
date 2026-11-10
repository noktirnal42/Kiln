import SwiftUI

/// Command-palette entries for the Develop IDE. Each calls `DevelopController`, the same service the agent's `ide_*` tools use.
enum DevelopCommands {
    @MainActor
    static func all(app: AppModel, select: @escaping @MainActor () -> Void) -> [WorkstationCommand] {
        let d = app.develop
        func cmd(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, shortcut: String? = nil,
                 _ run: @escaping @MainActor () -> Void) -> WorkstationCommand {
            WorkstationCommand(id: "develop.\(id)", title: title, subtitle: subtitle, symbol: symbol,
                               keywords: ["develop", "xcode", "ide"], shortcut: shortcut, run: { select(); run() })
        }
        func attempt(_ body: @escaping @MainActor () throws -> Void) -> @MainActor () -> Void {
            { do { try body() } catch { d.error = error.localizedDescription } }
        }
        return [
            cmd("build", "Build", "Build the project with the selected scheme", "hammer", shortcut: "⌘B", attempt { try d.startBuild() }),
            cmd("test", "Run Tests", "Run the project's tests", "checkmark.diamond", shortcut: "⌘U", attempt { try d.startTests() }),
            cmd("run", "Run", "Build and run", "play.fill", shortcut: "⌘R", attempt { try d.startRun() }),
            cmd("stop", "Stop", "Cancel the build, test or run and end the debugger", "stop.fill") { Task { await d.stop() } },
            cmd("debug", "Debug", "Build and run under LLDB", "ant", shortcut: "⌥⌘R") {
                Task { do { try await d.startDebugging() } catch { d.error = error.localizedDescription } }
            },
            cmd("continue", "Debugger: Continue", "Resume the paused program", "play", shortcut: "⌃⌘Y") { Task { try? await d.debug(.continue) } },
            cmd("stepOver", "Debugger: Step Over", "Next line", "arrow.right.to.line", shortcut: "⌘'") { Task { try? await d.debug(.stepOver) } },
            cmd("stepInto", "Debugger: Step Into", "Enter the call", "arrow.down.to.line", shortcut: "⌘;") { Task { try? await d.debug(.stepInto) } },
            cmd("stepOut", "Debugger: Step Out", "Finish the function", "arrow.up.to.line", shortcut: "⇧⌘;") { Task { try? await d.debug(.stepOut) } },
            cmd("definition", "Jump to Definition", "Declaration of the symbol at the caret", "arrow.turn.down.right", shortcut: "⌃⌘J") { Task { await d.goToDefinition() } },
            cmd("references", "Find References", "Every use of the symbol at the caret", "text.magnifyingglass", shortcut: "⌃⌘U") { Task { await d.findReferences() } },
            cmd("rename", "Rename Symbol…", "Rename through the language server", "pencil", shortcut: "⌃⌘E") { d.request = .rename },
            cmd("quickHelp", "Quick Help", "Type and documentation at the caret", "questionmark.circle") { d.request = .quickHelp },
            cmd("quickOpen", "Open Quickly", "Open a file by name", "magnifyingglass", shortcut: "⌘P") { d.request = .quickOpen },
            cmd("goToLine", "Go to Line…", "Jump to a line", "arrow.right.to.line", shortcut: "⌘L") { d.request = .goToLine },
            cmd("back", "Go Back", "Previous place", "chevron.left", shortcut: "⌃⌘←") { d.goBack() },
            cmd("forward", "Go Forward", "Next place", "chevron.right", shortcut: "⌃⌘→") { d.goForward() },
            cmd("symbols", "Show Symbols", "Outline of the open file", "list.bullet.indent") { d.navigator = .symbols; d.showNavigator = true },
            cmd("issues", "Show Issues", "Build and language-server problems", "exclamationmark.triangle") { d.navigator = .issues; d.showNavigator = true },
            cmd("tests", "Show Tests", "Test results", "checkmark.diamond") { d.navigator = .tests; d.showNavigator = true },
            cmd("navigator", "Toggle Navigator", "Show or hide the left pane", "sidebar.left", shortcut: "⌥⌘1") { d.showNavigator.toggle() },
            cmd("inspector", "Toggle Inspector", "Show or hide the right pane", "sidebar.right", shortcut: "⌥⌘0") { d.showInspector.toggle() },
            cmd("debugArea", "Toggle Debug Area", "Show or hide the bottom pane", "rectangle.bottomthird.inset.filled", shortcut: "⇧⌘Y") { d.showBottom.toggle() },
        ]
    }
}
