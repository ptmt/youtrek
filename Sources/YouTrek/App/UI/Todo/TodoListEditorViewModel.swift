import AppKit
import Foundation
import SwiftUI

@MainActor
protocol TodoListMarkdownStoring: AnyObject {
    func loadTodoListMarkdown(id: UUID) async -> String
    func saveTodoListMarkdown(id: UUID, markdown: String) async
}

@MainActor
protocol TodoIssueLinkHandling: AnyObject {
    func loadTodoIssueStyles(readableIDs: Set<String>) async -> [String: TodoIssueInlineStyle]
    func openIssueFromTodoLink(_ readableID: String) async
}

@MainActor
protocol TodoListManaging: AnyObject {
    func renameTodoList(id: UUID, name: String) async
}

protocol TodoURLOpening {
    func openURL(_ url: URL)
}

struct WorkspaceTodoURLOpener: TodoURLOpening {
    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

protocol TodoIssueIDParsing {
    func issueIDs(in markdown: String) -> Set<String>
}

struct RegexTodoIssueIDParser: TodoIssueIDParsing {
    private static let issueIDPattern = #"\b([A-Z][A-Z0-9]+-\d+)\b"#
    private let regex: NSRegularExpression?

    init() {
        regex = try? NSRegularExpression(pattern: Self.issueIDPattern)
    }

    func issueIDs(in markdown: String) -> Set<String> {
        guard let regex else { return [] }
        let nsText = markdown as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: markdown, range: range)
        return Set(matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let raw = nsText.substring(with: match.range(at: 1))
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return normalized.isEmpty ? nil : normalized
        })
    }
}

struct TodoChecklistLineMatch: Equatable, Sendable {
    let lineIndex: Int
    let issueID: String?
    let isChecked: Bool
}

struct RegexTodoChecklistDetector {
    private static let issueIDPattern = #"\b([A-Z][A-Z0-9]+-\d+)\b"#
    private static let listItemPattern = #"^\s*[-*+]\s+"#
    private static let markdownChecklistPattern = #"^\s*[-*+]\s+\[([ xX])\](?:\s+|$)"#

    private let issueIDRegex: NSRegularExpression?
    private let listItemRegex: NSRegularExpression?
    private let markdownChecklistRegex: NSRegularExpression?

    init() {
        issueIDRegex = try? NSRegularExpression(pattern: Self.issueIDPattern)
        listItemRegex = try? NSRegularExpression(pattern: Self.listItemPattern)
        markdownChecklistRegex = try? NSRegularExpression(pattern: Self.markdownChecklistPattern)
    }

    func checklistLines(in markdown: String) -> [TodoChecklistLineMatch] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.enumerated().compactMap { index, line in
            checklistMatch(in: line, lineIndex: index)
        }
    }

    private func checklistMatch(in line: String, lineIndex: Int) -> TodoChecklistLineMatch? {
        let nsLine = line as NSString
        let lineRange = NSRange(location: 0, length: nsLine.length)

        if
            let markdownChecklistRegex,
            let match = markdownChecklistRegex.firstMatch(in: line, range: lineRange),
            match.numberOfRanges > 1,
            match.range(at: 1).location != NSNotFound
        {
            let rawState = nsLine.substring(with: match.range(at: 1))
            let isChecked = rawState == "x" || rawState == "X"
            return TodoChecklistLineMatch(lineIndex: lineIndex, issueID: nil, isChecked: isChecked)
        }

        guard
            let listItemRegex,
            listItemRegex.firstMatch(in: line, range: lineRange) != nil,
            let issueIDRegex
        else {
            return nil
        }

        var issueIDs: [String] = []
        issueIDRegex.enumerateMatches(in: line, range: lineRange) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            let issueRange = match.range(at: 1)
            guard issueRange.location != NSNotFound else { return }
            issueIDs.append(nsLine.substring(with: issueRange).uppercased())
        }

        guard issueIDs.count == 1, let issueID = issueIDs.first else { return nil }
        return TodoChecklistLineMatch(lineIndex: lineIndex, issueID: issueID, isChecked: false)
    }
}

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
