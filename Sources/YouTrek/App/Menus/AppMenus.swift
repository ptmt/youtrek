import SwiftUI

struct AppMenus: Commands {
    @ObservedObject var container: AppContainer

    var body: some Commands {
        CommandMenu("Issues") {
            Button("New Issue") {
                container.issueComposer.beginNewIssue(withTitle: "Untitled Issue")
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Command Palette…") {
                container.commandPalette.open()
            }
            .keyboardShortcut(.init(.letter("P")), modifiers: [.command, .shift])
        }

        CommandGroup(after: .appVisibility) {
            Button("Toggle Sidebar") {
                container.appState.toggleSidebarVisibility()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }
    }
}
