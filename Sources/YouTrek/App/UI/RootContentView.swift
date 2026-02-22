import SwiftUI

struct RootContentView: View {
    @EnvironmentObject var container: AppContainer
    @ObservedObject var appState: AppState
    @State var searchQuery: String = ""
    @State var isInspectorVisible: Bool = true
    @AppStorage("issueList.showAssigneeColumn") var showAssigneeColumn: Bool = false
    #if DEBUG
    @AppStorage(AppDebugSettings.Keys.simulateSlowResponses) var simulateSlowResponses: Bool = false
    @AppStorage(AppDebugSettings.Keys.showNetworkFooter) var showNetworkFooter: Bool = false
    @AppStorage(AppDebugSettings.Keys.disableSyncing) var disableSyncing: Bool = false
    @AppStorage(AppDebugSettings.Keys.showBoardDiagnostics) var showBoardDiagnostics: Bool = false
    @AppStorage(AppDebugSettings.Keys.showIssueListDiagnostics) var showIssueListDiagnostics: Bool = false
    #else
    let showBoardDiagnostics: Bool = false
    let showIssueListDiagnostics: Bool = false
    #endif

    init(appState: AppState) {
        self.appState = appState
    }
}
