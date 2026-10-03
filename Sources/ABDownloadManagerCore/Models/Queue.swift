import Foundation

/// A download queue: an ordered group of tasks sharing a concurrency policy.
public struct DownloadQueue: Codable, Sendable, Identifiable, Hashable {
    public var id: Int64
    public var name: String
    /// Ordering index used by the sidebar; lower sorts first.
    public var order: Int
    /// When true the scheduler is allowed to start tasks in this queue.
    public var isRunning: Bool
    /// Max simultaneous downloads inside this queue.
    public var concurrencyLimit: Int
    /// Optional schedule window; `nil` means "always allowed".
    public var schedule: QueueSchedule?
    public var completionAction: QueueCompletionAction

    public init(
        id: Int64 = 0,
        name: String,
        order: Int = 0,
        isRunning: Bool = true,
        concurrencyLimit: Int = 1,
        schedule: QueueSchedule? = nil,
        completionAction: QueueCompletionAction = .none
    ) {
        self.id = id
        self.name = name
        self.order = order
        self.isRunning = isRunning
        self.concurrencyLimit = concurrencyLimit
        self.schedule = schedule
        self.completionAction = completionAction
    }
}

/// A recurring time window during which a queue may run.
public struct QueueSchedule: Codable, Sendable, Hashable {
    /// Days the schedule applies to.
    public var weekdays: Set<Weekday>
    /// Seconds since local midnight when the window opens.
    public var startSeconds: Int
    /// Seconds since local midnight when the window closes. May be less than
    /// `startSeconds`, which denotes a window crossing midnight.
    public var endSeconds: Int
    public var isEnabled: Bool

    public init(
        weekdays: Set<Weekday> = Set(Weekday.allCases),
        startSeconds: Int = 0,
        endSeconds: Int = 24 * 3600 - 1,
        isEnabled: Bool = true
    ) {
        self.weekdays = weekdays
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.isEnabled = isEnabled
    }

    public enum Weekday: String, Codable, Sendable, CaseIterable, Hashable {
        case sunday, monday, tuesday, wednesday, thursday, friday, saturday
    }

    /// Whether `date` falls inside the window, evaluated in the given calendar.
    public func isOpen(at date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return true }
        let components = calendar.dateComponents([.weekday, .hour, .minute, .second], from: date)
        guard let weekdayNumber = components.weekday,
              let hour = components.hour,
              let minute = components.minute,
              let second = components.second
        else { return true }

        let secondsOfDay = hour * 3600 + minute * 60 + second
        // Calendar weekdays are 1...7 starting Sunday.
        let weekday = Weekday.allCases[weekdayNumber - 1]

        if startSeconds <= endSeconds {
            return weekdays.contains(weekday)
                && secondsOfDay >= startSeconds
                && secondsOfDay <= endSeconds
        }
        // Window crosses midnight: it opens today and closes tomorrow, so the
        // tail belongs to the following weekday.
        if secondsOfDay >= startSeconds {
            return weekdays.contains(weekday)
        }
        if secondsOfDay <= endSeconds {
            let previous = Weekday.allCases[(weekdayNumber - 2 + 7) % 7]
            return weekdays.contains(previous)
        }
        return false
    }
}

/// A user-defined grouping for downloads (the original's "categories").
public struct DownloadCategory: Codable, Sendable, Identifiable, Hashable {
    public var id: Int64
    public var name: String
    public var order: Int
    public var acceptedFileTypes: [String]
    public var acceptedURLPatterns: [String]
    public var categoryPath: String?
    public var icon: String

    public init(id: Int64 = 0, name: String, order: Int = 0, acceptedFileTypes: [String] = [], acceptedURLPatterns: [String] = [], categoryPath: String? = nil, icon: String = "folder") {
        self.id = id; self.name = name; self.order = order
        self.acceptedFileTypes = acceptedFileTypes; self.acceptedURLPatterns = acceptedURLPatterns; self.categoryPath = categoryPath; self.icon = icon
    }
}

/// A finished (completed, failed or cancelled) download kept for history.
public struct DownloadRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: Int64
    public var taskID: Int64
    public var name: String
    public var url: String
    public var folderPath: String
    public var fileName: String
    public var finalStatus: DownloadStatus
    public var totalSize: Int64?
    public var downloadedSize: Int64
    public var startedAt: Date?
    public var finishedAt: Date
    public var errorMessage: String?
    public var checksum: String?

    public init(
        id: Int64 = 0,
        taskID: Int64,
        name: String,
        url: String,
        folderPath: String,
        fileName: String,
        finalStatus: DownloadStatus,
        totalSize: Int64?,
        downloadedSize: Int64,
        startedAt: Date?,
        finishedAt: Date,
        errorMessage: String? = nil,
        checksum: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.name = name
        self.url = url
        self.folderPath = folderPath
        self.fileName = fileName
        self.finalStatus = finalStatus
        self.totalSize = totalSize
        self.downloadedSize = downloadedSize
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.checksum = checksum
    }
}

extension DownloadCategory {
    private enum CodingKeys: String, CodingKey { case id, name, order, acceptedFileTypes, acceptedURLPatterns, categoryPath, icon }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id); name = try c.decode(String.self, forKey: .name); order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        acceptedFileTypes = try c.decodeIfPresent([String].self, forKey: .acceptedFileTypes) ?? []
        acceptedURLPatterns = try c.decodeIfPresent([String].self, forKey: .acceptedURLPatterns) ?? []
        categoryPath = try c.decodeIfPresent(String.self, forKey: .categoryPath)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "folder"
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(order, forKey: .order); try c.encode(acceptedFileTypes, forKey: .acceptedFileTypes); try c.encode(acceptedURLPatterns, forKey: .acceptedURLPatterns); try c.encodeIfPresent(categoryPath, forKey: .categoryPath); try c.encode(icon, forKey: .icon)
    }
}

public enum QueueCompletionAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case quitApplication
    case sleepComputer
    case shutDownComputer
    public var id: String { rawValue }
    public var isPowerAction: Bool { self != .none }
}


extension DownloadQueue {
    private enum CodingKeys: String, CodingKey { case id, name, order, isRunning, concurrencyLimit, schedule, completionAction }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(Int64.self, forKey: .id); name = try c.decode(String.self, forKey: .name); order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0; isRunning = try c.decodeIfPresent(Bool.self, forKey: .isRunning) ?? true; concurrencyLimit = try c.decodeIfPresent(Int.self, forKey: .concurrencyLimit) ?? 1; schedule = try c.decodeIfPresent(QueueSchedule.self, forKey: .schedule); completionAction = try c.decodeIfPresent(QueueCompletionAction.self, forKey: .completionAction) ?? .none }
    public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(order, forKey: .order); try c.encode(isRunning, forKey: .isRunning); try c.encode(concurrencyLimit, forKey: .concurrencyLimit); try c.encodeIfPresent(schedule, forKey: .schedule); try c.encode(completionAction, forKey: .completionAction) }
}
