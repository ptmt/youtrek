import SwiftUI

struct RootView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        RootContentView(appState: container.appState)
            .environmentObject(container)
    }
}

private struct RootContentView: View {
    @EnvironmentObject private var container: AppContainer
    @ObservedObject var appState: AppState
    @State private var searchQuery: String = ""
    @State private var isInspectorVisible: Bool = true
    @AppStorage("issueList.showAssigneeColumn") private var showAssigneeColumn: Bool = false
    @AppStorage("issueList.showUpdatedColumn") private var showUpdatedColumn: Bool = true
    @State private var simulateSlowResponses: Bool = AppDebugSettings.simulateSlowResponses
    @State private var showNetworkFooter: Bool = AppDebugSettings.showNetworkFooter
    @State private var disableSyncing: Bool = AppDebugSettings.disableSyncing
    @State private var showBoardDiagnostics: Bool = AppDebugSettings.showBoardDiagnostics
    private var selectedIssues: [IssueSummary] {
        appState.issues.filter { appState.selectedIssueIDs.contains($0.id) }
    }
    private var hasUnreadIssues: Bool {
        appState.issues.contains { appState.isIssueUnread($0) }
    }
    private var showsDraftsInList: Bool {
        guard let selection = appState.selectedSidebarItem else { return false }
        return selectionShowsDrafts(selection)
    }
    private var visibleIssues: [IssueSummary] {
        let baseIssues: [IssueSummary]
        if showsDraftsInList {
            let drafts = appState.draftRecords
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { IssueSummary.draft($0) }
            baseIssues = drafts + appState.issues
        } else {
            baseIssues = appState.issues
        }
        return appState.filteredIssues(baseIssues, searchQuery: searchQuery)
    }

    init(appState: AppState) {
        self.appState = appState
    }

    private func selectionShowsDrafts(_ selection: SidebarItem) -> Bool {
        selection.isInbox || selection.title.caseInsensitiveCompare("Inbox") == .orderedSame
    }

    var body: some View {
        rootSplitView
    }

    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { appState.columnVisibility },
            set: { newValue in
                appState.updateColumnVisibility(newValue, source: "NavigationSplitView")
            }
        )
    }

    private var rootSplitView: some View {
        NavigationSplitView(columnVisibility: columnVisibilityBinding) {
            sidebarContent
        } detail: {
            mainContent
                .toolbar { mainToolbar }
        }
        .inspector(isPresented: $isInspectorVisible) {
            inspectorContent
        }
        .searchable(text: $searchQuery, placement: .toolbar, prompt: Text("Search issues"))
        .navigationSplitViewStyle(.prominentDetail)
        #if DEBUG
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showNetworkFooter {
                NetworkRequestFooterView(monitor: container.networkMonitor)
            }
        }
        #endif
        .task {
            isInspectorVisible = appState.isInspectorVisible
        }
        .onChange(of: simulateSlowResponses) { _, newValue in
            AppDebugSettings.setSimulateSlowResponses(newValue)
        }
        .onChange(of: showNetworkFooter) { _, newValue in
            AppDebugSettings.setShowNetworkFooter(newValue)
        }
        .onChange(of: disableSyncing) { _, newValue in
            AppDebugSettings.setDisableSyncing(newValue)
        }
        .onChange(of: showBoardDiagnostics) { _, newValue in
            AppDebugSettings.setShowBoardDiagnostics(newValue)
        }
        .onChange(of: searchQuery) { _, query in
            appState.updateSearch(query: query)
        }
        .onChange(of: appState.isInspectorVisible) { _, newValue in
            isInspectorVisible = newValue
        }
        .onChange(of: appState.selectedIssue) { _, issue in
            guard let issue else {
                appState.selectedDraftID = nil
                return
            }
            Task { @MainActor in
                if appState.selectedIssueIDs != [issue.id] {
                    appState.selectedIssueIDs = [issue.id]
                }
            }
            if issue.isDraft, let draftID = issue.draftID {
                appState.selectedDraftID = draftID
                if appState.draftRecord(id: draftID) != nil {
                    container.selectDraft(recordID: draftID)
                }
                return
            }
            appState.selectedDraftID = nil
            container.markIssueSeen(issue)
            Task {
                await container.loadIssueDetail(for: issue)
            }
        }
        .onChange(of: appState.selectedSidebarItem) { _, selection in
            guard let selection else { return }
            container.recordSidebarSelection(selection)
            if !selectionShowsDrafts(selection), appState.selectedIssue?.isDraft == true {
                appState.selectedDraftID = nil
                appState.selectedIssue = nil
                appState.selectedIssueIDs.removeAll()
            }
            Task {
                await container.loadIssues(for: selection)
            }
        }
        .sheet(item: $appState.activeConflict) { conflict in
            ConflictResolutionDialog(conflict: conflict)
        }
        .sheet(item: $appState.activeNewIssueDialog) { _ in
            NewIssueDialog(state: newIssueDialogBinding)
        }
    }

    private var newIssueDialogBinding: Binding<NewIssueDialogState> {
        Binding(
            get: { appState.activeNewIssueDialog ?? NewIssueDialogState() },
            set: { appState.activeNewIssueDialog = $0 }
        )
    }

    private var sidebarContent: some View {
        SidebarView(
            sections: appState.sidebarSections,
            selection: $appState.selectedSidebarItem,
            isSyncing: appState.isSyncing,
            syncStatusMessage: appState.syncStatusMessage,
            onDeleteSavedSearch: { savedQueryID in
                Task {
                    await container.deleteSavedSearch(id: savedQueryID)
                }
            },
            onRefreshBoard: { item in
                Task {
                    await container.refreshBoardIssues(for: item)
                }
            },
            onOpenBoardInWeb: { item in
                container.openBoardInWeb(item)
            },
            boardSyncStatus: { item in
                appState.boardSyncStatus(for: item)
            }
        )
    }

    @ViewBuilder
    private var mainContent: some View {
        if let selection = appState.selectedSidebarItem, selection.isBoard {
            BoardContentView(
                appState: appState,
                selection: selection,
                searchQuery: searchQuery,
                showDiagnostics: showBoardDiagnostics
            )
        } else {
            IssueListView(
                issues: visibleIssues,
                selection: $appState.selectedIssue,
                selectedIDs: $appState.selectedIssueIDs,
                showAssigneeColumn: showAssigneeColumn,
                showUpdatedColumn: showUpdatedColumn,
                isLoading: appState.isLoadingIssues,
                hasCompletedSync: appState.hasCompletedIssueSync,
                isIssueUnread: { issue in
                    appState.isIssueUnread(issue)
                },
                onIssuesRendered: { count in
                    appState.recordIssueListRendered(issueCount: count)
                },
                onDeleteDraft: { draftID in
                    container.discardDraft(recordID: draftID)
                }
            )
        }
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            NewIssueToolbar(container: container)
                .frame(maxWidth: 280)
        }

        ToolbarItem(placement: .confirmationAction) {
            Button(action: container.commandPalette.open) {
                Label("Command Palette", systemImage: "command.square")
            }
            .buttonStyle(.accessoryBar)
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                isInspectorVisible.toggle()
                appState.setInspectorVisible(isInspectorVisible)
            } label: {
                Label("Toggle Inspector", systemImage: "sidebar.trailing")
            }
            .buttonStyle(.accessoryBar)
            .help("Show or hide the inspector column")
        }

        ToolbarItem(placement: .automatic) {
            Menu {
                Toggle("Assignee as Column", isOn: $showAssigneeColumn)
                Toggle("Updated as Column", isOn: $showUpdatedColumn)
            } label: {
                Label("Columns", systemImage: "tablecells")
            }
            .help("Show or hide optional columns in the issue list")
        }

        ToolbarItem(placement: .automatic) {
            Button {
                container.markAllIssuesSeen()
            } label: {
                Label("Mark All as Read", systemImage: "checkmark.circle")
            }
            .buttonStyle(.accessoryBar)
            .disabled(!hasUnreadIssues)
            .help("Mark all issues in the current list as read")
        }

        #if DEBUG
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Toggle("Simulate slow responses", isOn: $simulateSlowResponses)
                        Toggle("Show network footer", isOn: $showNetworkFooter)
                        Toggle("Disable syncing", isOn: $disableSyncing)
                        Toggle("Show board diagnostics", isOn: $showBoardDiagnostics)
                        Divider()
                        Button("Clear cache and refetch") {
                            container.clearCacheAndRefetch()
                        }
                    } label: {
                        Label("Developer", systemImage: "wrench.and.screwdriver")
                    }
                }
        #endif
    }

    private var inspectorContent: some View {
        Group {
            if let draftID = appState.selectedDraftID,
               let record = appState.draftRecord(id: draftID) {
                DraftIssueDetailView(record: record)
            } else if appState.selectedDraftID != nil {
                ContentUnavailableView(
                    "Draft not found",
                    systemImage: "square.and.pencil",
                    description: Text("The selected draft is no longer available.")
                )
            } else if selectedIssues.count > 1 {
                MultiIssueSelectionView(issues: selectedIssues)
            } else if let issue = appState.selectedIssue ?? selectedIssues.first {
                IssueDetailView(
                    issue: issue,
                    detail: appState.issueDetail(for: issue),
                    isLoadingDetail: appState.isIssueDetailLoading(issue.id)
                )
            } else {
                ContentUnavailableView(
                    "Select an issue",
                    systemImage: "square.stack.3d.up",
                    description: Text("Choose an issue from the middle column to inspect details.")
                )
            }
        }
        .inspectorColumnWidth(min: 320, ideal: 400, max: 500)
        .background(.ultraThinMaterial)
    }

}

private struct BoardContentView: View {
    @EnvironmentObject private var container: AppContainer
    @ObservedObject var appState: AppState
    let selection: SidebarItem
    let searchQuery: String
    let showDiagnostics: Bool

    var body: some View {
        let board = selection.board ?? IssueBoard(
            id: selection.boardID ?? selection.id,
            name: selection.title,
            isFavorite: true,
            projectNames: []
        )
        let sprintFilter = container.sprintFilter(for: board)
        let diagnosticEvents = appState.boardDataSourceEvents(for: board.id)
        IssueBoardView(
            board: board,
            issues: appState.filteredIssues(searchQuery: searchQuery),
            selection: $appState.selectedIssue,
            isLoading: appState.isLoadingIssues,
            sprintFilter: sprintFilter,
            showDiagnostics: showDiagnostics,
            diagnosticEvents: diagnosticEvents,
            onSelectSprint: { filter in
                Task {
                    await container.updateSprintFilter(filter, for: board)
                }
            }
        )
    }
}

private struct MultiIssueSelectionView: View {
    @EnvironmentObject private var container: AppContainer
    let issues: [IssueSummary]
    @State private var statusOptions: [IssueFieldOption] = []
    @State private var priorityOptions: [IssueFieldOption] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                actionSection
                Divider()
                selectionList
                Spacer(minLength: 24)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(.ultraThinMaterial)
        .task(id: issues.map(\.id)) {
            statusOptions = []
            priorityOptions = []
            statusOptions = await container.loadStatusOptions(for: issues)
            priorityOptions = await container.loadPriorityOptions(for: issues)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Multiple issues selected")
                .font(.title3.weight(.semibold))
            Text(selectionSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bulk actions")
                .font(.headline)
            HStack(spacing: 12) {
                Menu {
                    ForEach(statusMenuOptions, id: \.stableID) { option in
                        Button {
                            applyStatus(option)
                        } label: {
                            let colors = option.badgeColors(fallback: IssueStatus(option: option).badgeColors)
                            menuRow(title: option.displayName, colors: colors)
                        }
                    }
                } label: {
                    Label("Set Status", systemImage: "flag")
                }
                Menu {
                    ForEach(priorityMenuOptions, id: \.stableID) { option in
                        Button {
                            applyPriority(option)
                        } label: {
                            let colors = option.badgeColors(fallback: IssuePriority(option: option).badgeColors)
                            menuRow(title: option.displayName, colors: colors)
                        }
                    }
                } label: {
                    Label("Set Priority", systemImage: "exclamationmark.triangle")
                }
            }
        }
    }

    private var selectionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected issues")
                .font(.headline)
            ForEach(issues) { issue in
                HStack(alignment: .top, spacing: 10) {
                    UserAvatarView(person: issue.assignee, size: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(issue.readableID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(issue.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        HStack(spacing: 8) {
                            Text(issue.projectName)
                                .foregroundStyle(.secondary)
                            Text(issue.assigneeDisplayName)
                                .foregroundStyle(issue.assignee == nil ? .secondary : .primary)
                        }
                        .font(.caption)
                    }
                    Spacer()
                }
                .padding(10)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var selectionSummary: String {
        let issueCount = issues.count
        let projectCount = Set(issues.map(\.projectName)).count
        let peopleCount = Set(issues.compactMap(\.assignee?.id)).count
        return "\(issueCount) \(issueCount == 1 ? "issue" : "issues") in \(projectCount) \(projectCount == 1 ? "project" : "projects") for \(peopleCount) \(peopleCount == 1 ? "person" : "people") selected"
    }

    private var statusMenuOptions: [IssueFieldOption] {
        if statusOptions.isEmpty {
            return IssueStatus.fallbackCases.map { status in
                IssueFieldOption(id: "", name: status.displayName, displayName: status.displayName)
            }
        }
        return statusOptions
    }

    private var priorityMenuOptions: [IssueFieldOption] {
        if priorityOptions.isEmpty {
            return IssuePriority.fallbackCases.map { priority in
                IssueFieldOption(id: "", name: priority.displayName, displayName: priority.displayName)
            }
        }
        return priorityOptions
    }

    private func menuRow(title: String, colors: IssueBadgeColors) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(colors.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(colors.border, lineWidth: 1)
                )
                .frame(width: 18, height: 12)
            Text(title)
                .foregroundStyle(.primary)
        }
    }

    private func applyStatus(_ option: IssueFieldOption) {
        applyPatch(IssuePatch(title: nil, description: nil, status: nil, statusOption: option, priority: nil))
    }

    private func applyPriority(_ option: IssueFieldOption) {
        applyPatch(IssuePatch(title: nil, description: nil, status: nil, priority: nil, priorityOption: option))
    }

    private func applyPatch(_ patch: IssuePatch) {
        let selectedIssues = issues
        Task {
            for issue in selectedIssues {
                var issuePatch = patch
                issuePatch.issueReadableID = issue.readableID
                await container.updateIssue(id: issue.id, patch: issuePatch)
            }
        }
    }
}

struct SyncStatusIndicator: View {
    let label: String?

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(label ?? "Syncing…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }
}
