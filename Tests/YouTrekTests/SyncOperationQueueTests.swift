import XCTest
@testable import YouTrek

final class SyncOperationQueueTests: XCTestCase {
    func testOperationsExecuteInOrder() async throws {
        let recorder = ValueRecorder<Int>()
        let queue = SyncOperationQueue()

        let firstTask = Task {
            try await queue.enqueue(label: "First") {
                await recorder.append(1)
                try await Task.sleep(nanoseconds: 30_000_000)
                return 1
            }
        }

        try await Task.sleep(nanoseconds: 5_000_000)

        let secondTask = Task {
            try await queue.enqueue(label: "Second") {
                await recorder.append(2)
                return 2
            }
        }

        _ = try await firstTask.value
        _ = try await secondTask.value

        let values = await recorder.snapshot()
        XCTAssertEqual(values, [1, 2])
    }

    func testActivitySinkReportsPendingCountAndLabel() async throws {
        let recorder = ActivityRecorder()
        let queue = SyncOperationQueue { pendingCount, label in
            await recorder.append(ActivityEvent(pendingCount: pendingCount, label: label))
        }

        _ = try await queue.enqueue(label: "First") { 1 }
        _ = try await queue.enqueue(label: "Second") { 2 }

        let events = await recorder.snapshot()
        XCTAssertGreaterThanOrEqual(events.count, 4)
        XCTAssertEqual(events[0], ActivityEvent(pendingCount: 1, label: "First"))
        XCTAssertEqual(events[1], ActivityEvent(pendingCount: 0, label: nil))
        XCTAssertEqual(events[2], ActivityEvent(pendingCount: 1, label: "Second"))
        XCTAssertEqual(events[3], ActivityEvent(pendingCount: 0, label: nil))
    }

    func testErrorDoesNotBlockQueue() async throws {
        let queue = SyncOperationQueue()

        struct DummyError: Error {}

        let failingTask = Task {
            try await queue.enqueue(label: "Fail") {
                throw DummyError()
            }
        }

        let succeedingTask = Task {
            try await queue.enqueue(label: "After") {
                7
            }
        }

        do {
            _ = try await failingTask.value
            XCTFail("Expected failure from the first queued task")
        } catch {
            // Expected error.
        }

        let result = try await succeedingTask.value
        XCTAssertEqual(result, 7)
    }
}

private actor ValueRecorder<Value: Sendable> {
    private var values: [Value] = []

    func append(_ value: Value) {
        values.append(value)
    }

    func snapshot() -> [Value] {
        values
    }
}

private struct ActivityEvent: Equatable, Sendable {
    let pendingCount: Int
    let label: String?
}

private actor ActivityRecorder {
    private var events: [ActivityEvent] = []

    func append(_ event: ActivityEvent) {
        events.append(event)
    }

    func snapshot() -> [ActivityEvent] {
        events
    }
}
