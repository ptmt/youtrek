import SwiftUI

@main
struct YouTrekApp: App {
    @StateObject private var container = AppContainer.live

    var body: some Scene {
        WindowGroup(id: SceneID.main.rawValue) {
            MainWindowContent()
                .environmentObject(container)
        }
        .commands { AppMenus(container: container) }

        WindowGroup("YouTrek Issue", id: SceneID.issue.rawValue) {
            IssueDetailWindow()
                .environmentObject(container)
        }
        .handlesExternalEvents(matching: ["youtrek://issue"])
        .defaultSize(width: 720, height: 640)

        WindowGroup("New Issue", id: SceneID.newIssue.rawValue) {
            NewIssueWindow()
                .environmentObject(container)
        }
        .handlesExternalEvents(matching: ["youtrek://new-issue"])
        .defaultSize(width: 560, height: 520)

        Settings {
            SettingsView()
                .environmentObject(container)
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
        nsView.configureWindowIfNeeded()
    }
}

@MainActor
private final class WindowAccessorView: NSView {
    var isSetup = false
    private var lastConfiguredForSetup: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfNeeded()
    }

    func configureWindowIfNeeded() {
        guard let window else { return }
        let needsReconfigure = lastConfiguredForSetup != isSetup
        lastConfiguredForSetup = isSetup

        if isSetup {
            if needsReconfigure {
                window.styleMask = [.borderless]
                window.isMovableByWindowBackground = true
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
            }
            window.setContentSize(NSSize(width: 480, height: 340))
            window.center()
        } else if needsReconfigure {
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.isMovableByWindowBackground = false
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()
        }
    }
}

enum SceneID: String {
    case main
    case issue
    case newIssue
}
