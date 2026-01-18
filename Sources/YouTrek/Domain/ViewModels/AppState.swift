import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var selectedSidebarItem: SidebarItem?
    @Published private(set) var sidebarSections: [SidebarSection] = []
    @Published var selectedIssue: IssueSummary?
    @Published private(set) var issues: [IssueSummary]
    @Published private var searchQuery: String = ""
    @Published private(set) var isInspectorVisible: Bool = true
    @Published private(set) var isSidebarVisible: Bool = true
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var syncStatusMessage: String? = nil
    @Published private(set) var isLoadingIssues: Bool = false
    @Published var activeConflict: ConflictNotice?

    init(issues: [IssueSummary] = []) {
        self.issues = issues
    }

    func replaceIssues(with newIssues: [IssueSummary]) {
        issues = newIssues
        if let first = newIssues.first {
            selectedIssue = first
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

    func updateSidebar(sections: [SidebarSection], preferredSelectionID: SidebarItem.ID?) {
        sidebarSections = sections
        let items = sections.flatMap(\.items)

        if let current = selectedSidebarItem, items.contains(current) {
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

    func toggleSidebarVisibility() {
        isSidebarVisible.toggle()
        columnVisibility = isSidebarVisible ? .all : .detailOnly
    }

    func setInspectorVisible(_ isVisible: Bool) {
        isInspectorVisible = isVisible
    }

    func updateSyncActivity(isSyncing: Bool, label: String?) {
        self.isSyncing = isSyncing
        self.syncStatusMessage = label
    }

    func setIssuesLoading(_ isLoading: Bool) {
        isLoadingIssues = isLoading
    }

    func presentConflict(_ conflict: ConflictNotice) {
        activeConflict = conflict
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
                priority: .low,
                status: .done,
                tags: ["macOS", "polish"]
            )
        ]
    }
}
