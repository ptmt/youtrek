import Foundation
import SwiftUI

@MainActor
final class TodoListEditorViewModel: ObservableObject {
    @Published var markdown: String = ""
    @Published private(set) var title: String
    @Published private(set) var issueStyles: [String: TodoIssueInlineStyle] = [:]

    let listID: UUID

    private let markdownStore: TodoListMarkdownStoring
    private let issueLinkHandler: TodoIssueLinkHandling
    private let todoListManager: (any TodoListManaging)?
    private let issueIDParser: any TodoIssueIDParsing
    private let saveDebounceNanoseconds: UInt64
    private var saveTask: Task<Void, Never>?
    private var styleTask: Task<Void, Never>?
    private var hasLoaded = false
    private var isHydrating = false

    init(
        listID: UUID,
        title: String,
        markdownStore: TodoListMarkdownStoring,
        issueLinkHandler: TodoIssueLinkHandling,
        todoListManager: (any TodoListManaging)? = nil,
        issueIDParser: any TodoIssueIDParsing = RegexTodoIssueIDParser(),
        saveDebounceNanoseconds: UInt64 = 600_000_000
    ) {
        self.listID = listID
        self.title = title
        self.markdownStore = markdownStore
        self.issueLinkHandler = issueLinkHandler
        self.todoListManager = todoListManager
        self.issueIDParser = issueIDParser
        self.saveDebounceNanoseconds = saveDebounceNanoseconds
    }

    func load() async {
        cancelPendingWork()
        isHydrating = true
        let loaded = await markdownStore.loadTodoListMarkdown(id: listID)
        if loaded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            markdown = "# \(title)\n\n"
        } else {
            markdown = loaded
        }
        hasLoaded = true
        isHydrating = false
        scheduleStyleRefresh(for: markdown, debounce: false)
    }

    func handleMarkdownChange(_ newValue: String) {
        guard hasLoaded, !isHydrating else { return }
        scheduleSave(for: newValue)
        scheduleStyleRefresh(for: newValue, debounce: true)
    }

    func openIssue(_ issueID: String) async {
        await issueLinkHandler.openIssueFromTodoLink(issueID)
    }

    func setIssueClosed(fromChecklist issueID: String, isClosed: Bool) async {
        await issueLinkHandler.setIssueClosedFromTodoLink(issueID, isClosed: isClosed)
    }

    func saveImageAttachment(data: Data, preferredFileExtension: String) async -> String? {
        await markdownStore.saveTodoListImageAttachment(
            id: listID,
            data: data,
            preferredFileExtension: preferredFileExtension
        )
    }

    func loadImageAttachment(reference: String) async -> Data? {
        await markdownStore.loadTodoListImageAttachment(id: listID, reference: reference)
    }

    func refreshIssueStylesNow() {
        scheduleStyleRefresh(for: markdown, debounce: false)
    }

    func rename(to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await todoListManager?.renameTodoList(id: listID, name: trimmed)
        title = trimmed
        let updated = replacingTopLevelHeading(in: markdown, with: trimmed)
        if updated != markdown {
            markdown = updated
        }
    }

    func cleanup() async {
        cancelPendingWork()
        guard hasLoaded else { return }
        await markdownStore.saveTodoListMarkdown(id: listID, markdown: markdown)
    }

    private func cancelPendingWork() {
        saveTask?.cancel()
        saveTask = nil
        styleTask?.cancel()
        styleTask = nil
    }

    private func scheduleSave(for markdown: String) {
        saveTask?.cancel()
        let listID = self.listID
        let debounce = saveDebounceNanoseconds
        saveTask = Task { [weak self] in
            guard let self else { return }
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: debounce)
            }
            if Task.isCancelled { return }
            await self.markdownStore.saveTodoListMarkdown(id: listID, markdown: markdown)
        }
    }

    private func scheduleStyleRefresh(for markdown: String, debounce: Bool) {
        styleTask?.cancel()
        let issueIDs = issueIDParser.issueIDs(in: markdown)
        if issueIDs.isEmpty {
            issueStyles = [:]
            return
        }
        styleTask = Task { [weak self] in
            guard let self else { return }
            if debounce {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if Task.isCancelled { return }
            let styles = await self.issueLinkHandler.loadTodoIssueStyles(readableIDs: issueIDs)
            if Task.isCancelled { return }
            self.issueStyles = styles
        }
    }

    private func replacingTopLevelHeading(in markdown: String, with newTitle: String) -> String {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if trimmed.hasPrefix("#") {
                lines[index] = "# \(newTitle)"
                return lines.joined(separator: "\n")
            }
            break
        }
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "# \(newTitle)\n\n"
        }
        return "# \(newTitle)\n\n\(markdown)"
    }
}
