import Foundation
import XCTest
@testable import ABDownloadManagerCore

private actor RecordingQueueActionExecutor: QueueCompletionActionExecutor {
    private(set) var actions: [QueueCompletionAction] = []
    func execute(_ action: QueueCompletionAction) async throws { actions.append(action) }
}

final class QueueCompletionTests: XCTestCase {
    func testQueueCompletionActionsAreAtMostOncePerWorkCycle() async throws {
        let executor = RecordingQueueActionExecutor()
        let runner = QueueCompletionActionRunner(executor: executor)
        let queue = DownloadQueue(id: 7, name: "Night", completionAction: .sleepComputer)
        var first = DownloadTask(id: 1, source: DownloadSource(url: URL(string: "https://example.test/one")!), folderPath: "/tmp", fileName: "one")
        var second = DownloadTask(id: 2, source: DownloadSource(url: URL(string: "https://example.test/two")!), folderPath: "/tmp", fileName: "two")
        first.queueID = queue.id
        second.queueID = queue.id

        try await runner.observe(queues: [queue], tasks: [first, second])
        var actions = await executor.actions
        XCTAssertTrue(actions.isEmpty)

        first.status = .completed
        second.status = .failed
        try await runner.observe(queues: [queue], tasks: [first, second])
        try await runner.observe(queues: [queue], tasks: [first, second])
        actions = await executor.actions
        XCTAssertEqual(actions, [.sleepComputer])

        var third = DownloadTask(id: 3, source: DownloadSource(url: URL(string: "https://example.test/three")!), folderPath: "/tmp", fileName: "three")
        third.queueID = queue.id
        try await runner.observe(queues: [queue], tasks: [first, second, third])
        actions = await executor.actions
        XCTAssertEqual(actions, [.sleepComputer])
        third.status = .cancelled
        try await runner.observe(queues: [queue], tasks: [first, second, third])
        actions = await executor.actions
        XCTAssertEqual(actions, [.sleepComputer, .sleepComputer])
    }
}
