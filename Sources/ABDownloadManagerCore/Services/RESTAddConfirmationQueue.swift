import Foundation

/// Holds browser/API requests that need a user decision before the app creates
/// a task. Keeping this ordered prevents a burst of selected links from
/// replacing the request already shown in the native add sheet.
public struct RESTAddConfirmationQueue: Sendable {
    private var operations: [RESTAddOperation] = []

    public init() {}

    public var current: RESTAddOperation? { operations.first }
    public var count: Int { operations.count }

    public mutating func enqueue(_ operation: RESTAddOperation) {
        operations.append(operation)
    }

    /// Resolves the visible request, whether the user accepted or cancelled it.
    @discardableResult
    public mutating func resolveCurrent() -> RESTAddOperation? {
        guard !operations.isEmpty else { return nil }
        operations.removeFirst()
        return operations.first
    }
}
