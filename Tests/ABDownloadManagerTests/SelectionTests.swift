import XCTest
@testable import ABDownloadManagerCore

final class SelectionTests: XCTestCase {
    private func task(_ id: Int64, _ status: DownloadStatus) -> DownloadTask {
        DownloadTask(
            id: id,
            source: DownloadSource(url: URL(string: "https://example.test/\(id).bin")!),
            folderPath: "/tmp",
            fileName: "file-\(id).bin",
            status: status
        )
    }

    // MARK: - Selection add/remove/toggle

    func testToggleAddsAndRemovesId() {
        var selection = TaskSelection()
        XCTAssertTrue(selection.isEmpty)
        selection = selection.toggling(7)
        XCTAssertTrue(selection.contains(7))
        XCTAssertEqual(selection.primary, 7)
        selection = selection.toggling(7)
        XCTAssertFalse(selection.contains(7))
        XCTAssertNil(selection.primary)
    }

    func testToggleMultipleKeepsTrackOfIdsAndPrimary() {
        var selection = TaskSelection()
        selection = selection.toggling(1)
        selection = selection.toggling(2)
        XCTAssertEqual(selection.ids, Set([1, 2]))
        XCTAssertEqual(selection.primary, 2)
        selection = selection.toggling(1)
        XCTAssertEqual(selection.ids, Set([2]))
        XCTAssertEqual(selection.primary, 2)
    }

    // MARK: - Select-all-visible + clear

    func testSelectAllVisibleSelectsOnlyVisibleIds() {
        let base = TaskSelection().selecting(visible: [10, 20, 30])
        XCTAssertEqual(base.ids, Set([10, 20, 30]))
        XCTAssertEqual(base.count, 3)
        XCTAssertTrue(base.contains(10))
    }

    func testSelectAllVisibleKeepsPrimaryWhenPresent() {
        let selection = TaskSelection(primary: 20).selecting(visible: [10, 20, 30])
        XCTAssertEqual(selection.primary, 20)
        XCTAssertEqual(selection.ids, Set([10, 20, 30]))
    }

    func testSelectAllVisibleClearsPrimaryWhenDropped() {
        let selection = TaskSelection(primary: 99).selecting(visible: [10, 20, 30])
        XCTAssertNil(selection.primary)
        XCTAssertEqual(selection.ids, Set([10, 20, 30]))
    }

    // MARK: - Prune after refresh/filter

    func testPruneDropsIdsNoLongerAvailable() {
        let selection = TaskSelection(ids: Set([1, 2, 3]), primary: 2)
        let pruned = selection.pruned(available: [1, 3, 5])
        XCTAssertEqual(pruned.ids, Set([1, 3]))
        XCTAssertNil(pruned.primary)
    }

    func testPruneKeepsPrimaryWhenStillAvailable() {
        let selection = TaskSelection(ids: Set([1, 2, 3]), primary: 2)
        let pruned = selection.pruned(available: [2, 5])
        XCTAssertEqual(pruned.ids, Set([2]))
        XCTAssertEqual(pruned.primary, 2)
    }

    func testPruneNeverSelectsHiddenTasks() {
        let selection = TaskSelection(ids: Set([9]), primary: 9)
        let pruned = selection.pruned(available: [])
        XCTAssertTrue(pruned.isEmpty)
        XCTAssertNil(pruned.primary)
    }

    /// Pruning must resolve against the *visible* list, not the full task list.
    /// A cancelled (hidden) id that lingers in the selection must be dropped so
    /// a subsequent Command+A or batch action cannot reach a hidden task.
    func testPruneDropsCancelledHiddenIdsFromVisibleList() {
        let visible: [Int64] = [5, 6, 7]
        let hidden: Int64 = 99
        let selection = TaskSelection(ids: Set([5, hidden, 7]), primary: hidden)
        let pruned = selection.pruned(available: visible)
        XCTAssertEqual(pruned.ids, Set([5, 7]))
        XCTAssertNil(pruned.primary, "a hidden id must never remain the primary")
    }

    /// "All visible selected" is subset semantics: every visible id is in the
    /// selection, regardless of extras. This mirrors the model's
    /// ``visibleTasks.allSatisfy { selectedIDs.contains($0.id) }``. Empty
    /// lists must never report "all selected". A selection it can hold hidden
    /// ids (before pruning) breaks a naive count-equality check but is still
    /// "all selected" in the subset sense.
    func testIsAllSelectedIsSubsetNotCountEquality() {
        let visibleIds: [Int64] = [10, 20, 30]
        func isAllSelected(_ selected: Set<Int64>) -> Bool {
            !visibleIds.isEmpty && visibleIds.allSatisfy { selected.contains($0) }
        }
        XCTAssertTrue(isAllSelected(Set([10, 20, 30])))
        // More selected than visible still counts as "all visible selected".
        XCTAssertTrue(isAllSelected(Set([10, 20, 30, 999])))
        XCTAssertFalse(isAllSelected(Set([10, 20])))
        XCTAssertFalse(isAllSelected(Set([])))
        // The pure selection never reaches the predicate with hidden ids in it:
        // pruning drops them before the check can be asked.
        let pruned = TaskSelection(ids: Set([10, 20, 99])).pruned(available: visibleIds)
        XCTAssertEqual(pruned.ids, Set([10, 20]))
        XCTAssertFalse(isAllSelected(pruned.ids))
    }

    /// The snapshot used by batch actions only ever contains ids from the
    /// visible list; hidden ids are filtered out.
    func testBatchSnapshotExcludesHiddenIds() {
        let selection = TaskSelection(ids: Set([1, 2, 99]))
        let snapshot = selection.snapshot([1, 2, 3])
        XCTAssertEqual(snapshot, [1, 2])
        XCTAssertFalse(snapshot.contains(99))
    }

    /// Primary after a prune must be a visible id picked in visible order, not
    /// an arbitrary Set member.
    func testPruneStabilizesPrimaryAmongVisibleOrder() {
        let selection = TaskSelection(ids: Set([30, 10, 20]), primary: 99)
        let pruned = selection.pruned(available: [10, 20, 30])
        XCTAssertNil(pruned.primary)
        // When the caller restores primary by visible order (as AppModel does
        // via selectedTasks.first), it must be the newest visible id, not a
        // random set iteration.
        let orderedSelection = TaskSelection(ids: Set([30, 10, 20]), primary: nil)
        XCTAssertEqual(orderedSelection.snapshot([10, 20, 30]).first, 10)
    }

    // MARK: - Snapshot preserves visible order

    func testSnapshotFollowsAvailableOrder() {
        let selection = TaskSelection(ids: Set([30, 10, 20]))
        XCTAssertEqual(selection.snapshot([10, 20, 30]), [10, 20, 30])
        XCTAssertEqual(selection.snapshot([]), [])
    }

    // MARK: - Batch action state filtering

    private func assertOnlyTasksWithStatuses(_ statuses: Set<DownloadStatus>, perform filter: (DownloadTask) -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        for (index, status) in DownloadStatus.allCases.enumerated() {
            let id = Int64(index + 1)
            let accepts = filter(task(id, status))
            XCTAssertEqual(accepts, statuses.contains(status), "unexpected filter result for \(status)", file: file, line: line)
        }
    }

    func testStartAcceptsOnlyResumableStates() {
        let accepts = { (t: DownloadTask) -> Bool in t.status.isResumable }
        assertOnlyTasksWithStatuses([.created, .paused, .failed, .stopped], perform: accepts)
    }

    func testPauseAcceptsOnlyActiveStates() {
        let accepts = { (t: DownloadTask) -> Bool in t.status.isActive }
        assertOnlyTasksWithStatuses([.downloading, .merging], perform: accepts)
    }

    func testRetryAcceptsOnlyFailedOrStopped() {
        let accepts = { (t: DownloadTask) -> Bool in t.status == .failed || t.status == .stopped }
        assertOnlyTasksWithStatuses([.failed, .stopped], perform: accepts)
    }

    func testCancelSkipsTerminalStates() {
        let accepts = { (t: DownloadTask) -> Bool in !t.status.isTerminal }
        assertOnlyTasksWithStatuses([.created, .downloading, .paused, .failed, .stopped, .merging], perform: accepts)
    }

    // MARK: - Delete-confirmation finished/unfinished/mixed classification

    func testDeleteClassificationUnfinishedOnly() {
        let summary = DeleteSelectionSummary.classify([task(1, .downloading), task(2, .paused)])
        XCTAssertEqual(summary.ids, [1, 2])
        XCTAssertFalse(summary.hasFinished)
        XCTAssertTrue(summary.hasUnfinished)
    }

    func testDeleteClassificationFinishedOnly() {
        let summary = DeleteSelectionSummary.classify([task(1, .completed), task(2, .completed)])
        XCTAssertTrue(summary.hasFinished)
        XCTAssertFalse(summary.hasUnfinished)
    }

    func testDeleteClassificationMixed() {
        let summary = DeleteSelectionSummary.classify([task(1, .completed), task(2, .downloading)])
        XCTAssertTrue(summary.hasFinished)
        XCTAssertTrue(summary.hasUnfinished)
    }

    func testDeleteClassificationEmpty() {
        let summary = DeleteSelectionSummary.classify([])
        XCTAssertTrue(summary.ids.isEmpty)
        XCTAssertFalse(summary.hasFinished)
        XCTAssertFalse(summary.hasUnfinished)
    }

    // MARK: - Batch skip-vs-aggregate semantics

    private actor PerformedRecorder {
        private(set) var performed: [Int64] = []
        func append(_ id: Int64) { performed.append(id) }
        var values: [Int64] { performed }
    }

    private func recordingResume(_ recorder: PerformedRecorder) -> BatchAction {
        BatchAction(appliesTo: { $0.status.isResumable }, perform: { task in await recorder.append(task.id) })
    }

    func testRunBatchSkipsUnresumableTasksWithoutAggregating() async {
        let recorder = PerformedRecorder()
        let resume = recordingResume(recorder)
        let visible = [task(1, .downloading), task(2, .paused), task(3, .failed), task(4, .completed)]
        let result = await runBatch(resume, ids: Set([1, 2, 3, 4]), visible: visible)
        XCTAssertNil(result, "a task that cannot take the action is skipped, not a failure")
        let values = await recorder.values
        XCTAssertEqual(values, [2, 3])
    }

    func testRunBatchAggregatesGenuineErrorsButContinues() async {
        struct EngineFailure: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        let recorder = PerformedRecorder()
        let logging = BatchAction(appliesTo: { $0.status.isResumable }, perform: { task in
            await recorder.append(task.id)
            if task.id == 2 { throw EngineFailure(message: "boom") }
        })
        let visible = [task(1, .paused), task(2, .failed), task(3, .created)]
        let errors = await runBatch(logging, ids: Set([1, 2, 3]), visible: visible)
        let values = await recorder.values
        XCTAssertEqual(values, [1, 2, 3], "one failure must not abort the remaining legal items")
        XCTAssertEqual(errors?.contains("boom"), true)
    }

    func testRunBatchEmptySelectionReturnsNoFailures() async {
        let resume = BatchAction(appliesTo: { $0.status.isResumable }, perform: { _ in })
        let result = await runBatch(resume, ids: Set<Int64>(), visible: [task(1, .paused)])
        XCTAssertNil(result)
    }

    func testRunBatchOnlyActsOnVisibleIds() async {
        let recorder = PerformedRecorder()
        let resume = recordingResume(recorder)
        // id 2 is hidden: it appears in the snapshot but is absent from the
        // visible list, so the batch must never act on it.
        let visible = [task(1, .paused)]
        let result = await runBatch(resume, ids: Set([1, 2]), visible: visible)
        XCTAssertNil(result)
        let values = await recorder.values
        XCTAssertEqual(values, [1])
    }
}