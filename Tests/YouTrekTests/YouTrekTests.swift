import XCTest
@testable import YouTrek

final class YouTrekTests: XCTestCase {
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
}
