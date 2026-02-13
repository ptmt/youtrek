import AppKit
import Foundation

@MainActor
protocol TodoListMarkdownStoring: AnyObject {
    func loadTodoListMarkdown(id: UUID) async -> String
    func saveTodoListMarkdown(id: UUID, markdown: String) async
    func saveTodoListImageAttachment(id: UUID, data: Data, preferredFileExtension: String) async -> String?
    func loadTodoListImageAttachment(id: UUID, reference: String) async -> Data?
}

@MainActor
protocol TodoIssueLinkHandling: AnyObject {
    func loadTodoIssueStyles(readableIDs: Set<String>) async -> [String: TodoIssueInlineStyle]
    func openIssueFromTodoLink(_ readableID: String) async
    func setIssueClosedFromTodoLink(_ readableID: String, isClosed: Bool) async
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
