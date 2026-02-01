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
}
