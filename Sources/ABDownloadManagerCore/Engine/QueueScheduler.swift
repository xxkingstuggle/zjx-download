import Foundation

/// Schedules queued tasks while respecting queue windows, queue concurrency,
/// global concurrency, and priority. A one-second clock makes schedule changes
/// observable without blocking the download actors.
public actor QueueScheduler {
    private let store: AppStateStore
    private let engine: DownloadEngine
    private var loop: Task<Void, Never>?

    public init(store: AppStateStore, engine: DownloadEngine) { self.store = store; self.engine = engine }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scheduleAvailable()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() { loop?.cancel(); loop = nil }

    public func scheduleNow() async { await scheduleAvailable() }

    private func scheduleAvailable() async {
        let snapshot = await store.snapshot()
        let active = snapshot.tasks.filter { $0.status == .downloading || $0.status == .merging }
        guard active.count < snapshot.settings.maxConcurrentDownloads else { return }
        var queueCounts: [Int64: Int] = [:]
        for task in active { if let queueID = task.queueID { queueCounts[queueID, default: 0] += 1 } }
        let queues = Dictionary(uniqueKeysWithValues: snapshot.queues.map { ($0.id, $0) })
        let candidates = snapshot.tasks.filter { $0.isQueued && ($0.status == .created || $0.status == .stopped) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return priority(lhs.priority) > priority(rhs.priority) }
                return lhs.createdAt < rhs.createdAt
            }
        var slots = max(0, snapshot.settings.maxConcurrentDownloads - active.count)
        for task in candidates {
            guard slots > 0 else { break }
            if let queueID = task.queueID, let queue = queues[queueID] {
                guard queue.isRunning, queue.schedule?.isOpen(at: Date()) ?? true, queueCounts[queueID, default: 0] < queue.concurrencyLimit else { continue }
                queueCounts[queueID, default: 0] += 1
            }
            try? await engine.start(taskID: task.id)
            slots -= 1
        }
    }

    private func priority(_ priority: DownloadPriority) -> Int {
        switch priority { case .low: 0; case .normal: 1; case .high: 2 }
    }
}
