import AppKit
import SwiftUI
import XCTest
@testable import YouTrek

final class YouTrekTests: XCTestCase {
    func testMarkdownDisplayTextRendererNormalizesWindowsLineEndingsIntoHardBreaks() {
        let prepared = MarkdownDisplayTextRenderer.preparedMarkdown(
            for: "First line\r\nSecond line\rThird line"
        )

        XCTAssertEqual(
            prepared,
            """
            First line  
            Second line  
            Third line
            """
        )
    }

    func testMarkdownDisplayTextRendererPreservesCodeFenceLinesWhileNormalizingLineEndings() {
        let prepared = MarkdownDisplayTextRenderer.preparedMarkdown(
            for: "Before\r\n```swift\r\nlet value = 1\r\nlet other = 2\r\n```\r\nAfter"
        )

        XCTAssertEqual(
            prepared,
            """
            Before  
            ```swift
            let value = 1
            let other = 2
            ```
            After
            """
        )
    }

    func testMarkdownDisplayTextRendererPreservesSingleLineBreaksAfterParsing() throws {
        let attributed = try XCTUnwrap(MarkdownDisplayTextRenderer.attributedMarkdown(
            for: "First line\nSecond line"
        ))

        XCTAssertEqual(String(attributed.characters), "First line\nSecond line")
    }

    func testMarkdownDisplayTextRendererPreservesSingleLineBreaksAroundBlockMarkdown() throws {
        let attributed = try XCTUnwrap(MarkdownDisplayTextRenderer.attributedMarkdown(
            for: "# Heading\nBody\n- Item"
        ))

        XCTAssertEqual(String(attributed.characters), "Heading\nBody\nItem")
    }

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

    @MainActor
    func testSidebarCoordinatorDoesNotReapplyStaleSelectionDuringSelectionChange() {
        final class CoordinatorBox {
            var coordinator: AppKitSidebarPane.Coordinator?
        }

        let page = IssueQuery.Page(size: 50, offset: 0)
        let inbox = SidebarItem.inbox(page: page)
        let assigned = SidebarItem.assignedToMe(page: page)
        let sections = [SidebarSection(id: "smart", title: "Smart Filters", items: [inbox, assigned])]

        let containerView = SidebarOutlineContainerView(frame: .init(x: 0, y: 0, width: 280, height: 320))
        let outlineView = containerView.outlineView

        var selectedItem: SidebarItem? = inbox
        let coordinatorBox = CoordinatorBox()

        let selectionBinding = Binding<SidebarItem?>(
            get: { selectedItem },
            set: { newValue in
                let staleParent = AppKitSidebarPane(
                    sections: sections,
                    selection: .constant(selectedItem),
                    onDeleteSavedSearch: nil,
                    onRefreshBoard: nil,
                    onOpenBoardInWeb: nil,
                    boardSyncStatus: nil,
                    onCreateTodoList: nil,
                    onRenameTodoList: nil,
                    onDeleteTodoList: nil
                )
                coordinatorBox.coordinator?.apply(parent: staleParent, outlineView: outlineView)
                selectedItem = newValue
            }
        )

        let pane = AppKitSidebarPane(
            sections: sections,
            selection: selectionBinding,
            onDeleteSavedSearch: nil,
            onRefreshBoard: nil,
            onOpenBoardInWeb: nil,
            boardSyncStatus: nil,
            onCreateTodoList: nil,
            onRenameTodoList: nil,
            onDeleteTodoList: nil
        )

        let coordinator = pane.makeCoordinator()
        coordinatorBox.coordinator = coordinator
        coordinator.configure(outlineView: outlineView)
        coordinator.apply(parent: pane, outlineView: outlineView)

        outlineView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        coordinator.outlineViewSelectionDidChange(
            Notification(name: NSOutlineView.selectionDidChangeNotification, object: outlineView)
        )

        XCTAssertEqual(selectedItem?.id, assigned.id)
        XCTAssertEqual(outlineView.selectedRow, 2)
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

    @MainActor
    func testShowToastCanCarryCreatedIssueTarget() {
        let state = AppState()
        let issue = IssueSummary(
            readableID: "YT-42",
            title: "Refresh issue list after create",
            projectName: "YouTrek"
        )

        state.showToast("Issue YT-42 created", issueToOpen: issue)

        XCTAssertEqual(state.activeToast?.message, "Issue YT-42 created")
        XCTAssertEqual(state.activeToast?.issueToOpen, issue)
        XCTAssertEqual(state.activeToast?.isInteractive, true)
    }

    @MainActor
    func testActivateToastOpensIssueInInspector() {
        let container = AppContainer.preview
        let issue = IssueSummary(
            readableID: "YT-77",
            title: "Open created issue from toast",
            projectName: "YouTrek"
        )
        let toast = ToastNotice(message: "Issue YT-77 created", issueToOpen: issue)

        container.appState.setInspectorVisible(false)
        container.appState.selectedIssue = nil
        container.appState.selectedIssueIDs = []
        container.appState.activeToast = toast

        container.activateToast(toast)

        XCTAssertNil(container.appState.activeToast)
        XCTAssertEqual(container.appState.selectedIssue, issue)
        XCTAssertEqual(container.appState.selectedIssueIDs, [issue.id])
        XCTAssertTrue(container.appState.isInspectorVisible)
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

    func testMarkdownImageParserConsumesYouTrackImageAttributes() {
        let markdown = """
        Before text
        ![Preview](screenshot.png){width=70%}
        After text
        """

        let fragments = MarkdownImageMarkdownParser.fragments(in: markdown)
        XCTAssertEqual(fragments.count, 3)

        guard case .image(let match) = fragments[1] else {
            return XCTFail("Expected image fragment")
        }
        XCTAssertEqual(match.altText, "Preview")
        XCTAssertEqual(match.source, "screenshot.png")
        XCTAssertEqual(match.displayOptions.width, .percent(0.7))

        guard case .text(let trailing) = fragments[2] else {
            return XCTFail("Expected trailing text fragment")
        }
        XCTAssertFalse(trailing.contains("{width=70%}"))
    }

    func testMarkdownImageSourceResolverMatchesIssueAttachmentByName() {
        let url = URL(string: "https://example.com/api/files/2-3")!
        let attachment = IssueAttachment(
            id: "2-3",
            name: "screenshot.png",
            size: nil,
            mimeType: "image/png",
            url: url,
            createdAt: nil,
            author: nil
        )

        let resolved = MarkdownImageSourceResolver.resolve(
            source: "screenshot.png",
            baseURL: nil,
            attachments: [attachment]
        )

        XCTAssertEqual(resolved, .remote(url))
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

    func testOAuthConfigurationFallsBackToInfoDictionaryValues() throws {
        let configuration = try YouTrackOAuthConfiguration.load(
            environment: [:],
            infoDictionary: [
                "YOUTRACK_BASE_URL": "https://example.jetbrains.space/api",
                "YOUTRACK_CLIENT_ID": "mobile-client",
                "YOUTRACK_REDIRECT_URI": "youtrek://oauth_callback",
                "YOUTRACK_SCOPES": "YouTrack, Hub"
            ]
        )

        XCTAssertEqual(configuration.apiBaseURL.absoluteString, "https://example.jetbrains.space/api")
        XCTAssertEqual(
            configuration.authorizationEndpoint.absoluteString,
            "https://example.jetbrains.space/hub/api/rest/oauth2/auth"
        )
        XCTAssertEqual(
            configuration.tokenEndpoint.absoluteString,
            "https://example.jetbrains.space/hub/api/rest/oauth2/token"
        )
        XCTAssertEqual(configuration.clientID, "mobile-client")
        XCTAssertEqual(configuration.redirectURI.absoluteString, "youtrek://oauth_callback")
        XCTAssertEqual(configuration.scopes, ["YouTrack", "Hub"])
    }

    func testOAuthConfigurationEnvironmentOverridesInfoDictionary() throws {
        let configuration = try YouTrackOAuthConfiguration.load(
            environment: [
                "YOUTRACK_CLIENT_ID": "env-client",
                "YOUTRACK_BASE_URL": "https://env.example.com/api",
                "YOUTRACK_SCOPES": "YouTrack"
            ],
            infoDictionary: [
                "YOUTRACK_CLIENT_ID": "plist-client",
                "YOUTRACK_BASE_URL": "https://plist.example.com/api",
                "YOUTRACK_SCOPES": "Hub"
            ]
        )

        XCTAssertEqual(configuration.clientID, "env-client")
        XCTAssertEqual(configuration.apiBaseURL.absoluteString, "https://env.example.com/api")
        XCTAssertEqual(configuration.scopes, ["YouTrack"])
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

    func testCLIInstallerUsesHomebrewFallbackBeforeUserLevelFallbacks() {
        XCTAssertEqual(
            CLIInstaller.preferredFallbackInstallPaths + CLIInstaller.fallbackInstallPaths,
            [
                "/opt/homebrew/bin/youtrek",
                "~/.local/bin/youtrek",
                "~/bin/youtrek"
            ]
        )
    }

    func testCLIInstallerOmitsPathNoteWhenInstallDirectoryIsOnPath() {
        let message = CLIInstaller.appendPathNoteIfNeeded(
            to: "Installed CLI alias",
            directory: "/opt/homebrew/bin",
            environment: ["PATH": "/usr/bin:/opt/homebrew/bin:/bin"]
        )

        XCTAssertEqual(message, "Installed CLI alias")
    }

    func testCLIInstallerAddsPathNoteWhenInstallDirectoryIsNotOnPath() {
        let message = CLIInstaller.appendPathNoteIfNeeded(
            to: "Installed CLI alias",
            directory: "/Users/example/.local/bin",
            environment: ["PATH": "/usr/local/bin:/usr/bin:/bin"]
        )

        XCTAssertEqual(
            message,
            "Installed CLI alias\nNote: ensure /Users/example/.local/bin is on your PATH."
        )
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

final class IssueListReloadPlannerTests: XCTestCase {
    func testFirstRenderRequiresFullReload() {
        let next = makeSnapshot(titles: ["A", "B"], unread: [true, false])

        XCTAssertEqual(IssueListReloadPlanner.action(previous: nil, next: next), .full)
    }

    func testUnchangedSnapshotSkipsReload() {
        let previous = makeSnapshot(titles: ["A", "B"], unread: [true, false])
        let next = makeSnapshot(titles: ["A", "B"], unread: [true, false])

        XCTAssertEqual(IssueListReloadPlanner.action(previous: previous, next: next), .none)
    }

    func testIssueContentChangeRequiresFullReload() {
        let previous = makeSnapshot(titles: ["A", "B"], unread: [false, false])
        let next = makeSnapshot(titles: ["A", "C"], unread: [false, false])

        XCTAssertEqual(IssueListReloadPlanner.action(previous: previous, next: next), .full)
    }

    func testColumnConfigurationChangeRequiresFullReload() {
        let previous = makeSnapshot(titles: ["A"], unread: [false], showAssigneeColumn: false)
        let next = makeSnapshot(titles: ["A"], unread: [false], showAssigneeColumn: true)

        XCTAssertEqual(IssueListReloadPlanner.action(previous: previous, next: next), .full)
    }

    func testUnreadFlagChangeReloadsOnlyChangedRows() {
        let previous = makeSnapshot(titles: ["A", "B", "C"], unread: [true, true, false])
        let next = makeSnapshot(titles: ["A", "B", "C"], unread: [false, true, true])

        XCTAssertEqual(
            IssueListReloadPlanner.action(previous: previous, next: next),
            .rows(IndexSet([0, 2]))
        )
    }

    private func makeSnapshot(
        titles: [String],
        unread: [Bool],
        showAssigneeColumn: Bool = false
    ) -> IssueListRenderSnapshot {
        let issues = titles.enumerated().map { index, title in
            IssueSummary(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                readableID: "YT-\(index)",
                title: title,
                projectName: "YouTrek",
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        }
        return IssueListRenderSnapshot(
            issues: issues,
            unreadFlags: unread,
            showAssigneeColumn: showAssigneeColumn
        )
    }
}
