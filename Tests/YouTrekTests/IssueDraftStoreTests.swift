import XCTest
@testable import YouTrek

final class IssueDraftStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "IssueDraftStoreTests")
        defaults.removePersistentDomain(forName: "IssueDraftStoreTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "IssueDraftStoreTests")
        defaults = nil
        super.tearDown()
    }

    func testLatestSubmittedDraftReturnsNilWhenNone() async {
        let store = IssueDraftStore(defaults: defaults)
        let latest = await store.latestSubmittedDraft()
        XCTAssertNil(latest)
    }

    func testLatestSubmittedDraftReturnsMostRecentSubmittedDraft() async {
        let store = IssueDraftStore(defaults: defaults)

        let firstDraft = IssueDraft(
            title: "First",
            description: "",
            projectID: "0-1",
            module: "Core",
            priority: .high,
            assigneeID: "me"
        )
        let firstRecord = await store.saveDraft(firstDraft)
        _ = await store.markDraftSubmitted(id: firstRecord.id)

        let secondDraft = IssueDraft(
            title: "Second",
            description: "",
            projectID: "0-2",
            module: "UI",
            priority: .low,
            assigneeID: "me"
        )
        let secondRecord = await store.saveDraft(secondDraft)
        _ = await store.markDraftSubmitted(id: secondRecord.id)

        let latest = await store.latestSubmittedDraft()
        XCTAssertEqual(latest, secondDraft)
    }
}
