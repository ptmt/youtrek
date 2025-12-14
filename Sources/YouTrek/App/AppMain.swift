import SwiftUI

@main
struct YouTrekApp: App {
    @StateObject private var container = AppContainer.live

    var body: some Scene {
        WindowGroup(id: SceneID.main.rawValue) {
            RootView()
                .environmentObject(container)
        }
        .commands { AppMenus(container: container) }
        .windowStyle(.automatic)
        .defaultSize(width: 1280, height: 800)

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

        WindowGroup("Connect to YouTrack", id: SceneID.setup.rawValue) {
            SetupWindow()
                .environmentObject(container)
        }
        .defaultSize(width: 560, height: 360)

        Settings {
            SettingsView()
                .environmentObject(container)
        }
    }
}

enum SceneID: String {
    case main
    case issue
    case newIssue
    case setup
}
