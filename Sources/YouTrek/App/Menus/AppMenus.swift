import AppKit
import SwiftUI

struct AppMenus: Commands {
    @ObservedObject var container: AppContainer

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Issue") {
                openNewIssue()
            }
            .keyboardShortcut("n", modifiers: [.command])
        }

        CommandMenu("Issues") {
            Button("New Issue") {
                openNewIssue()
            }

            Button("Command Palette…") {
                container.commandPalette.open()
            }
            .keyboardShortcut("P", modifiers: [.command, .shift])
        }

        CommandGroup(after: .appVisibility) {
            Button("Toggle Sidebar") {
                container.appState.toggleSidebarVisibility(source: "menu")
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
            let message = try CLIInstaller.installDefault(force: false)
            showAlert(title: "CLI Installed", message: message, style: .informational)
        } catch {
            if case CLIInstallerError.permissionDenied = error {
                showAlert(
                    title: "CLI Install Needs Terminal",
                    message: manualInstallInstructions(),
                    style: .warning
                )
                return
            }
            showAlert(title: "CLI Install Failed", message: error.localizedDescription, style: .warning)
        }
    }

    private func manualInstallInstructions() -> String {
        let executablePath = Bundle.main.executableURL?.path ?? "/Applications/YouTrek.app/Contents/MacOS/YouTrek"
        return """
        YouTrek could not create the CLI alias automatically.

        Run one of the following in Terminal:

        sudo ln -s "\(executablePath)" /usr/local/bin/youtrek

        mkdir -p ~/.local/bin
        ln -s "\(executablePath)" ~/.local/bin/youtrek

        If you use the user-level path, ensure ~/.local/bin is on your PATH.
        """
    }

    private func openNewIssue() {
        container.beginNewIssue(withTitle: "")
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
