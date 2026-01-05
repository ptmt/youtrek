import Foundation

actor SyncOperationQueue {
    private var pendingCount: Int = 0
    private var currentLabel: String?
    private var tail: Task<Void, Never> = Task {}
    private let activitySink: (@Sendable (Int, String?) async -> Void)?

    init(activitySink: (@Sendable (Int, String?) async -> Void)? = nil) {
        self.activitySink = activitySink
    }

    func enqueue<T: Sendable>(label: String, operation: @Sendable @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous.value
            await markStarted(label: label)
            do {
                let result = try await operation()
                await self.markFinished()
                return result
            } catch {
                await self.markFinished()
                throw error
            }
        }
        tail = Task {
            _ = try? await task.value
        }
        return try await task.value
    }

    private func markStarted(label: String) async {
        pendingCount += 1
        currentLabel = label
        await publish()
    }

    private func markFinished() async {
        pendingCount = max(0, pendingCount - 1)
        if pendingCount == 0 {
            currentLabel = nil
        }
        await publish()
    }

    private func publish() async {
        guard let activitySink else { return }
        await activitySink(pendingCount, currentLabel)
    }
}
