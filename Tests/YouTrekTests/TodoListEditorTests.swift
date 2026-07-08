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

    func testChecklistParserDetectsChecklistMarkersAndIssueID() {
        let parser = RegexTodoChecklistMarkerParser()
        let markdown = """
        - [ ] First task
          1. [x] YT-42 done task
        2. [X]Immediate
        regular text
        """

        let markers = parser.checklistMarkers(in: markdown)

        XCTAssertEqual(markers.count, 3)
        XCTAssertEqual(markers[0].isChecked, false)
        XCTAssertTrue(markers[0].hasExplicitCheckbox)
        XCTAssertNil(markers[0].issueID)
        XCTAssertEqual(markers[1].isChecked, true)
        XCTAssertTrue(markers[1].hasExplicitCheckbox)
        XCTAssertEqual(markers[1].issueID, "YT-42")
        XCTAssertEqual(markers[2].isChecked, true)
        XCTAssertTrue(markers[2].hasExplicitCheckbox)
    }

    func testChecklistParserAppliesCheckStateToMarkdown() {
        let parser = RegexTodoChecklistMarkerParser()
        let markdown = """
        - [ ] First task
        - [x] YT-7 done task
        """
        let markers = parser.checklistMarkers(in: markdown)
        XCTAssertEqual(markers.count, 2)

        let checked = parser.applyingCheckState(true, to: markdown, marker: markers[0])
        let unchecked = parser.applyingCheckState(false, to: checked, marker: markers[1])

        XCTAssertEqual(
            unchecked,
            """
            - [x] First task
            - [ ] YT-7 done task
            """
        )
    }

    func testChecklistParserDetectsPlainDashAndNumericListMarkers() {
        let parser = RegexTodoChecklistMarkerParser()
        let markdown = """
        - plain bullet
        \t2. numbered bullet
        * unsupported star bullet
        4) unsupported numeric style
        plain text
        """
        let markers = parser.checklistMarkers(in: markdown)
        XCTAssertEqual(markers.count, 2)
        XCTAssertFalse(markers[0].hasExplicitCheckbox)
        XCTAssertFalse(markers[1].hasExplicitCheckbox)
        XCTAssertFalse(markers[0].isChecked)
        XCTAssertFalse(markers[1].isChecked)
    }

    func testChecklistParserToggleOnlyReplacesStateCharacterLength() {
        let parser = RegexTodoChecklistMarkerParser()
        let markdown = "- [ ] plain bullet"
        let markers = parser.checklistMarkers(in: markdown)
        XCTAssertEqual(markers.count, 1)
        let toggled = parser.applyingCheckState(true, to: markdown, marker: markers[0])
        XCTAssertEqual(toggled.count, markdown.count)
        XCTAssertEqual(toggled, "- [x] plain bullet")
    }

    func testChecklistParserTogglePlainListDoesNotModifyMarkdown() {
        let parser = RegexTodoChecklistMarkerParser()
        let markdown = "- plain bullet"
        let markers = parser.checklistMarkers(in: markdown)
        XCTAssertEqual(markers.count, 1)
        XCTAssertFalse(markers[0].hasExplicitCheckbox)

        let toggled = parser.applyingCheckState(true, to: markdown, marker: markers[0])

        XCTAssertEqual(toggled, markdown)
    }

    func testChecklistParserSkipsLinesInsideCodeFence() {
        let parser = RegexTodoChecklistMarkerParser()
        let markdown = """
        - [ ] outside
        ```
        - [x] inside code fence
        ```
        - [x] outside 2
        """
        let markers = parser.checklistMarkers(in: markdown)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers[0].isChecked, false)
        XCTAssertEqual(markers[1].isChecked, true)
    }

    func testChecklistDetectorDetectsDashAndNumericListsWithOptionalTabs() {
        let detector = RegexTodoChecklistDetector()
        let markdown = """
        - plain
        \t- tabbed
        1. ordered
        \t2. [x] checked
        3. [ ] unchecked
        * unsupported star
        4) unsupported numeric style
        """

        let matches = detector.checklistLines(in: markdown)

        XCTAssertEqual(matches.map(\.lineIndex), [0, 1, 2, 3, 4])
        XCTAssertEqual(matches.map(\.isChecked), [false, false, false, true, false])
        XCTAssertTrue(matches.allSatisfy { $0.issueID == nil })
    }

    func testDashListContinuationDetectorReturnsIndentationForDashLists() {
        let detector = RegexTodoDashListContinuationDetector()

        XCTAssertEqual(detector.continuationIndentation(in: "- item"), "")
        XCTAssertEqual(detector.continuationIndentation(in: "\t- item"), "\t")
        XCTAssertEqual(detector.continuationIndentation(in: "  - [x] done"), "  ")
        XCTAssertNil(detector.continuationIndentation(in: "1. ordered item"))
        XCTAssertNil(detector.continuationIndentation(in: "* bullet"))
        XCTAssertNil(detector.continuationIndentation(in: "plain text"))
    }

    func testInlineMarkdownParserDetectsInlineElements() {
        let parser = RegexTodoInlineMarkdownParser()
        let markdown = """
        Prefix **bold** *italic* _italic2_ `code` ~~strike~~ [docs](https://example.com/docs)
        """
        let nsText = markdown as NSString
        let matches = parser.matches(in: markdown)

        let boldMatch = matches.first { match in
            if case .bold = match.kind { return true }
            return false
        }
        let italicMatch = matches.first { match in
            if case .italic = match.kind { return true }
            return false
        }
        let codeMatch = matches.first { match in
            if case .code = match.kind { return true }
            return false
        }
        let strikeMatch = matches.first { match in
            if case .strikethrough = match.kind { return true }
            return false
        }
        let linkMatch = matches.first { match in
            if case .link = match.kind { return true }
            return false
        }

        XCTAssertEqual(matches.count, 6)
        XCTAssertEqual(boldMatch.map { nsText.substring(with: $0.contentRange) }, "bold")
        XCTAssertNotNil(italicMatch)
        XCTAssertEqual(codeMatch.map { nsText.substring(with: $0.contentRange) }, "code")
        XCTAssertEqual(strikeMatch.map { nsText.substring(with: $0.contentRange) }, "strike")
        if let linkMatch {
            XCTAssertEqual(nsText.substring(with: linkMatch.contentRange), "docs")
            if case .link(let url) = linkMatch.kind {
                XCTAssertEqual(url.absoluteString, "https://example.com/docs")
            } else {
                XCTFail("Expected link kind")
            }
        } else {
            XCTFail("Expected link match")
        }
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

        // The style refresh debounces 250ms internally; poll for the result
        // instead of racing it with a single fixed sleep.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline, viewModel.issueStyles["YT-323"]?.status != .done {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

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

    func testViewModelSetIssueClosedDelegatesToHandler() async {
        let store = MockTodoMarkdownStore()
        let issues = MockTodoIssueLinkHandler()
        let viewModel = TodoListEditorViewModel(
            listID: UUID(),
            title: "Daily",
            markdownStore: store,
            issueLinkHandler: issues,
            saveDebounceNanoseconds: 0
        )

        await viewModel.setIssueClosed(fromChecklist: "YT-404", isClosed: true)
        XCTAssertEqual(issues.closedUpdates.count, 1)
        XCTAssertEqual(issues.closedUpdates.first?.id, "YT-404")
        XCTAssertEqual(issues.closedUpdates.first?.isClosed, true)
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
    var savedAttachments: [(id: UUID, data: Data, ext: String)] = []
    var attachmentDataByReference: [String: Data] = [:]

    func loadTodoListMarkdown(id: UUID) async -> String {
        loadedIDs.append(id)
        return loadedMarkdown
    }

    func saveTodoListMarkdown(id: UUID, markdown: String) async {
        savedEntries.append((id: id, markdown: markdown))
    }

    func saveTodoListImageAttachment(id: UUID, data: Data, preferredFileExtension: String) async -> String? {
        savedAttachments.append((id: id, data: data, ext: preferredFileExtension))
        let reference = "\(UUID().uuidString).\(preferredFileExtension)"
        attachmentDataByReference[reference] = data
        return reference
    }

    func loadTodoListImageAttachment(id: UUID, reference: String) async -> Data? {
        attachmentDataByReference[reference]
    }
}

@MainActor
private final class MockTodoIssueLinkHandler: TodoIssueLinkHandling {
    var styles: [String: TodoIssueInlineStyle] = [:]
    var requestedIDs: [Set<String>] = []
    var openedIssueIDs: [String] = []
    var closedUpdates: [(id: String, isClosed: Bool)] = []

    func loadTodoIssueStyles(readableIDs: Set<String>) async -> [String: TodoIssueInlineStyle] {
        requestedIDs.append(readableIDs)
        return styles
    }

    func openIssueFromTodoLink(_ readableID: String) async {
        openedIssueIDs.append(readableID)
    }

    func setIssueClosedFromTodoLink(_ readableID: String, isClosed: Bool) async {
        closedUpdates.append((id: readableID, isClosed: isClosed))
    }
}

@MainActor
private final class MockTodoListManager: TodoListManaging {
    var renameEntries: [(id: UUID, name: String)] = []

    func renameTodoList(id: UUID, name: String) async {
        renameEntries.append((id: id, name: name))
    }
}
