import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private let launchUptime: TimeInterval
    @Published private(set) var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var selectedSidebarItem: SidebarItem?
    @Published private(set) var sidebarSections: [SidebarSection] = []
    @Published var selectedIssue: IssueSummary?
    @Published var selectedIssueIDs: Set<IssueSummary.ID> = []
    @Published private(set) var issues: [IssueSummary]
    @Published private(set) var issueSeenUpdates: [IssueSummary.ID: Date] = [:]
    @Published private(set) var issueDetails: [IssueSummary.ID: IssueDetail] = [:]
    @Published private(set) var issueDetailLoadingIDs: Set<IssueSummary.ID> = []
    @Published private var searchQuery: String = ""
    @Published private(set) var isInspectorVisible: Bool = true
    @Published private(set) var isSidebarVisible: Bool = true
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var syncStatusMessage: String? = nil
    @Published private(set) var isLoadingIssues: Bool = false
    @Published private(set) var hasCompletedIssueSync: Bool = false
    @Published private(set) var hasCompletedBoardSync: Bool = false
    @Published private(set) var hasCompletedSavedSearchSync: Bool = false
    @Published private(set) var currentUserDisplayName: String? = nil
    @Published private(set) var boardSyncTimestamps: [String: Date] = [:]
    @Published private var boardSprintFilters: [String: BoardSprintFilter] = [:]
    @Published var activeConflict: ConflictNotice?
    private var didLogIssueListRendered = false

    init(issues: [IssueSummary] = []) {
        self.launchUptime = ProcessInfo.processInfo.systemUptime
        self.issues = issues
    }

    func replaceIssues(with newIssues: [IssueSummary]) {
        guard issues != newIssues else { return }
        issues = newIssues
        if let first = newIssues.first {
            selectedIssue = first
            selectedIssueIDs = [first.id]
        } else {
            selectedIssueIDs.removeAll()
        }
    }

    func updateIssue(_ issue: IssueSummary) {
        if let index = issues.firstIndex(where: { $0.id == issue.id }) {
            issues[index] = issue
        } else {
            issues.append(issue)
        }
        if selectedIssue?.id == issue.id {
            selectedIssue = issue
        }
    }

    func updateIssueSeenUpdates(_ updates: [IssueSummary.ID: Date]) {
        issueSeenUpdates.merge(updates) { _, new in new }
    }

    func markIssueSeen(_ issue: IssueSummary) {
        issueSeenUpdates[issue.id] = issue.updatedAt
    }

    func resetIssueSeenUpdates() {
        issueSeenUpdates = [:]
    }

    func issueDetail(for issue: IssueSummary) -> IssueDetail? {
        issueDetails[issue.id]
    }

    func isIssueDetailLoading(_ id: IssueSummary.ID) -> Bool {
        issueDetailLoadingIDs.contains(id)
    }

    func updateIssueDetail(_ detail: IssueDetail) {
        issueDetails[detail.id] = detail
    }

    func recordComment(_ comment: IssueComment, for issue: IssueSummary) {
        if let detail = issueDetails[issue.id] {
            issueDetails[issue.id] = detail.appending(comment: comment)
        }
        let updatedAt = max(issue.updatedAt, comment.createdAt)
        updateIssue(issue.updating(updatedAt: updatedAt))
    }

    func setIssueDetailLoading(_ id: IssueSummary.ID, isLoading: Bool) {
        if isLoading {
            issueDetailLoadingIDs.insert(id)
        } else {
            issueDetailLoadingIDs.remove(id)
        }
    }

    func resetIssueDetails() {
        issueDetails = [:]
        issueDetailLoadingIDs = []
    }

    func isIssueUnread(_ issue: IssueSummary) -> Bool {
        guard let seenAt = issueSeenUpdates[issue.id] else { return true }
        return issue.updatedAt > seenAt
    }

    func updateSidebar(sections: [SidebarSection], preferredSelectionID: SidebarItem.ID?) {
        sidebarSections = sections
        let items = sections.flatMap(\.items)

        if let current = selectedSidebarItem,
           let updated = items.first(where: { $0.id == current.id }) {
            selectedSidebarItem = updated
            return
        }

        if let preferredSelectionID,
           let preferred = items.first(where: { $0.id == preferredSelectionID }) {
            selectedSidebarItem = preferred
        } else {
            selectedSidebarItem = items.first
        }
    }

    func filteredIssues(searchQuery: String) -> [IssueSummary] {
        guard !searchQuery.isEmpty else { return issues }
        let lowercased = searchQuery.lowercased()
        return issues.filter { issue in
            issue.title.lowercased().contains(lowercased) ||
            issue.readableID.lowercased().contains(lowercased) ||
            issue.projectName.lowercased().contains(lowercased)
        }
    }

    func updateSearch(query: String) {
        searchQuery = query
    }

    func toggleSidebarVisibility(source: String = "menu") {
        let shouldShow = columnVisibility != .all
        updateColumnVisibility(shouldShow ? .all : .doubleColumn, source: source)
    }

    func updateColumnVisibility(_ newValue: NavigationSplitViewVisibility, source: String) {
        guard columnVisibility != newValue else { return }
        let oldValue = columnVisibility
        columnVisibility = newValue
        isSidebarVisible = newValue == .all
        logSidebarVisibilityChange(from: oldValue, to: newValue, source: source)
    }

    func setInspectorVisible(_ isVisible: Bool) {
        isInspectorVisible = isVisible
    }

    func updateSyncActivity(isSyncing: Bool, label: String?) {
        self.isSyncing = isSyncing
        self.syncStatusMessage = label
    }

    func recordIssueSyncCompleted() {
        hasCompletedIssueSync = true
    }

    func recordBoardListSyncCompleted() {
        hasCompletedBoardSync = true
    }

    func recordSavedSearchSyncCompleted() {
        hasCompletedSavedSearchSync = true
    }

    func resetBoardSyncState() {
        boardSyncTimestamps = [:]
        boardSprintFilters = [:]
    }

    func resetInitialSyncState() {
        hasCompletedIssueSync = false
        hasCompletedBoardSync = false
        hasCompletedSavedSearchSync = false
    }

    func setCurrentUserDisplayName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentUserDisplayName = trimmed?.isEmpty == false ? trimmed : nil
    }

    var hasCompletedInitialSync: Bool {
        hasCompletedIssueSync && hasCompletedBoardSync
    }

    var initialSyncProgress: Double {
        let total: Double = 3
        let completed: Double = (hasCompletedIssueSync ? 1 : 0)
            + (hasCompletedBoardSync ? 1 : 0)
            + (hasCompletedSavedSearchSync ? 1 : 0)
        return completed / total
    }

    func recordBoardSync(boardID: String, at date: Date = Date()) {
        boardSyncTimestamps[boardID] = date
    }

    func sprintFilter(for board: IssueBoard) -> BoardSprintFilter {
        if let existing = boardSprintFilters[board.id] {
            let resolved = board.resolveSprintFilter(existing)
            if resolved != existing {
                boardSprintFilters[board.id] = resolved
            }
            return resolved
        }

        let fallback = board.defaultSprintFilter
        boardSprintFilters[board.id] = fallback
        return fallback
    }

    func updateSprintFilter(_ filter: BoardSprintFilter, for boardID: String) {
        boardSprintFilters[boardID] = filter
    }

    func boardSyncStatus(for item: SidebarItem, now: Date = Date()) -> String? {
        guard let boardID = item.boardID else { return nil }
        return boardSyncStatus(boardID: boardID, now: now)
    }

    func boardSyncStatus(boardID: String, now: Date = Date()) -> String {
        guard let date = boardSyncTimestamps[boardID] else { return "never" }
        return relativeTimeString(since: date, now: now)
    }

    func setIssuesLoading(_ isLoading: Bool) {
        isLoadingIssues = isLoading
    }

    func presentConflict(_ conflict: ConflictNotice) {
        activeConflict = conflict
    }

    func recordIssueListRendered(issueCount: Int) {
        guard issueCount > 0, !didLogIssueListRendered else { return }
        didLogIssueListRendered = true
        let elapsed = ProcessInfo.processInfo.systemUptime - launchUptime
        let formatted = String(format: "%.2f", elapsed)
        LoggingService.general.info(
            "Startup: issue list rendered in \(formatted, privacy: .public)s (issues: \(issueCount, privacy: .public))"
        )
    }
}

private extension AppState {
    func logSidebarVisibilityChange(
        from oldValue: NavigationSplitViewVisibility,
        to newValue: NavigationSplitViewVisibility,
        source: String
    ) {
        let oldDescription = columnVisibilityDescription(oldValue)
        let newDescription = columnVisibilityDescription(newValue)
        LoggingService.general.info(
            "Sidebar visibility changed: \(oldDescription, privacy: .public) -> \(newDescription, privacy: .public) source=\(source, privacy: .public)"
        )
        #if DEBUG
        let stack = Thread.callStackSymbols.prefix(8).joined(separator: " | ")
        LoggingService.general.debug("Sidebar visibility stack: \(stack, privacy: .public)")
        #endif
    }

    func columnVisibilityDescription(_ value: NavigationSplitViewVisibility) -> String {
        String(describing: value)
    }

    func relativeTimeString(since date: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        if elapsed < 60 {
            return "just now"
        }
        let minutes = elapsed / 60
        if minutes < 60 {
            return "\(minutes) min ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours) hr ago"
        }
        let days = hours / 24
        return "\(days) d ago"
    }
}

struct ConflictNotice: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let message: String
    let localChanges: String

    init(id: UUID = UUID(), title: String, message: String, localChanges: String) {
        self.id = id
        self.title = title
        self.message = message
        self.localChanges = localChanges
    }
}

enum AppStatePlaceholder {
    static func sampleIssues() -> [IssueSummary] {
        let people = [
            Person(displayName: "Taylor Atkins"),
            Person(displayName: "Morgan Chan"),
            Person(displayName: "Ola Svensson"),
            Person(displayName: "Priya Desai")
        ]

        return [
            IssueSummary(
                readableID: "YT-101",
                title: "Set up Apollo + SQLite normalized cache",
                projectName: "YouTrek",
                updatedAt: Date().addingTimeInterval(-3600),
                assignee: people[0],
                reporter: people[1],
                priority: .high,
                status: .inProgress,
                tags: ["sync", "networking"]
            ),
            IssueSummary(
                readableID: "YT-96",
                title: "Implement OAuth login via AppAuth",
                projectName: "YouTrek",
                updatedAt: Date().addingTimeInterval(-7200),
                assignee: people[1],
                reporter: people[2],
                priority: .critical,
                status: .blocked,
                tags: ["auth"]
            ),
            IssueSummary(
                readableID: "YT-87",
                title: "Design command palette commands",
                projectName: "YouTrek",
                updatedAt: Date().addingTimeInterval(-10800),
                assignee: people[2],
                reporter: people[3],
                priority: .normal,
                status: .inReview,
                tags: ["ux"]
            ),
            IssueSummary(
                readableID: "YT-75",
                title: "Persist split view column widths",
                projectName: "YouTrek",
                updatedAt: Date().addingTimeInterval(-86400),
                assignee: people[3],
                reporter: people[0],
                priority: .low,
                status: .done,
                tags: ["macOS", "polish"]
            )
        ]
    }
}
