import Foundation

/// Pure selection model over download task ids, mirroring the original's
/// `BaseHomeComponent` selection-list semantics: selection always resolves
/// against the *current visible* task list, dangling ids are pruned on every
/// refresh, and "select all" can only ever select what is currently visible.
///
/// The set deliberately lives outside SwiftUI so the same rules can be unit
/// tested without a scene and without needing model plumbing.
public struct TaskSelection: Hashable, Equatable {
    public var ids: Set<Int64>
    /// The id the UI treats as primary (inspector anchor / double-click target).
    public var primary: Int64?

    public init(ids: Set<Int64> = Set<Int64>(), primary: Int64? = nil) {
        self.ids = ids
        self.primary = primary
    }

    /// Whether `id` is currently selected.
    public func contains(_ id: Int64) -> Bool {
        ids.contains(id)
    }

    public var count: Int {
        ids.count
    }

    public var isEmpty: Bool {
        ids.isEmpty
    }

    /// Replaces the selection with exactly the ids of `visible` and keeps the
    /// current primary when still visible. Returns a new selection value; the
    /// caller is responsible for assigning it back.
    public func selecting(visible: [Int64]) -> TaskSelection {
        var next = Set<Int64>()
        for id in visible {
            next.insert(id)
        }
        return TaskSelection(ids: next, primary: Self.containsPrimary(primary, in: next))
    }

    /// Toggles `id`. The primary becomes `id` when it is now selected, and is
    /// cleared when the toggled id was the primary and got deselected.
    public func toggling(_ id: Int64) -> TaskSelection {
        var next = ids
        let isSelected = next.contains(id)
        if isSelected {
            next.remove(id)
        } else {
            next.insert(id)
        }
        return TaskSelection(ids: next, primary: Self.selectionPrimary(next, primary, id))
    }

    /// Removes ids no longer present in `available` (e.g. after a refresh or
    /// a task deletion). Returns a new selection value.
    public func pruned(available: [Int64]) -> TaskSelection {
        var valid = Set<Int64>()
        for id in available {
            if ids.contains(id) {
                valid.insert(id)
            }
        }
        return TaskSelection(ids: valid, primary: Self.containsPrimary(primary, in: valid))
    }

    /// Snapshot of ids in `available` order, sorted the same way as the visible
    /// list so callers can act on the same deterministic set.
    public func snapshot(_ available: [Int64]) -> [Int64] {
        available.filter { ids.contains($0) }
    }

    private static func containsPrimary(_ primary: Int64?, in set: Set<Int64>) -> Int64? {
        guard let primary, set.contains(primary) else { return nil }
        return primary
    }

    /// Decides the next primary when toggling `id`: an explicit toggle of `id`
    /// makes it primary when selected, otherwise the previous primary wins when
    /// it remains selected.
    private static func selectionPrimary(_ next: Set<Int64>, _ previous: Int64?, _ toggled: Int64) -> Int64? {
        if next.contains(toggled) {
            return toggled
        }
        guard let previous, next.contains(previous) else { return nil }
        return previous
    }
}

/// Pure classification of a multi-delete request, mirroring the original's
/// "confirm delete" dialog which distinguishes finished, unfinished and mixed
/// selections so the UI can offer "also delete files from disk" only when a
/// completed file would be affected.
public struct DeleteSelectionSummary: Hashable, Equatable {
    public let ids: [Int64]
    public let hasFinished: Bool
    public let hasUnfinished: Bool

    public init(ids: [Int64], hasFinished: Bool, hasUnfinished: Bool) {
        self.ids = ids
        self.hasFinished = hasFinished
        self.hasUnfinished = hasUnfinished
    }

    public static func classify(_ tasks: [DownloadTask]) -> DeleteSelectionSummary {
        DeleteSelectionSummary(
            ids: tasks.map(\.id),
            hasFinished: tasks.contains { $0.status == .completed },
            hasUnfinished: tasks.contains { $0.status != .completed }
        )
    }
}

/// Declarative description of one batch action (start/resume/pause/retry/
/// cancel). Separating the "which states are legal" test from the engine call
/// lets the batch runner skip invalid-state tasks without treating them as
/// failures — matching upstream's `runCatching` per-item guards — while still
/// letting a genuine engine/store error be reported.
public struct BatchAction: Sendable {
    public let appliesTo: @Sendable (DownloadTask) -> Bool
    public let perform: @Sendable (DownloadTask) async throws -> Void

    public init(
        appliesTo: @escaping @Sendable (DownloadTask) -> Bool,
        perform: @escaping @Sendable (DownloadTask) async throws -> Void
    ) {
        self.appliesTo = appliesTo
        self.perform = perform
    }

    public static func simple(
        appliesTo: @escaping @Sendable (DownloadTask) -> Bool,
        perform: @escaping @Sendable (DownloadTask) async throws -> Void
    ) -> BatchAction {
        BatchAction(appliesTo: appliesTo, perform: perform)
    }
}

/// Runs `action` over the visible tasks for `ids`, skipping those `action`
/// does not apply to (their rejection is not a failure) and collecting genuine
/// thrown errors without letting one abort the rest. Returns the aggregate
/// error text the UI should display, or `nil` when everything succeeded.
///
/// This is the pure, engine-free core of the app's `AppModel.batch`; keeping
/// it here lets the skip-vs-aggregate semantics be unit tested directly.
public func runBatch(
    _ action: BatchAction,
    ids: Set<Int64>,
    visible: [DownloadTask]
) async -> String? {
    guard !ids.isEmpty else { return nil }
    let tasks = visible.filter { ids.contains($0.id) }
    guard !tasks.isEmpty else { return nil }
    var failures: [String] = []
    for task in tasks {
        guard action.appliesTo(task) else { continue }
        do {
            try await action.perform(task)
        } catch {
            failures.append("\(task.fileName): \(error.localizedDescription)")
            continue
        }
    }
    return failures.isEmpty ? nil : failures.joined(separator: "\n")
}