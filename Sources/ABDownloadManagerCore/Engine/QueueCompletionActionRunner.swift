import Foundation

public struct QueueCompletionEvent: Sendable, Equatable {
    public let queueID: Int64
    public let action: QueueCompletionAction
    public init(queueID: Int64, action: QueueCompletionAction) { self.queueID = queueID; self.action = action }
}

public protocol QueueCompletionActionExecutor: Sendable {
    func execute(_ action: QueueCompletionAction) async throws
}

/// Converts queue snapshots into at-most-once completion actions. A queue must
/// have observed pending work before a completed/failed/cancelled transition;
/// reopening an app with old completed downloads therefore never repeats a
/// sleep, shutdown, or quit action.
public actor QueueCompletionActionRunner {
    private let executor: any QueueCompletionActionExecutor
    private var queuesWithPendingWork: Set<Int64> = []

    public init(executor: any QueueCompletionActionExecutor) { self.executor = executor }

    public func observe(queues: [DownloadQueue], tasks: [DownloadTask]) async throws {
        let queueIDs = Set(queues.map(\.id))
        queuesWithPendingWork.formIntersection(queueIDs)
        let tasksByQueue = Dictionary(grouping: tasks.compactMap { task -> (Int64, DownloadTask)? in
            guard let id = task.queueID else { return nil }
            return (id, task)
        }, by: \.0)

        for queue in queues.sorted(by: { $0.order < $1.order }) {
            let members = (tasksByQueue[queue.id] ?? []).map(\.1)
            guard !members.isEmpty else { continue }
            let hasPending = members.contains { !Self.isQueueAttemptFinished($0.status) }
            if hasPending {
                queuesWithPendingWork.insert(queue.id)
                continue
            }
            guard queuesWithPendingWork.remove(queue.id) != nil, queue.completionAction != .none else { continue }
            try await executor.execute(queue.completionAction)
        }
    }

    private static func isQueueAttemptFinished(_ status: DownloadStatus) -> Bool {
        status == .completed || status == .failed || status == .cancelled
    }
}
