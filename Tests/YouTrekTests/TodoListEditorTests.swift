import XCTest
@testable import YouTrek

@MainActor
final class TodoListEditorTests: XCTestCase {
    func testRegexIssueIDParserExtractsNormalizedIDs() {
        let parser = RegexTodoIssueIDParser()
        let markdown = """
        - YT-101 investigate
        - yt-999 should not match lowercase prefix
        - API-7 and API-7 duplicated
        """

        let ids = parser.issueIDs(in: markdown)
        XCTAssertEqual(ids, Set(["YT-101", "API-7"]))
    }

    func testChecklistRendererConvertsMarkdownCheckboxesToRenderedSymbols() {
        let renderer = TodoChecklistMarkdownRenderer()
        let markdown = """
        - [ ] First task
          * [x] Done task
        + [X]Immediate
        - regular bullet
        """

        let rendered = renderer.displayText(fromMarkdown: markdown)

        XCTAssertEqual(
            rendered,
            """
            - ☐ First task
              * ☑ Done task
            + ☑ Immediate
            - regular bullet
            """
        )
    }

    func testChecklistRendererConvertsRenderedSymbolsBackToMarkdown() {
        let renderer = TodoChecklistMarkdownRenderer()
        let rendered = """
        - ☐ First task
          * ☑ Done task
        + ☑ Immediate
        - regular bullet
        """

        let markdown = renderer.markdownText(fromDisplayText: rendered)

        XCTAssertEqual(
            markdown,
            """
            - [ ] First task
              * [x] Done task
            + [x] Immediate
            - regular bullet
            """
        )
    }

    func testViewModelLoadUsesHeadingWhenDocumentIsEmpty() async {
        let store = MockTodoMarkdownStore()
        let issues = MockTodoIssueLinkHandler()
        let listID = UUID()
        let viewModel = TodoListEditorViewModel(
            listID: listID,
            title: "Daily",
            markdownStore: store,
            issueLinkHandler: issues,
            saveDebounceNanoseconds: 0
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.markdown, "# Daily\n\n")
        XCTAssertEqual(store.loadedIDs, [listID])
    }

    func testViewModelSavesAndLoadsIssueStylesAfterMarkdownChange() async {
        let store = MockTodoMarkdownStore()
        let issues = MockTodoIssueLinkHandler()
        let listID = UUID()
        store.loadedMarkdown = "# Sprint\n\n"
        issues.styles = [
            "YT-323": TodoIssueInlineStyle(issueID: "YT-323", status: .done)
        ]
        let viewModel = TodoListEditorViewModel(
            listID: listID,
            title: "Sprint",
            markdownStore: store,
            issueLinkHandler: issues,
            saveDebounceNanoseconds: 0
        )
        await viewModel.load()

        let updated = "# Sprint\n\nYT-323 done"
        viewModel.markdown = updated
        viewModel.handleMarkdownChange(updated)
        try? await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(store.savedEntries.last?.markdown, updated)
        XCTAssertEqual(issues.requestedIDs.last, Set(["YT-323"]))
        XCTAssertEqual(viewModel.issueStyles["YT-323"]?.status, .done)
    }

    func testViewModelOpenIssueDelegatesToHandler() async {
        let store = MockTodoMarkdownStore()
        let issues = MockTodoIssueLinkHandler()
        let viewModel = TodoListEditorViewModel(
            listID: UUID(),
            title: "Daily",
            markdownStore: store,
            issueLinkHandler: issues,
            saveDebounceNanoseconds: 0
        )

        await viewModel.openIssue("YT-404")
        XCTAssertEqual(issues.openedIssueIDs, ["YT-404"])
    }

    func testViewModelRenameDelegatesAndUpdatesHeading() async {
        let store = MockTodoMarkdownStore()
        let issues = MockTodoIssueLinkHandler()
        let manager = MockTodoListManager()
        let listID = UUID()
        let viewModel = TodoListEditorViewModel(
            listID: listID,
            title: "Old Name",
            markdownStore: store,
            issueLinkHandler: issues,
            todoListManager: manager,
            saveDebounceNanoseconds: 0
        )
        viewModel.markdown = "# Old Name\n\n- item"

        await viewModel.rename(to: "New Name")

        XCTAssertEqual(manager.renameEntries.count, 1)
        XCTAssertEqual(manager.renameEntries.first?.id, listID)
        XCTAssertEqual(manager.renameEntries.first?.name, "New Name")
        XCTAssertEqual(viewModel.title, "New Name")
        XCTAssertTrue(viewModel.markdown.hasPrefix("# New Name"))
    }
}

@MainActor
private final class MockTodoMarkdownStore: TodoListMarkdownStoring {
    var loadedMarkdown: String = ""
    var loadedIDs: [UUID] = []
    var savedEntries: [(id: UUID, markdown: String)] = []

    func loadTodoListMarkdown(id: UUID) async -> String {
        loadedIDs.append(id)
        return loadedMarkdown
    }

    func saveTodoListMarkdown(id: UUID, markdown: String) async {
        savedEntries.append((id: id, markdown: markdown))
    }
}

@MainActor
private final class MockTodoIssueLinkHandler: TodoIssueLinkHandling {
    var styles: [String: TodoIssueInlineStyle] = [:]
    var requestedIDs: [Set<String>] = []
    var openedIssueIDs: [String] = []

    func loadTodoIssueStyles(readableIDs: Set<String>) async -> [String: TodoIssueInlineStyle] {
        requestedIDs.append(readableIDs)
        return styles
    }

    func openIssueFromTodoLink(_ readableID: String) async {
        openedIssueIDs.append(readableID)
    }
}

@MainActor
private final class MockTodoListManager: TodoListManaging {
    var renameEntries: [(id: UUID, name: String)] = []

    func renameTodoList(id: UUID, name: String) async {
        renameEntries.append((id: id, name: name))
    }
}
