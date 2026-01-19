import AppKit
import SwiftUI

struct AppMenus: Commands {
    @ObservedObject var container: AppContainer

    var body: some Commands {
        CommandMenu("Issues") {
            Button("New Issue") {
                container.beginNewIssue(withTitle: "Untitled Issue")
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Command Palette…") {
                container.commandPalette.open()
            }
            .keyboardShortcut("P", modifiers: [.command, .shift])
        }

        CommandGroup(after: .appVisibility) {
            Button("Toggle Sidebar") {
                container.appState.toggleSidebarVisibility()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }

        CommandMenu("CLI") {
            Button("Install CLI Alias") {
                installCLI()
            }
        }
    }

    private func installCLI() {
        do {
            let message = try CLIInstaller.installSymlink(
                at: URL(fileURLWithPath: CLIInstaller.defaultInstallPath),
                force: false
            )
            showAlert(title: "CLI Installed", message: message, style: .informational)
        } catch {
            showAlert(title: "CLI Install Failed", message: error.localizedDescription, style: .warning)
        }
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
