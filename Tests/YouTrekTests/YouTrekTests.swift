import XCTest
@testable import YouTrek

final class YouTrekTests: XCTestCase {
    @MainActor
    func testRootSplitViewControllerUsesFullHeightLayoutForMainAndInspector() {
        let controller = RootSplitViewController()
        XCTAssertGreaterThanOrEqual(controller.splitViewItems.count, 3)
        XCTAssertTrue(controller.splitViewItems[1].allowsFullHeightLayout)
        XCTAssertTrue(controller.splitViewItems[2].allowsFullHeightLayout)
    }

    @MainActor
    func testAppStartsWithExpectedBootstrapState() async throws {
        let container = AppContainer.preview
        XCTAssertNotNil(container)
        await container.bootstrap()
        let selection = try XCTUnwrap(container.appState.selectedSidebarItem)
        XCTAssertFalse(selection.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(selection.query.page.offset, 0)
    }

    @MainActor
    func testSidebarContainsTodoSectionAfterBootstrap() async throws {
        let container = AppContainer.preview
        await container.bootstrap()

        let todoSection = try XCTUnwrap(container.appState.sidebarSections.first { $0.id == "todo" })
        XCTAssertEqual(todoSection.title, "Todo Lists")
    }

    func testTodoListSidebarItemRoundTripsDocumentID() {
        let id = UUID()
        let page = IssueQuery.Page(size: 50, offset: 0)
        let document = TodoListDocument(
            id: id,
            name: "Daily Notes",
            fileName: "\(id.uuidString).md",
            updatedAt: Date()
        )
        let item = SidebarItem.todoList(document, page: page)
        XCTAssertTrue(item.isTodoList)
        XCTAssertEqual(item.todoListID, id)
        XCTAssertEqual(item.title, "Daily Notes")
    }

    func testTodoListMarkdownStorePersistsAndUpdatesTitle() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("youtrek-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let store = TodoListMarkdownStore(accountID: nil, baseDirectory: tempRoot)
        let created = try await store.createDocument(named: "Standup")
        XCTAssertEqual(created.name, "Standup")

        let loaded = try await store.loadMarkdown(id: created.id)
        XCTAssertTrue(loaded.hasPrefix("# Standup"))

        try await store.saveMarkdown(id: created.id, markdown: "# Release Plan\n\nYT-323: Ship sidebar")
        let documents = try await store.listDocuments()
        let updated = try XCTUnwrap(documents.first { $0.id == created.id })
        XCTAssertEqual(updated.name, "Release Plan")
    }

    func testTodoListMarkdownStorePersistsImageAttachmentPayload() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("youtrek-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let store = TodoListMarkdownStore(accountID: nil, baseDirectory: tempRoot)
        let created = try await store.createDocument(named: "Images")
        let payload = Data([0, 1, 2, 3, 4, 5])

        let reference = try await store.saveImageAttachment(
            id: created.id,
            data: payload,
            preferredFileExtension: "png"
        )
        let loaded = try await store.loadImageAttachment(id: created.id, reference: reference)

        XCTAssertEqual(loaded, payload)
    }

    @MainActor
    func testNewIssueDialogStateFromSelectedTextReturnsBlankForEmptyInput() {
        let state = AppContainer.newIssueDialogState(fromSelectedText: "   \n  ")
        XCTAssertEqual(state.title, "")
        XCTAssertEqual(state.description, "")
    }

    @MainActor
    func testNewIssueDialogStateFromSelectedTextUsesSingleLineAsTitle() {
        let state = AppContainer.newIssueDialogState(fromSelectedText: "Fix flaky sync toast")
        XCTAssertEqual(state.title, "Fix flaky sync toast")
        XCTAssertEqual(state.description, "")
    }

    @MainActor
    func testNewIssueDialogStateFromSelectedTextUsesFirstLineAsTitleAndFullDescription() {
        let state = AppContainer.newIssueDialogState(
            fromSelectedText: "Sync failure in background\n1. Open app\n2. Wait for sync"
        )
        XCTAssertEqual(state.title, "Sync failure in background")
        XCTAssertEqual(state.description, "Sync failure in background\n1. Open app\n2. Wait for sync")
    }

    @MainActor
    func testNewIssueDialogStateFromSelectedTextTruncatesLongTitleAndPreservesDescription() {
        let longSelection = String(repeating: "A", count: 130)
        let state = AppContainer.newIssueDialogState(fromSelectedText: longSelection)
        XCTAssertEqual(state.title, String(repeating: "A", count: 120) + "...")
        XCTAssertEqual(state.description, longSelection)
    }

    @MainActor
    func testNewIssueDialogStateFromSelectedTextCanBeMarkedAsQueued() {
        let state = AppContainer.newIssueDialogState(
            fromSelectedText: "Queue this issue",
            queueAsUncommitted: true
        )
        XCTAssertTrue(state.queueAsUncommitted)
        XCTAssertEqual(state.title, "Queue this issue")
    }

    func testMarkdownImageParserSplitsTextAndImageFragments() {
        let markdown = """
        Before text

        ![Preview](https://example.com/image.png)

        After text
        """

        let fragments = MarkdownImageMarkdownParser.fragments(in: markdown)
        XCTAssertEqual(fragments.count, 3)

        guard case .text(let leading) = fragments[0] else {
            return XCTFail("Expected leading text fragment")
        }
        XCTAssertTrue(leading.contains("Before text"))

        guard case .image(let match) = fragments[1] else {
            return XCTFail("Expected image fragment")
        }
        XCTAssertEqual(match.altText, "Preview")
        XCTAssertEqual(match.source, "https://example.com/image.png")

        guard case .text(let trailing) = fragments[2] else {
            return XCTFail("Expected trailing text fragment")
        }
        XCTAssertTrue(trailing.contains("After text"))
    }

    func testMarkdownImageSourceResolverDecodesInlineDataURL() {
        let resolved = MarkdownImageSourceResolver.resolve(
            source: "data:image/png;base64,AAEC",
            baseURL: nil
        )
        guard case .inlineData(let data) = resolved else {
            return XCTFail("Expected inline image data")
        }
        XCTAssertEqual(data, Data([0, 1, 2]))
    }

    func testMarkdownClipboardImageEncoderProducesMarkdownImageSnippet() {
        let markdown = MarkdownClipboardImageEncoder.markdownSnippet(forPNGData: Data([0, 1, 2]))
        XCTAssertTrue(markdown.hasPrefix("![Pasted image](data:image/png;base64,"))
        XCTAssertTrue(markdown.hasSuffix(")"))
    }

    func testYouTrackAPIErrorCancellationDetectionForTransportCancelled() {
        let error = YouTrackAPIError.transport(underlying: URLError(.cancelled))
        XCTAssertTrue(error.isCancellation)
    }

    func testYouTrackAPIErrorCancellationDetectionForTransportTimeout() {
        let error = YouTrackAPIError.transport(underlying: URLError(.timedOut))
        XCTAssertFalse(error.isCancellation)
    }

    @MainActor
    func testSyncCompleteIndicatorAppearsAfterIdleDelay() async throws {
        let state = AppState(
            syncCompleteRevealDelay: .milliseconds(80),
            syncCompleteVisibleDuration: .seconds(1)
        )

        state.updateSyncActivity(isSyncing: true, label: "Sync issues")
        state.updateSyncActivity(isSyncing: false, label: nil)

        XCTAssertFalse(state.showSyncComplete)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(state.showSyncComplete)

        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertTrue(state.showSyncComplete)
    }

    @MainActor
    func testSyncCompleteIndicatorOnlyShowsForFinalSubsync() async throws {
        let state = AppState(
            syncCompleteRevealDelay: .milliseconds(100),
            syncCompleteVisibleDuration: .seconds(1)
        )

        state.updateSyncActivity(isSyncing: true, label: "Sync issues")
        state.updateSyncActivity(isSyncing: false, label: nil)

        try await Task.sleep(nanoseconds: 50_000_000)
        state.updateSyncActivity(isSyncing: true, label: "Sync saved searches")
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertFalse(state.showSyncComplete)

        state.updateSyncActivity(isSyncing: false, label: nil)
        try await Task.sleep(nanoseconds: 130_000_000)
        XCTAssertTrue(state.showSyncComplete)
    }

    @MainActor
    func testWorkspaceIssueListComposerShowsDraftsInInbox() {
        let appState = AppState()
        let issueA = makeIssue(readableID: "YT-1", title: "Server exception")
        let issueB = makeIssue(readableID: "YT-2", title: "Toolbar polish")
        appState.replaceIssues(with: [issueA, issueB])

        let olderDraft = makeDraftRecord(title: "Older draft", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newerDraft = makeDraftRecord(title: "Newer draft", updatedAt: Date(timeIntervalSince1970: 2_000))
        appState.setDrafts([olderDraft, newerDraft])

        let visible = WorkspaceIssueListComposer.visibleIssues(
            appState: appState,
            selection: SidebarItem.inbox(page: .init(size: 50, offset: 0)),
            searchQuery: ""
        )

        XCTAssertEqual(visible.count, 4)
        XCTAssertEqual(visible.prefix(2).compactMap(\.draftID), [newerDraft.id, olderDraft.id])
        XCTAssertEqual(Array(visible.dropFirst(2)).map(\.id), [issueA.id, issueB.id])
    }

    @MainActor
    func testWorkspaceIssueListComposerSkipsDraftsOutsideInbox() {
        let appState = AppState()
        let issueA = makeIssue(readableID: "YT-10", title: "Background sync")
        let issueB = makeIssue(readableID: "YT-11", title: "Command palette")
        appState.replaceIssues(with: [issueA, issueB])
        appState.setDrafts([makeDraftRecord(title: "Draft task", updatedAt: Date())])

        let visible = WorkspaceIssueListComposer.visibleIssues(
            appState: appState,
            selection: SidebarItem.assignedToMe(page: .init(size: 50, offset: 0)),
            searchQuery: ""
        )

        XCTAssertEqual(visible.map(\.id), [issueA.id, issueB.id])
        XCTAssertTrue(visible.allSatisfy { $0.draftID == nil })
    }

    func testWorkspaceIssueListComposerTreatsInboxTitleAsDraftSelection() {
        let item = SidebarItem(
            id: "saved:inbox-alias",
            kind: .savedSearch,
            title: "inbox",
            iconName: "tray",
            query: IssueQuery(
                rawQuery: nil,
                search: "",
                filters: [],
                sort: nil,
                page: .init(size: 50, offset: 0)
            ),
            board: nil
        )

        XCTAssertTrue(WorkspaceIssueListComposer.selectionShowsDrafts(item))
    }

    private func makeIssue(readableID: String, title: String) -> IssueSummary {
        IssueSummary(
            readableID: readableID,
            title: title,
            projectName: "YouTrek",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeDraftRecord(title: String, updatedAt: Date) -> IssueDraftRecord {
        IssueDraftRecord(
            draft: IssueDraft(
                title: title,
                description: "",
                projectID: "0-0",
                module: nil,
                priority: .normal,
                assigneeID: nil
            ),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: updatedAt
        )
    }
}
