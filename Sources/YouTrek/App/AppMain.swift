import AppKit

@main
@MainActor
final class YouTrekApp: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: YouTrekApp?
    private let container = AppContainer.live
    private var mainWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private var themeObserver: NSObjectProtocol?
    private let showAssigneeColumnDefaultsKey = "issueList.showAssigneeColumn"
    private weak var showAssigneeMenuItem: NSMenuItem?

#if DEBUG
    private weak var simulateSlowResponsesMenuItem: NSMenuItem?
    private weak var showNetworkFooterMenuItem: NSMenuItem?
    private weak var verboseRequestLoggingMenuItem: NSMenuItem?
    private weak var disableSyncingMenuItem: NSMenuItem?
    private weak var showBoardDiagnosticsMenuItem: NSMenuItem?
    private weak var showIssueListDiagnosticsMenuItem: NSMenuItem?
#endif

    static func main() {
        let application = NSApplication.shared
        let delegate = YouTrekApp()
        retainedDelegate = delegate
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await bootstrap() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    private func bootstrap() async {
        if CLIEntrypoint.shouldRun(arguments: CommandLine.arguments) {
            await CLIEntrypoint.runAndExit(arguments: CommandLine.arguments)
            return
        }
        installMenus()
        openMainWindow()
        observePreferenceChanges()
        applyTheme()
    }

    private func openMainWindow() {
        if mainWindowController == nil {
            mainWindowController = makeMainWindowController()
        }
        guard let window = mainWindowController?.window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = makeSettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func makeMainWindowController() -> NSWindowController {
        let contentController = MainWindowViewController(container: container)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1280, height: 800)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "YouTrek"
        window.contentViewController = contentController
        window.center()
        window.isReleasedWhenClosed = false
        applyTheme(to: window)
        return NSWindowController(window: window)
    }

    private func makeSettingsWindowController() -> NSWindowController {
        let contentController = SettingsWindowViewController(container: container)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 480, height: 420)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentViewController = contentController
        window.center()
        window.isReleasedWhenClosed = false
        applyTheme(to: window)
        return NSWindowController(window: window)
    }

    private func applyTheme() {
        let appearance = configuredAppearance()
        for window in visibleWindows {
            window.appearance = appearance
        }
    }

    private var visibleWindows: [NSWindow] {
        [mainWindowController, settingsWindowController]
            .compactMap { $0?.window }
    }

    private func configuredAppearance() -> NSAppearance? {
        let rawTheme = UserDefaults.standard.string(forKey: AppTheme.storageKey) ?? AppTheme.dark.rawValue
        let theme = AppTheme(rawValue: rawTheme) ?? .dark
        return theme == .system ? nil : (theme == .light ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua))
    }

    private func applyTheme(to window: NSWindow) {
        window.appearance = configuredAppearance()
        window.invalidateShadow()
    }

    private func observePreferenceChanges() {
        themeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyTheme()
                self?.refreshMenuStates()
            }
        }
        refreshMenuStates()
    }

    private func refreshMenuStates() {
        showAssigneeMenuItem?.state = UserDefaults.standard.bool(forKey: showAssigneeColumnDefaultsKey) ? .on : .off
#if DEBUG
        simulateSlowResponsesMenuItem?.state = AppDebugSettings.simulateSlowResponses ? .on : .off
        showNetworkFooterMenuItem?.state = AppDebugSettings.showNetworkFooter ? .on : .off
        verboseRequestLoggingMenuItem?.state = AppDebugSettings.verboseRequestLogging ? .on : .off
        disableSyncingMenuItem?.state = AppDebugSettings.disableSyncing ? .on : .off
        showBoardDiagnosticsMenuItem?.state = AppDebugSettings.showBoardDiagnostics ? .on : .off
        showIssueListDiagnosticsMenuItem?.state = AppDebugSettings.showIssueListDiagnostics ? .on : .off
#endif
    }

    private func installMenus() {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        mainMenu.addItem(makeFileMenuItem())
        mainMenu.addItem(makeIssuesMenuItem())
        mainMenu.addItem(makeViewMenuItem())
        mainMenu.addItem(makeCLIMenuItem())
#if DEBUG
        mainMenu.addItem(makeDeveloperMenuItem())
#endif
        NSApp.mainMenu = mainMenu
        refreshMenuStates()
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let appTitle = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "YouTrek"
        let appMenu = NSMenu(title: appTitle)
        let appMenuItem = NSMenuItem(title: appTitle, action: nil, keyEquivalent: "")
        appMenuItem.submenu = appMenu

        appMenu.addItem(NSMenuItem(
            title: "About \(appTitle)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = NSMenu(title: "Services")
        appMenu.addItem(servicesItem)
        appMenu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(
            title: "Hide \(appTitle)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(appTitle)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        return appMenuItem
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        let parent = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        parent.submenu = menu

        let undoItem = NSMenuItem(
            title: "Undo",
            action: NSSelectorFromString("undo:"),
            keyEquivalent: "z"
        )
        undoItem.keyEquivalentModifierMask = .command
        menu.addItem(undoItem)

        let redoItem = NSMenuItem(
            title: "Redo",
            action: NSSelectorFromString("redo:"),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = NSEvent.ModifierFlags([.command, .shift])
        menu.addItem(redoItem)

        menu.addItem(NSMenuItem.separator())

        let cutItem = NSMenuItem(
            title: "Cut",
            action: NSSelectorFromString("cut:"),
            keyEquivalent: "x"
        )
        cutItem.keyEquivalentModifierMask = .command
        menu.addItem(cutItem)

        let copyItem = NSMenuItem(
            title: "Copy",
            action: NSSelectorFromString("copy:"),
            keyEquivalent: "c"
        )
        copyItem.keyEquivalentModifierMask = .command
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: "Paste",
            action: NSSelectorFromString("paste:"),
            keyEquivalent: "v"
        )
        pasteItem.keyEquivalentModifierMask = .command
        menu.addItem(pasteItem)

        menu.addItem(NSMenuItem.separator())

        let deleteItem = NSMenuItem(
            title: "Delete",
            action: NSSelectorFromString("delete:"),
            keyEquivalent: ""
        )
        menu.addItem(deleteItem)

        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: NSSelectorFromString("selectAll:"),
            keyEquivalent: "a"
        )
        selectAllItem.keyEquivalentModifierMask = .command
        menu.addItem(selectAllItem)

        return parent
    }

    private func makeFileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        let parent = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        parent.submenu = menu

        let newIssueItem = NSMenuItem(
            title: "New Issue",
            action: #selector(openNewIssue),
            keyEquivalent: "n"
        )
        newIssueItem.target = self
        menu.addItem(newIssueItem)

        let newIssueFromSelectionItem = NSMenuItem(
            title: "New Issue from Selection",
            action: #selector(openNewIssueFromSelection),
            keyEquivalent: "n"
        )
        newIssueFromSelectionItem.keyEquivalentModifierMask = [.command, .shift]
        newIssueFromSelectionItem.target = self
        menu.addItem(newIssueFromSelectionItem)

        menu.addItem(NSMenuItem.separator())
        let closeItem = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.target = nil
        menu.addItem(closeItem)

        return parent
    }

    private func makeIssuesMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Issues")
        let parent = NSMenuItem(title: "Issues", action: nil, keyEquivalent: "")
        parent.submenu = menu

        let commandPaletteItem = NSMenuItem(
            title: "Command Palette…",
            action: #selector(openCommandPalette),
            keyEquivalent: "k"
        )
        commandPaletteItem.target = self
        menu.addItem(commandPaletteItem)

        let showAssigneeItem = NSMenuItem(
            title: "Show Assignee Column",
            action: #selector(toggleAssigneeColumn),
            keyEquivalent: ""
        )
        showAssigneeItem.target = self
        showAssigneeMenuItem = showAssigneeItem
        menu.addItem(showAssigneeItem)

        return parent
    }

    private func makeViewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        let parent = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        parent.submenu = menu

        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar),
            keyEquivalent: "s"
        )
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .option]
        toggleSidebarItem.target = self
        menu.addItem(toggleSidebarItem)

        return parent
    }

    private func makeCLIMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "CLI")
        let parent = NSMenuItem(title: "CLI", action: nil, keyEquivalent: "")
        parent.submenu = menu

        let installItem = NSMenuItem(
            title: "Install CLI Alias",
            action: #selector(installCLI),
            keyEquivalent: ""
        )
        installItem.target = self
        menu.addItem(installItem)

        return parent
    }

#if DEBUG
    private func makeDeveloperMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Developer")
        let parent = NSMenuItem(title: "Developer", action: nil, keyEquivalent: "")
        parent.submenu = menu

        let simulateSlowResponsesItem = NSMenuItem(
            title: "Simulate slow responses",
            action: #selector(toggleSimulateSlowResponses),
            keyEquivalent: ""
        )
        simulateSlowResponsesItem.target = self
        simulateSlowResponsesMenuItem = simulateSlowResponsesItem

        let showNetworkFooterItem = NSMenuItem(
            title: "Show network footer",
            action: #selector(toggleShowNetworkFooter),
            keyEquivalent: ""
        )
        showNetworkFooterItem.target = self
        showNetworkFooterMenuItem = showNetworkFooterItem

        let verboseLoggingItem = NSMenuItem(
            title: "Verbose request logs",
            action: #selector(toggleVerboseRequestLogging),
            keyEquivalent: ""
        )
        verboseLoggingItem.target = self
        verboseRequestLoggingMenuItem = verboseLoggingItem

        let disableSyncingItem = NSMenuItem(
            title: "Disable syncing",
            action: #selector(toggleDisableSyncing),
            keyEquivalent: ""
        )
        disableSyncingItem.target = self
        disableSyncingMenuItem = disableSyncingItem

        let boardDiagnosticsItem = NSMenuItem(
            title: "Show board diagnostics",
            action: #selector(toggleShowBoardDiagnostics),
            keyEquivalent: ""
        )
        boardDiagnosticsItem.target = self
        showBoardDiagnosticsMenuItem = boardDiagnosticsItem

        let issueListDiagnosticsItem = NSMenuItem(
            title: "Show issue list diagnostics",
            action: #selector(toggleShowIssueListDiagnostics),
            keyEquivalent: ""
        )
        issueListDiagnosticsItem.target = self
        showIssueListDiagnosticsMenuItem = issueListDiagnosticsItem

        let clearCacheItem = NSMenuItem(
            title: "Clear cache and refetch",
            action: #selector(clearCacheAndRefetch),
            keyEquivalent: ""
        )
        clearCacheItem.target = self

        for item in [
            simulateSlowResponsesItem,
            showNetworkFooterItem,
            verboseLoggingItem,
            disableSyncingItem,
            boardDiagnosticsItem,
            issueListDiagnosticsItem,
            clearCacheItem
        ] {
            menu.addItem(item)
        }

        return parent
    }
#endif

    @objc private func openSettings() {
        openSettingsWindow()
    }

    @objc private func openNewIssue() {
        container.presentNewIssueDialog()
    }

    @objc private func openNewIssueFromSelection() {
        container.presentNewIssueDialog(fromSelectedText: selectedTextFromFocusedResponder())
    }

    @objc private func openCommandPalette() {
        container.commandPalette.open()
    }

    @objc private func toggleSidebar() {
        if NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil) {
            return
        }
        container.appState.toggleSidebarVisibility(source: "menu-fallback")
    }

    @objc private func toggleAssigneeColumn(_ sender: NSMenuItem) {
        let newValue = !UserDefaults.standard.bool(forKey: showAssigneeColumnDefaultsKey)
        UserDefaults.standard.set(newValue, forKey: showAssigneeColumnDefaultsKey)
        sender.state = newValue ? .on : .off
    }

    @objc private func installCLI() {
        do {
            let message = try CLIInstaller.installDefault(force: false)
            showAlert(
                title: "CLI Installed",
                message: message,
                style: .informational
            )
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

#if DEBUG
    @objc private func toggleSimulateSlowResponses(_ sender: NSMenuItem) {
        let newValue = !AppDebugSettings.simulateSlowResponses
        AppDebugSettings.setSimulateSlowResponses(newValue)
        sender.state = newValue ? .on : .off
    }

    @objc private func toggleShowNetworkFooter(_ sender: NSMenuItem) {
        let newValue = !AppDebugSettings.showNetworkFooter
        AppDebugSettings.setShowNetworkFooter(newValue)
        sender.state = newValue ? .on : .off
    }

    @objc private func toggleVerboseRequestLogging(_ sender: NSMenuItem) {
        let newValue = !AppDebugSettings.verboseRequestLogging
        AppDebugSettings.setVerboseRequestLogging(newValue)
        sender.state = newValue ? .on : .off
    }

    @objc private func toggleDisableSyncing(_ sender: NSMenuItem) {
        let newValue = !AppDebugSettings.disableSyncing
        AppDebugSettings.setDisableSyncing(newValue)
        sender.state = newValue ? .on : .off
    }

    @objc private func toggleShowBoardDiagnostics(_ sender: NSMenuItem) {
        let newValue = !AppDebugSettings.showBoardDiagnostics
        AppDebugSettings.setShowBoardDiagnostics(newValue)
        sender.state = newValue ? .on : .off
    }

    @objc private func toggleShowIssueListDiagnostics(_ sender: NSMenuItem) {
        let newValue = !AppDebugSettings.showIssueListDiagnostics
        AppDebugSettings.setShowIssueListDiagnostics(newValue)
        sender.state = newValue ? .on : .off
    }

    @objc private func clearCacheAndRefetch() {
        container.clearCacheAndRefetch()
    }
#endif

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }

    private func manualInstallInstructions() -> String {
        let executablePath = Bundle.main.executableURL?.path ?? "/Applications/YouTrek.app/Contents/MacOS/YouTrek"
        return """
        YouTrek could not create the CLI alias automatically.

        Run one of the following in Terminal:

        sudo ln -s \"\(executablePath)\" /usr/local/bin/youtrek

        mkdir -p ~/.local/bin
        ln -s \"\(executablePath)\" ~/.local/bin/youtrek

        If you use the user-level path, ensure ~/.local/bin is on your PATH.
        """
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
        var current: NSResponder? = responder
        while let active = current {
            if let textView = active as? NSTextView,
               let selectedText = selectedText(from: textView) {
                return selectedText
            }
            current = active.nextResponder
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
}
enum SceneID: String {
    case main
    case issue
    case newIssue
}
