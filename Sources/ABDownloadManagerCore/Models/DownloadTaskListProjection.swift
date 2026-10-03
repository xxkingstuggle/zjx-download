import Foundation

/// A materialized list projection so SwiftUI table body reads do not sort and
/// filter the entire task collection repeatedly on every unrelated update.
public struct DownloadTaskListProjection: Sendable, Equatable {
    public let visible: [DownloadTask]
    public let filtered: [DownloadTask]

    public init(
        tasks: [DownloadTask],
        search: String = "",
        status: String = "all",
        categoryID: Int64? = nil,
        queueID: Int64? = nil,
        sortField: String = "createdAt",
        sortAscending: Bool = false
    ) {
        var ordered = tasks.contains(where: { $0.status == .cancelled })
            ? tasks.filter { $0.status != .cancelled }
            : tasks
        ordered.sort { lhs, rhs in
            let comparison: ComparisonResult = switch sortField {
            case "fileName": lhs.fileName.localizedStandardCompare(rhs.fileName)
            case "status": lhs.status.rawValue.localizedStandardCompare(rhs.status.rawValue)
            case "downloadedSize": lhs.downloadedSize == rhs.downloadedSize ? .orderedSame : (lhs.downloadedSize < rhs.downloadedSize ? .orderedAscending : .orderedDescending)
            case "connectionCount": lhs.connectionCount == rhs.connectionCount ? .orderedSame : (lhs.connectionCount < rhs.connectionCount ? .orderedAscending : .orderedDescending)
            case "startedAt": Self.compare(lhs.startedAt, rhs.startedAt)
            case "completedAt": Self.compare(lhs.completedAt, rhs.completedAt)
            default: lhs.createdAt == rhs.createdAt ? .orderedSame : (lhs.createdAt < rhs.createdAt ? .orderedAscending : .orderedDescending)
            }
            if comparison != .orderedSame { return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending }
            return sortAscending ? lhs.id < rhs.id : lhs.id > rhs.id
        }
        visible = ordered

        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let needsFilter = !query.isEmpty || status != "all" || categoryID != nil || queueID != nil
        guard needsFilter else {
            filtered = ordered
            return
        }
        filtered = ordered.filter { task in
            (query.isEmpty
                || task.fileName.lowercased().contains(query)
                || task.source.url.absoluteString.lowercased().contains(query)
                || task.errorMessage?.lowercased().contains(query) == true)
                && (status == "all" || task.status.rawValue == status)
                && (categoryID == nil || task.categoryID == categoryID)
                && (queueID == nil || task.queueID == queueID)
        }
    }

    private static func compare(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (left?, right?): left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        case (nil, nil): .orderedSame
        case (nil, _?): .orderedAscending
        case (_?, nil): .orderedDescending
        }
    }
}
