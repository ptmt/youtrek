import XCTest
@testable import YouTrek

final class YouTrekTests: XCTestCase {
    @MainActor
    func testAppStartsWithExpectedBootstrapState() throws {
        let container = AppContainer.preview
        XCTAssertNotNil(container)
        XCTAssertEqual(container.appState.selectedSidebarItem, .inbox)
    }
}
