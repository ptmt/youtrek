import AppKit
import SwiftUI

extension RootContentView {
    var selectedIssues: [IssueSummary] {
        appState.issues.filter { appState.selectedIssueIDs.contains($0.id) }
    }

    var hasUnreadIssues: Bool {
        appState.issues.contains { appState.isIssueUnread($0) }
    }

    var showsDraftsInList: Bool {
        guard let selection = appState.selectedSidebarItem else { return false }
        return selectionShowsDrafts(selection)
    }

    var visibleIssues: [IssueSummary] {
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

    func selectionShowsDrafts(_ selection: SidebarItem) -> Bool {
        selection.isInbox || selection.title.caseInsensitiveCompare("Inbox") == .orderedSame
    }

    func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSSplitViewController.toggleSidebar(_:)),
            with: nil
        )
    }

    func promptForTodoListName(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let textField = NSTextField(string: defaultValue)
        textField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = textField
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let resolved = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.isEmpty ? nil : resolved
    }

    func confirmDeleteTodoList(named name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Todo List"
        alert.informativeText = "Delete \"\(name)\" permanently?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
