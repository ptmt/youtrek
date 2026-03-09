import AppKit
import SwiftUI

struct AppMenus: Commands {
    @ObservedObject var container: AppContainer
    @AppStorage("issueList.showAssigneeColumn") private var showAssigneeColumn: Bool = false
    #if DEBUG
    @AppStorage(AppDebugSettings.Keys.simulateSlowResponses) private var simulateSlowResponses: Bool = false
    @AppStorage(AppDebugSettings.Keys.showNetworkFooter) private var showNetworkFooter: Bool = false
    @AppStorage(AppDebugSettings.Keys.verboseRequestLogging) private var verboseRequestLogging: Bool = false
    @AppStorage(AppDebugSettings.Keys.disableSyncing) private var disableSyncing: Bool = false
    @AppStorage(AppDebugSettings.Keys.showBoardDiagnostics) private var showBoardDiagnostics: Bool = false
    @AppStorage(AppDebugSettings.Keys.showIssueListDiagnostics) private var showIssueListDiagnostics: Bool = false
    #endif

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Issue") {
                openNewIssue()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("New Issue from Selection") {
                openNewIssueFromSelection()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Issues") {
            Button("New Issue") {
                openNewIssue()
            }

            Button("New Issue from Selection") {
                openNewIssueFromSelection()
            }

            Button("Command Palette…") {
                container.commandPalette.open()
            }
            .keyboardShortcut("k", modifiers: [.command])

            Divider()

            Toggle("Show Assignee Column", isOn: $showAssigneeColumn)
        }

        CommandGroup(after: .appVisibility) {
            Button("Toggle Sidebar") {
                toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }

        CommandMenu("CLI") {
            Button("Install CLI Alias") {
                installCLI()
            }
        }

        #if DEBUG
        CommandMenu("Developer") {
            Toggle("Simulate slow responses", isOn: $simulateSlowResponses)
            Toggle("Show network footer", isOn: $showNetworkFooter)
            Toggle("Verbose request logs", isOn: $verboseRequestLogging)
            Toggle("Disable syncing", isOn: $disableSyncing)
            Toggle("Show board diagnostics", isOn: $showBoardDiagnostics)
            Toggle("Show issue list diagnostics", isOn: $showIssueListDiagnostics)
            Divider()
            Button("Clear cache and refetch") {
                container.clearCacheAndRefetch()
            }
        }
        #endif
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
        container.presentNewIssueDialog()
    }

    private func toggleSidebar() {
        if NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil) {
            return
        }
        container.appState.toggleSidebarVisibility(source: "menu-fallback")
    }

    private func openNewIssueFromSelection() {
        let shouldQueueAsUncommitted = container.appState.selectedSidebarItem?.isTodoList == true
        container.presentNewIssueDialog(
            fromSelectedText: selectedTextFromFocusedResponder(),
            queueAsUncommitted: shouldQueueAsUncommitted
        )
    }

    private func selectedTextFromFocusedResponder() -> String? {
        let firstResponder = NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
        return selectedText(from: firstResponder)
    }

    private func selectedText(from responder: NSResponder?) -> String? {
        guard let responder else { return nil }
        if let textView = responder as? NSTextView {
            return selectedText(from: textView)
        }
        if let text = selectedTextFromResponderChain(startingAt: responder) {
            return text
        }
        if let view = responder as? NSView,
           let fieldEditor = view.window?.fieldEditor(false, for: view) as? NSTextView {
            return selectedText(from: fieldEditor)
        }
        return nil
    }

    private func selectedTextFromResponderChain(startingAt responder: NSResponder) -> String? {
        var currentResponder: NSResponder? = responder
        while let current = currentResponder {
            if let textView = current as? NSTextView,
               let selectedText = selectedText(from: textView) {
                return selectedText
            }
            currentResponder = current.nextResponder
        }
        return nil
    }

    private func selectedText(from textView: NSTextView) -> String? {
        let range = textView.selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        let fullText = textView.string as NSString
        guard NSMaxRange(range) <= fullText.length else { return nil }
        let selectedText = fullText.substring(with: range)
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return selectedText
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
