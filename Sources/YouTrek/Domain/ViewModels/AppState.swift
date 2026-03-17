import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private let launchUptime: TimeInterval
    private let sidebarStabilityInterval: TimeInterval = 1.0
    @Published private(set) var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var selectedSidebarItem: SidebarItem?
    @Published private(set) var sidebarSections: [SidebarSection] = []
    @Published var selectedIssue: IssueSummary?
    @Published var selectedIssueIDs: Set<IssueSummary.ID> = []
    @Published private(set) var issues: [IssueSummary]
    @Published private(set) var draftRecords: [IssueDraftRecord] = []
    @Published var selectedDraftID: UUID?
    @Published private(set) var issueSeenUpdates: [IssueSummary.ID: Date] = [:]
    @Published private(set) var issueDetails: [IssueSummary.ID: IssueDetail] = [:]
    @Published private(set) var issueDetailLoadingIDs: Set<IssueSummary.ID> = []
    @Published private(set) var inboxFieldUsage: [String: [String: Int]] = [:]
    @Published private var searchQuery: String = ""
    @Published private(set) var isInspectorVisible: Bool = true
    @Published private(set) var isSidebarVisible: Bool = true
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var syncStatusMessage: String? = nil
    @Published private(set) var showSyncComplete: Bool = false
    @Published var activeToast: ToastNotice?
    @Published private(set) var isLoadingIssues: Bool = false
    @Published private(set) var hasCompletedIssueSync: Bool = false
    @Published private(set) var hasCompletedBoardSync: Bool = false
    @Published private(set) var hasCompletedSavedSearchSync: Bool = false
    @Published private(set) var currentUserDisplayName: String? = nil
    @Published private(set) var currentUserLogin: String? = nil
    @Published private(set) var currentUserID: String? = nil
    @Published private(set) var boardSyncTimestamps: [String: Date] = [:]
    @Published private(set) var boardDataSourceEvents: [String: [BoardDataSourceEvent]] = [:]
    @Published private(set) var issueListDataSourceEvents: [String: [IssueListDataSourceEvent]] = [:]
    @Published private var boardSprintFilters: [String: BoardSprintFilter] = [:]
    @Published var activeConflict: ConflictNotice?
    @Published var activeNewIssueDialog: NewIssueDialogState?
    @Published var activeCommandPalette: CommandPaletteState?
    @Published var subIssueRefresh: SubIssueRefresh?
    @Published var issueDetailRefresh: IssueDetailRefresh?
    private var didLogIssueListRendered = false
    private let boardDataSourceEventLimit = 60
    private let issueListDataSourceEventLimit = 60
    private let syncCompleteRevealDelay: Duration
    private let syncCompleteVisibleDuration: Duration

    init(
        issues: [IssueSummary] = [],
        syncCompleteRevealDelay: Duration = .milliseconds(350),
        syncCompleteVisibleDuration: Duration = .seconds(5)
    ) {
        self.launchUptime = ProcessInfo.processInfo.systemUptime
        self.issues = issues
        self.syncCompleteRevealDelay = syncCompleteRevealDelay
        self.syncCompleteVisibleDuration = syncCompleteVisibleDuration
    }

    func replaceIssues(with newIssues: [IssueSummary]) {
        guard issues != newIssues else { return }
        issues = newIssues
        if selectedIssue?.isDraft == true {
            return
        }
        if let first = newIssues.first {
            selectedIssue = first
            selectedIssueIDs = [first.id]
        } else {
            selectedIssueIDs.removeAll()
        }
    }

    func setDrafts(_ drafts: [IssueDraftRecord]) {
        draftRecords = drafts.sorted { $0.updatedAt > $1.updatedAt }
    }

    func addDraft(_ record: IssueDraftRecord) {
        draftRecords.append(record)
        draftRecords.sort { $0.updatedAt > $1.updatedAt }
    }

    func updateDraft(_ record: IssueDraftRecord) {
        if let index = draftRecords.firstIndex(where: { $0.id == record.id }) {
            draftRecords[index] = record
        } else {
            draftRecords.append(record)
        }
        draftRecords.sort { $0.updatedAt > $1.updatedAt }
    }

    func removeDraft(id: UUID) {
        draftRecords.removeAll { $0.id == id }
        if selectedDraftID == id {
            selectedDraftID = nil
        }
        selectedIssueIDs.remove(id)
        if selectedIssue?.draftID == id {
            selectedIssue = nil
        }
    }

    func draftRecord(id: UUID) -> IssueDraftRecord? {
        draftRecords.first(where: { $0.id == id })
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

    func markIssuesSeen(_ issues: [IssueSummary]) {
        guard !issues.isEmpty else { return }
        var updates: [IssueSummary.ID: Date] = [:]
        for issue in issues {
            updates[issue.id] = issue.updatedAt
        }
        issueSeenUpdates.merge(updates) { _, new in new }
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

    func appendAttachments(_ attachments: [IssueAttachment], to issueID: IssueSummary.ID) {
        guard !attachments.isEmpty, let detail = issueDetails[issueID] else { return }
        issueDetails[issueID] = detail.appending(attachments: attachments)
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

    func updateInboxFieldUsage(from issues: [IssueSummary]) {
        inboxFieldUsage = Self.buildInboxFieldUsage(from: issues)
    }

    func inboxFieldUsageScore(for fieldName: String) -> Int {
        let normalized = Self.normalizedFieldName(fieldName)
        guard let values = inboxFieldUsage[normalized] else { return 0 }
        return values.values.reduce(0, +)
    }

    func inboxFieldUsageCounts(for fieldName: String) -> [String: Int] {
        let normalized = Self.normalizedFieldName(fieldName)
        return inboxFieldUsage[normalized] ?? [:]
    }

    func isIssueUnread(_ issue: IssueSummary) -> Bool {
        guard let seenAt = issueSeenUpdates[issue.id] else { return true }
        return issue.updatedAt > seenAt
    }

    func updateSidebar(
        sections: [SidebarSection],
        preferredSelectionID: SidebarItem.ID?,
        fallbackToFirstItem: Bool = true
    ) {
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
        } else if fallbackToFirstItem {
            selectedSidebarItem = items.first
        } else {
            selectedSidebarItem = nil
        }
    }

    func filteredIssues(_ issues: [IssueSummary], searchQuery: String) -> [IssueSummary] {
        let parsed = parseSearchQuery(searchQuery)
        var filtered = issues
        if !parsed.statusFilters.isEmpty {
            let statusKeys = Set(parsed.statusFilters.map(Self.normalizedStatusKey))
            filtered = filtered.filter { issue in
                let displayKey = Self.normalizedStatusKey(issue.status.displayName)
                let rawKey = Self.normalizedStatusKey(issue.status.rawValue)
                return statusKeys.contains(displayKey) || statusKeys.contains(rawKey)
            }
        }

        let trimmed = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return filtered }
        let lowercased = trimmed.lowercased()
        return filtered.filter { issue in
            issue.title.lowercased().contains(lowercased) ||
            issue.readableID.lowercased().contains(lowercased) ||
            issue.projectName.lowercased().contains(lowercased)
        }
    }

    func filteredIssues(searchQuery: String) -> [IssueSummary] {
        filteredIssues(issues, searchQuery: searchQuery)
    }

    func updateSearch(query: String) {
        searchQuery = query
    }

    func showToast(_ message: String, issueToOpen: IssueSummary? = nil) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            activeToast = ToastNotice(message: trimmed, issueToOpen: issueToOpen)
        }
    }

    func dismissToast() {
        withAnimation(.easeIn(duration: 0.2)) {
            activeToast = nil
        }
    }

    private func parseSearchQuery(_ query: String) -> (text: String, statusFilters: [String]) {
        let pattern = #"(?i)\b(status|state)\s*:\s*(\"([^\"]+)\"|'([^']+)'|([^\s]+))"#
        let regex = try? NSRegularExpression(pattern: pattern)
        guard let regex else {
            return (query, [])
        }

        let range = NSRange(query.startIndex..., in: query)
        let matches = regex.matches(in: query, range: range)
        var filters: [String] = []
        for match in matches {
            let captureRanges = [3, 4, 5]
            for index in captureRanges {
                let captureRange = match.range(at: index)
                if captureRange.location != NSNotFound,
                   let range = Range(captureRange, in: query) {
                    let raw = query[range]
                    let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    filters.append(contentsOf: parts.filter { !$0.isEmpty })
                    break
                }
            }
        }

        let stripped = regex.stringByReplacingMatches(in: query, range: range, withTemplate: "")
        return (stripped, filters)
    }

    private static func normalizedStatusKey(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    func toggleSidebarVisibility(source: String = "menu") {
        let shouldShow = columnVisibility != .all
        updateColumnVisibility(shouldShow ? .all : .doubleColumn, source: source)
    }

    func updateColumnVisibility(_ newValue: NavigationSplitViewVisibility, source: String) {
        if source == "NavigationSplitView",
           shouldIgnoreInitialSidebarCollapse(newValue) {
            return
        }
        guard columnVisibility != newValue else { return }
        let oldValue = columnVisibility
        columnVisibility = newValue
        isSidebarVisible = newValue == .all
        logSidebarVisibilityChange(from: oldValue, to: newValue, source: source)
    }

    func setInspectorVisible(_ isVisible: Bool) {
        isInspectorVisible = isVisible
    }

    private var syncCompleteRevealTask: Task<Void, Never>?
    private var syncCompleteHideTask: Task<Void, Never>?

    func updateSyncActivity(isSyncing: Bool, label: String?) {
        let wasSyncing = self.isSyncing
        self.isSyncing = isSyncing
        self.syncStatusMessage = label

        if wasSyncing && !isSyncing {
            syncCompleteRevealTask?.cancel()
            syncCompleteHideTask?.cancel()
            showSyncComplete = false
            syncCompleteRevealTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: self.syncCompleteRevealDelay)
                guard !Task.isCancelled, !self.isSyncing else { return }
                self.showSyncComplete = true
                self.scheduleSyncCompleteHide()
            }
        } else if isSyncing {
            syncCompleteRevealTask?.cancel()
            syncCompleteHideTask?.cancel()
            showSyncComplete = false
        }
    }

    private func scheduleSyncCompleteHide() {
        syncCompleteHideTask?.cancel()
        syncCompleteHideTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.syncCompleteVisibleDuration)
            guard !Task.isCancelled else { return }
            self.showSyncComplete = false
        }
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

    func recordSubIssueLink(parentReadableID: String) {
        let trimmed = parentReadableID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        subIssueRefresh = SubIssueRefresh(parentReadableID: trimmed)
    }

    func recordIssueDetailRefresh(readableID: String) {
        let trimmed = readableID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        issueDetailRefresh = IssueDetailRefresh(readableID: trimmed)
    }

    func prefillInitialSyncState(issues: Bool, boards: Bool, savedSearches: Bool) {
        hasCompletedIssueSync = issues
        hasCompletedBoardSync = boards
        hasCompletedSavedSearchSync = savedSearches
    }

    func resetBoardSyncState() {
        boardSyncTimestamps = [:]
        boardSprintFilters = [:]
        boardDataSourceEvents = [:]
        issueListDataSourceEvents = [:]
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

    func setCurrentUserProfile(displayName: String?, login: String?, id: String?) {
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLogin = login?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentUserDisplayName = trimmedName?.isEmpty == false ? trimmedName : nil
        currentUserLogin = trimmedLogin?.isEmpty == false ? trimmedLogin : nil
        currentUserID = trimmedID?.isEmpty == false ? trimmedID : nil
    }

    var hasCompletedInitialSync: Bool {
        hasCompletedIssueSync && hasCompletedBoardSync && hasCompletedSavedSearchSync
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

    func recordBoardDataSourceEvent(boardID: String, message: String, at date: Date = Date()) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var events = boardDataSourceEvents[boardID, default: []]
        events.append(BoardDataSourceEvent(timestamp: date, message: trimmed))
        if events.count > boardDataSourceEventLimit {
            events.removeFirst(events.count - boardDataSourceEventLimit)
        }
        boardDataSourceEvents[boardID] = events
    }

    func boardDataSourceEvents(for boardID: String) -> [BoardDataSourceEvent] {
        boardDataSourceEvents[boardID] ?? []
    }

    func recordIssueListDataSourceEvent(listID: String, message: String, at date: Date = Date()) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var events = issueListDataSourceEvents[listID, default: []]
        events.append(IssueListDataSourceEvent(timestamp: date, message: trimmed))
        if events.count > issueListDataSourceEventLimit {
            events.removeFirst(events.count - issueListDataSourceEventLimit)
        }
        issueListDataSourceEvents[listID] = events
    }

    func issueListDataSourceEvents(for listID: String) -> [IssueListDataSourceEvent] {
        issueListDataSourceEvents[listID] ?? []
    }

    func sprintFilter(for board: IssueBoard) -> BoardSprintFilter {
        if let existing = boardSprintFilters[board.id] {
            return board.resolveSprintFilter(existing)
        }

        return board.defaultSprintFilter
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

    func presentNewIssueDialog(state: NewIssueDialogState = NewIssueDialogState()) {
        activeNewIssueDialog = state
    }

    func dismissNewIssueDialog() {
        activeNewIssueDialog = nil
    }

    func presentCommandPalette(state: CommandPaletteState = CommandPaletteState()) {
        withAnimation(.easeOut(duration: 0.15)) {
            activeCommandPalette = state
        }
    }

    func dismissCommandPalette() {
        withAnimation(.easeOut(duration: 0.15)) {
            activeCommandPalette = nil
        }
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

struct ToastNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let issueToOpen: IssueSummary?

    var isInteractive: Bool {
        issueToOpen != nil
    }
}

struct SubIssueRefresh: Identifiable, Equatable {
    let id = UUID()
    let parentReadableID: String
}

struct IssueDetailRefresh: Identifiable, Equatable {
    let id = UUID()
    let readableID: String
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

    func shouldIgnoreInitialSidebarCollapse(_ newValue: NavigationSplitViewVisibility) -> Bool {
        guard newValue != .all else { return false }
        if sidebarSections.isEmpty || selectedSidebarItem == nil {
            return true
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - launchUptime
        return elapsed < sidebarStabilityInterval
    }

    static func normalizedFieldName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func buildInboxFieldUsage(from issues: [IssueSummary]) -> [String: [String: Int]] {
        let excludedKeys: Set<String> = ["assignee", "state", "status", "priority"]
        let recent = issues.sorted { $0.updatedAt > $1.updatedAt }.prefix(50)
        var usage: [String: [String: Int]] = [:]
        for issue in recent {
            for (key, values) in issue.customFieldValues {
                let normalizedKey = normalizedFieldName(key)
                guard !normalizedKey.isEmpty, !excludedKeys.contains(normalizedKey) else { continue }
                for value in values {
                    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedValue.isEmpty else { continue }
                    usage[normalizedKey, default: [:]][trimmedValue, default: 0] += 1
                }
            }
        }
        return usage
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

struct NewIssueDialogState: Identifiable, Hashable, Sendable {
    let id: UUID
    var projectID: String?
    var parentIssueReadableID: String?
    var parentIssueTitle: String?
    var queueAsUncommitted: Bool
    var title: String
    var description: String
    var statusOption: IssueFieldOption?
    var priorityOption: IssueFieldOption?
    var assigneeOption: IssueFieldOption?
    var labels: [String]
    var createMore: Bool
    var customFields: [IssueDraftField]
    var attachments: [IssueAttachmentDraft]

    init(
        id: UUID = UUID(),
        projectID: String? = nil,
        parentIssueReadableID: String? = nil,
        parentIssueTitle: String? = nil,
        queueAsUncommitted: Bool = false,
        title: String = "",
        description: String = "",
        statusOption: IssueFieldOption? = nil,
        priorityOption: IssueFieldOption? = nil,
        assigneeOption: IssueFieldOption? = nil,
        labels: [String] = [],
        createMore: Bool = false,
        customFields: [IssueDraftField] = [],
        attachments: [IssueAttachmentDraft] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.parentIssueReadableID = parentIssueReadableID
        self.parentIssueTitle = parentIssueTitle
        self.queueAsUncommitted = queueAsUncommitted
        self.title = title
        self.description = description
        self.statusOption = statusOption
        self.priorityOption = priorityOption
        self.assigneeOption = assigneeOption
        self.labels = labels
        self.createMore = createMore
        self.customFields = customFields
        self.attachments = attachments
    }
}

struct CommandPaletteState: Identifiable, Hashable, Sendable {
    let id: UUID
    var query: String

    init(id: UUID = UUID(), query: String = "") {
        self.id = id
        self.query = query
    }
}

struct BoardDataSourceEvent: Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let message: String

    init(id: UUID = UUID(), timestamp: Date, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
    }
}

struct IssueListDataSourceEvent: Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let message: String

    init(id: UUID = UUID(), timestamp: Date, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
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
