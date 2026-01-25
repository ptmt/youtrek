import Foundation

enum SyncOperationQueueError: Error {
    case syncingDisabled
}

actor SyncOperationQueue {
    private var pendingCount: Int = 0
    private var currentLabel: String?
    private var tail: Task<Void, Never> = Task {}
    private let activitySink: (@Sendable (Int, String?) async -> Void)?

    init(activitySink: (@Sendable (Int, String?) async -> Void)? = nil) {
        self.activitySink = activitySink
    }

    func enqueue<T: Sendable>(label: String, operation: @Sendable @escaping () async throws -> T) async throws -> T {
        if AppDebugSettings.disableSyncing {
            throw SyncOperationQueueError.syncingDisabled
        }
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
        LoggingService.sync.info("Sync queue: started '\(label, privacy: .public)' (pending=\(self.pendingCount, privacy: .public)).")
        await publish()
    }

    private func markFinished() async {
        pendingCount = max(0, pendingCount - 1)
        if pendingCount == 0 {
            currentLabel = nil
        }
        LoggingService.sync.info("Sync queue: finished (pending=\(self.pendingCount, privacy: .public)).")
        await publish()
    }

    private func publish() async {
        guard let activitySink else { return }
        await activitySink(pendingCount, currentLabel)
    }
}
