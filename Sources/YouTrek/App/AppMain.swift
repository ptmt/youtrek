import SwiftUI

@main
enum YouTrekEntry {
    static func main() async {
        if CLIEntrypoint.shouldRun(arguments: CommandLine.arguments) {
            await CLIEntrypoint.runAndExit(arguments: CommandLine.arguments)
        }
        YouTrekApp.main()
    }
}

struct YouTrekApp: App {
    @StateObject private var container = AppContainer.live
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .dark

    var body: some Scene {
        WindowGroup(id: SceneID.main.rawValue) {
            MainWindowContent()
                .environmentObject(container)
                .preferredColorScheme(theme.colorScheme)
        }
        .commands { AppMenus(container: container) }

        WindowGroup("YouTrek Issue", id: SceneID.issue.rawValue) {
            IssueDetailWindow()
                .environmentObject(container)
                .preferredColorScheme(theme.colorScheme)
        }
        .handlesExternalEvents(matching: ["youtrek://issue"])
        .defaultSize(width: 720, height: 640)

        WindowGroup("New Issue", id: SceneID.newIssue.rawValue) {
            NewIssueWindow()
                .environmentObject(container)
                .preferredColorScheme(theme.colorScheme)
        }
        .handlesExternalEvents(matching: ["youtrek://new-issue"])
        .defaultSize(width: 560, height: 520)

        Settings {
            SettingsView()
                .environmentObject(container)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}

private struct MainWindowContent: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        Group {
            if container.requiresSetup {
                SetupWindow()
                    .background(WindowAccessor(isSetup: true))
            } else {
                RootView()
                    .background(WindowAccessor(isSetup: false))
            }
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let isSetup: Bool

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        view.isSetup = isSetup
        return view
    }

    func updateNSView(_ nsView: WindowAccessorView, context: Context) {
        nsView.isSetup = isSetup
        nsView.scheduleWindowConfiguration()
    }
}

@MainActor
private final class WindowAccessorView: NSView {
    var isSetup = false
    private var lastConfiguredForSetup: Bool?
    private var pendingConfiguration = false
    private var hasAppliedSetupPresentation = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleWindowConfiguration()
    }

    func scheduleWindowConfiguration() {
        guard !pendingConfiguration else { return }
        pendingConfiguration = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingConfiguration = false
            self.configureWindowIfNeeded()
        }
    }

    func configureWindowIfNeeded() {
        guard let window else { return }
        let needsReconfigure = lastConfiguredForSetup != isSetup
        if needsReconfigure {
            lastConfiguredForSetup = isSetup
        }

        if isSetup {
            if needsReconfigure {
                window.styleMask = [.borderless, .fullSizeContentView]
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
                window.isMovableByWindowBackground = true
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                if let contentView = window.contentView {
                    contentView.wantsLayer = true
                    if let layer = contentView.layer {
                        layer.cornerRadius = 12
                        if #available(macOS 10.13, *) {
                            layer.cornerCurve = .continuous
                        }
                        layer.masksToBounds = true
                    }
                }
                hasAppliedSetupPresentation = false
            }
            if !hasAppliedSetupPresentation {
                window.setContentSize(NSSize(width: 480, height: 340))
                window.center()
                window.makeKeyAndOrderFront(nil)
                hasAppliedSetupPresentation = true
            }
        } else if needsReconfigure {
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.isMovableByWindowBackground = false
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            if let contentView = window.contentView, let layer = contentView.layer {
                layer.cornerRadius = 0
                if #available(macOS 10.13, *) {
                    layer.cornerCurve = .continuous
                }
                layer.masksToBounds = false
            }
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()
            hasAppliedSetupPresentation = false
        }
    }
}

enum SceneID: String {
    case main
    case issue
    case newIssue
}
