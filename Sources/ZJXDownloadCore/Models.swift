import Foundation

public enum ProductIdentity {
    public static let name = "zjx-download"
    public static let bundleID = "com.zjx.download"
    public static let version = "2.0.1"
    public static let nativeHostName = "com.zjx.download"
    public static let defaultPort = 15151
}

public enum ByteFormatting {
    public static func size(_ bytes: Int64, unit: String) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: unit == "decimal" ? .file : .binary)
    }

    public static func speed(_ bytesPerSecond: Int64, unit: String) -> String {
        guard unit == "bits" || unit == "decimal-bits" else {
            return ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: unit == "decimal" ? .file : .binary) + "/s"
        }
        let base = unit == "decimal-bits" ? 1_000.0 : 1_024.0
        let names = unit == "decimal-bits" ? ["bit/s", "kbit/s", "Mbit/s", "Gbit/s", "Tbit/s"]
            : ["bit/s", "Kibit/s", "Mibit/s", "Gibit/s", "Tibit/s"]
        var value = Double(max(0, bytesPerSecond)) * 8
        var index = 0
        while value >= base && index < names.count - 1 { value /= base; index += 1 }
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = index == 0 ? 0 : 1
        formatter.minimumFractionDigits = 0
        return "\(formatter.string(from: NSNumber(value: value)) ?? String(value)) \(names[index])"
    }

    public static func speedUnitLabel(_ unit: String) -> String {
        switch unit {
        case "decimal": "KB/s"
        case "bits": "Kibit/s"
        case "decimal-bits": "kbit/s"
        default: "KiB/s"
        }
    }

    public static func speedLimitInput(bytesPerSecond: Int64, unit: String) -> String {
        let factor: Decimal = switch unit {
        case "decimal": 1_000
        case "bits": 128
        case "decimal-bits": 125
        default: 1_024
        }
        let value = Decimal(max(0, bytesPerSecond)) / factor
        return NSDecimalNumber(decimal: value).stringValue
    }

    public static func parseSpeedLimit(_ input: String, unit: String) -> Int64? {
        guard let value = Decimal(string: input.trimmingCharacters(in: .whitespacesAndNewlines),
                                  locale: Locale(identifier: "en_US_POSIX")), value >= 0 else { return nil }
        let factor: Decimal = switch unit {
        case "decimal": 1_000
        case "bits": 128
        case "decimal-bits": 125
        default: 1_024
        }
        let bytes = value * factor
        var rounded = Decimal()
        var mutableBytes = bytes
        NSDecimalRound(&rounded, &mutableBytes, 0, .plain)
        guard rounded == bytes, rounded <= Decimal(Int64.max) else { return nil }
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}

public enum DownloadStatus: String, Codable, CaseIterable, Sendable {
    case queued, preparing, downloading, paused, failed, completed, cancelled

    public var isActive: Bool { self == .preparing || self == .downloading }
    public var canResume: Bool { self == .paused || self == .failed || self == .queued }
    public var title: String {
        switch self {
        case .queued: "等待中"
        case .preparing: "准备中"
        case .downloading: "下载中"
        case .paused: "已暂停"
        case .failed: "错误"
        case .completed: "已完成"
        case .cancelled: "已取消"
        }
    }
}

public enum TransferKind: String, Codable, CaseIterable, Sendable { case http, hls }
public enum ConflictPolicy: String, Codable, CaseIterable, Sendable { case rename, replace, cancel }
public enum AppearanceChoice: String, Codable, CaseIterable, Sendable { case system, light, dark }
public enum ProxyMode: String, Codable, CaseIterable, Sendable { case direct, system, manual, pac }
public enum ProxyScheme: String, Codable, CaseIterable, Sendable { case http, https, socks5 }
public enum DNSMode: String, Codable, CaseIterable, Sendable { case system, doh }
public enum GlobalSpeedLimitMode: String, Codable, CaseIterable, Sendable { case off, always, backgroundInteraction }
public enum CompletionAction: String, Codable, CaseIterable, Sendable { case none, quit, sleep, shutdown }

public struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64
    public var kind: TransferKind
    public var sourceURL: String
    public var pageURL: String?
    public var displayName: String
    public var destinationDirectory: String
    public var status: DownloadStatus
    public var totalBytes: Int64?
    public var receivedBytes: Int64
    public var etag: String?
    public var lastModified: String?
    public var supportsRanges: Bool?
    public var resumeDataName: String?
    public var credentialAccount: String?
    public var requestHeaders: [String: String]
    public var categoryID: Int64?
    public var queueID: Int64?
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var lastError: String?
    public var retryCount: Int
    public var expectedChecksum: String?
    public var actualChecksum: String?
    public var speedLimitBytesPerSecond: Int64
    public var connectionCount: Int?
    public var conflictPolicy: ConflictPolicy
    public var removePartialOnCancel: Bool
    public var sourceDescription: String?
    public var importedFromLegacy: Bool
    public var legacyRecoveryNote: String?
    public var showProgressWindow: Bool?
    public var showCompletionWindow: Bool?
    public var completionAction: CompletionAction?

    public init(id: Int64, kind: TransferKind = .http, sourceURL: String, pageURL: String? = nil,
                displayName: String, destinationDirectory: String, status: DownloadStatus = .queued,
                totalBytes: Int64? = nil, receivedBytes: Int64 = 0, etag: String? = nil,
                lastModified: String? = nil, supportsRanges: Bool? = nil, resumeDataName: String? = nil,
                credentialAccount: String? = nil, requestHeaders: [String: String] = [:], categoryID: Int64? = nil, queueID: Int64? = 0,
                createdAt: Date = .now, startedAt: Date? = nil, completedAt: Date? = nil,
                lastError: String? = nil, retryCount: Int = 0, expectedChecksum: String? = nil,
                actualChecksum: String? = nil, speedLimitBytesPerSecond: Int64 = 0,
                conflictPolicy: ConflictPolicy = .rename, removePartialOnCancel: Bool = false,
                sourceDescription: String? = nil, importedFromLegacy: Bool = false,
                legacyRecoveryNote: String? = nil, connectionCount: Int? = nil,
                showProgressWindow: Bool? = nil, showCompletionWindow: Bool? = nil,
                completionAction: CompletionAction? = nil) {
        self.id = id
        self.kind = kind
        self.sourceURL = sourceURL
        self.pageURL = pageURL
        self.displayName = displayName
        self.destinationDirectory = destinationDirectory
        self.status = status
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.etag = etag
        self.lastModified = lastModified
        self.supportsRanges = supportsRanges
        self.resumeDataName = resumeDataName
        self.credentialAccount = credentialAccount
        self.requestHeaders = requestHeaders
        self.categoryID = categoryID
        self.queueID = queueID
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.lastError = lastError
        self.retryCount = retryCount
        self.expectedChecksum = expectedChecksum
        self.actualChecksum = actualChecksum
        self.speedLimitBytesPerSecond = speedLimitBytesPerSecond
        self.connectionCount = connectionCount
        self.conflictPolicy = conflictPolicy
        self.removePartialOnCancel = removePartialOnCancel
        self.sourceDescription = sourceDescription
        self.importedFromLegacy = importedFromLegacy
        self.legacyRecoveryNote = legacyRecoveryNote
        self.showProgressWindow = showProgressWindow
        self.showCompletionWindow = showCompletionWindow
        self.completionAction = completionAction
    }

    public var outputURL: URL { URL(fileURLWithPath: destinationDirectory, isDirectory: true).appendingPathComponent(displayName) }
    public var progress: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}

public struct CategoryRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var symbol: String
    public var extensions: [String]
    public var urlPatterns: [String]
    public var destinationDirectory: String?
    public var order: Int

    public init(id: Int64, name: String, symbol: String = "folder", extensions: [String] = [],
                urlPatterns: [String] = [], destinationDirectory: String? = nil, order: Int = 0) {
        self.id = id; self.name = name; self.symbol = symbol; self.extensions = extensions
        self.urlPatterns = urlPatterns; self.destinationDirectory = destinationDirectory; self.order = order
    }

    public func matches(url: URL, fileName: String) -> Bool {
        let extMatch = extensions.isEmpty || extensions.contains { fileName.lowercased().hasSuffix("." + $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
        let urlMatch = urlPatterns.isEmpty || urlPatterns.contains { wildcard($0, value: url.absoluteString) }
        return (!extensions.isEmpty || !urlPatterns.isEmpty) && extMatch && urlMatch
    }

    private func wildcard(_ pattern: String, value: String) -> Bool {
        let pieces = pattern.lowercased().split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var cursor = value.lowercased().startIndex
        let lower = value.lowercased()
        for (index, piece) in pieces.enumerated() {
            guard let found = lower.range(of: piece, range: cursor..<lower.endIndex) else { return false }
            if index == 0 && found.lowerBound != lower.startIndex { return false }
            cursor = found.upperBound
        }
        return pattern.hasSuffix("*") || cursor == lower.endIndex
    }
}

public struct QueueSchedule: Codable, Hashable, Sendable {
    public var days: Set<Int>
    public var startEnabled: Bool
    public var startHour: Int
    public var startMinute: Int
    public var stopEnabled: Bool
    public var stopHour: Int
    public var stopMinute: Int
    public var stopWhenEmpty: Bool

    public init(days: Set<Int> = Set(1...7), startEnabled: Bool = false, startHour: Int = 2, startMinute: Int = 30,
                stopEnabled: Bool = false, stopHour: Int = 7, stopMinute: Int = 30, stopWhenEmpty: Bool = false) {
        self.days = days; self.startEnabled = startEnabled; self.startHour = startHour; self.startMinute = startMinute
        self.stopEnabled = stopEnabled; self.stopHour = stopHour; self.stopMinute = stopMinute; self.stopWhenEmpty = stopWhenEmpty
    }
}

public struct QueueRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var taskIDs: [Int64]
    public var concurrency: Int
    public var isRunning: Bool
    public var schedule: QueueSchedule
    public var completionAction: CompletionAction
    public var order: Int

    public init(id: Int64, name: String, taskIDs: [Int64] = [], concurrency: Int = 2, isRunning: Bool = false,
                schedule: QueueSchedule = QueueSchedule(), completionAction: CompletionAction = .none, order: Int = 0) {
        self.id = id; self.name = name; self.taskIDs = taskIDs; self.concurrency = concurrency
        self.isRunning = isRunning; self.schedule = schedule; self.completionAction = completionAction; self.order = order
    }
}

public struct HostRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var pattern: String
    public var userAgent: String
    public var headers: [String: String]
    public var credentialAccount: String?
    public var speedLimitBytesPerSecond: Int64
    public var connectionCount: Int?

    public init(id: UUID = UUID(), pattern: String, userAgent: String = "", headers: [String: String] = [:],
                credentialAccount: String? = nil, speedLimitBytesPerSecond: Int64 = 0, connectionCount: Int? = nil) {
        self.id = id; self.pattern = pattern; self.userAgent = userAgent; self.headers = headers
        self.credentialAccount = credentialAccount; self.speedLimitBytesPerSecond = speedLimitBytesPerSecond
        self.connectionCount = connectionCount
    }
}

public struct ExtensionSettings: Codable, Hashable, Sendable {
    public var autoCapture: Bool
    public var showPageWidgets: Bool
    public var sendRequestHeaders: Bool
    public var silentAdd: Bool
    public var silentStart: Bool
    public var closeCapturedTab: Bool
    public var bypassKey: String
    public var minimumSizeKB: Int
    public var extensions: [String]
    public var ignoredPatterns: [String]
    public var apiPort: Int
    public var requestHeaderPermissionGranted: Bool

    public init(autoCapture: Bool = true, showPageWidgets: Bool = true, sendRequestHeaders: Bool = false,
                silentAdd: Bool = false, silentStart: Bool = false, closeCapturedTab: Bool = true,
                bypassKey: String = "Backspace", minimumSizeKB: Int = 0,
                extensions: [String] = ["zip", "rar", "7z", "iso", "tar", "gz", "exe", "msi", "deb", "jar", "apk", "bin", "mp3", "aac", "pdf", "mp4", "3gp", "avi", "mkv", "wav", "mpeg", "srt"],
                ignoredPatterns: [String] = [], apiPort: Int = ProductIdentity.defaultPort,
                requestHeaderPermissionGranted: Bool = false) {
        self.autoCapture = autoCapture; self.showPageWidgets = showPageWidgets; self.sendRequestHeaders = sendRequestHeaders
        self.silentAdd = silentAdd; self.silentStart = silentStart; self.closeCapturedTab = closeCapturedTab
        self.bypassKey = bypassKey; self.minimumSizeKB = minimumSizeKB; self.extensions = extensions
        self.ignoredPatterns = ignoredPatterns; self.apiPort = apiPort; self.requestHeaderPermissionGranted = requestHeaderPermissionGranted
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var defaultDownloadDirectory: String
    public var appearance: AppearanceChoice
    public var theme: String
    public var language: String
    public var fontName: String?
    public var sizeUnit: String
    public var speedUnit: String
    public var averageSpeedEnabled: Bool
    public var scalePercent: Int
    public var autoCategorizeNewDownloads: Bool
    public var compactToolbar: Bool
    public var showToolbarLabels: Bool
    public var useRelativeDates: Bool
    public var maxManualDownloads: Int
    public var maximumRetries: Int
    public var retryDelaySeconds: Int
    public var globalSpeedLimitBytesPerSecond: Int64
    public var globalSpeedLimitMode: GlobalSpeedLimitMode
    public var defaultConnectionCount: Int
    public var minimumSegmentSizeBytes: Int64
    public var dynamicSegmentation: Bool
    public var sparseFiles: Bool
    public var useServerTimestamp: Bool
    public var deletePartialOnCancel: Bool
    public var trackDeletedFiles: Bool
    public var preventSleepDuringTransfers: Bool
    public var allowInvalidTLSCertificates: Bool
    public var userAgent: String
    public var proxyMode: ProxyMode
    public var proxyScheme: ProxyScheme
    public var proxyHost: String
    public var proxyPort: Int
    public var proxyUsername: String
    public var proxyPasswordAccount: String
    public var proxyBypass: [String]
    public var pacURL: String
    public var dnsMode: DNSMode
    public var dohURL: String
    public var apiEnabled: Bool
    public var apiPort: Int
    public var apiRequiresKey: Bool
    public var apiKeyAccount: String
    public var hostRules: [HostRule]
    public var extensionSettings: ExtensionSettings
    public var showProgressWindow: Bool
    public var showCompletionWindow: Bool
    public var soundEnabled: Bool
    public var normalSoundPath: String
    public var successSoundPath: String
    public var errorSoundPath: String
    public var systemNotificationsEnabled: Bool
    public var loginItemEnabled: Bool
    public var menuBarEnabled: Bool
    public var lastUsedQueueID: Int64?
    public var updatesEnabled: Bool
    public var updateManifestURL: String
    public var lastUpdateCheck: Date?

    public init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        defaultDownloadDirectory = downloads.appendingPathComponent("zjx-download", isDirectory: true).path
        appearance = .system; theme = "Dark"; language = "system"; fontName = nil
        sizeUnit = "binary"; speedUnit = "bytes"; averageSpeedEnabled = true; scalePercent = 100
        autoCategorizeNewDownloads = true
        compactToolbar = true; showToolbarLabels = true; useRelativeDates = true
        maxManualDownloads = 3; maximumRetries = 3; retryDelaySeconds = 3; globalSpeedLimitBytesPerSecond = 0; globalSpeedLimitMode = .off
        defaultConnectionCount = 4; minimumSegmentSizeBytes = 1_048_576; dynamicSegmentation = true
        sparseFiles = true; useServerTimestamp = false; deletePartialOnCancel = false
        trackDeletedFiles = false; preventSleepDuringTransfers = true; allowInvalidTLSCertificates = false; userAgent = ""
        proxyMode = .system; proxyScheme = .http; proxyHost = ""; proxyPort = 0; proxyUsername = ""; proxyPasswordAccount = "proxy-password"; proxyBypass = []; pacURL = ""
        dnsMode = .system; dohURL = ""; apiEnabled = true; apiPort = ProductIdentity.defaultPort; apiRequiresKey = false
        apiKeyAccount = "integration-api-key"; hostRules = []; extensionSettings = ExtensionSettings()
        showProgressWindow = true; showCompletionWindow = true; soundEnabled = true
        normalSoundPath = ""; successSoundPath = ""; errorSoundPath = ""
        systemNotificationsEnabled = false
        loginItemEnabled = false; menuBarEnabled = true
        lastUsedQueueID = nil
        updatesEnabled = false; updateManifestURL = ""; lastUpdateCheck = nil
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case defaultDownloadDirectory, appearance, theme, language, fontName, sizeUnit, speedUnit, averageSpeedEnabled, scalePercent, autoCategorizeNewDownloads, compactToolbar, showToolbarLabels, useRelativeDates, maxManualDownloads, maximumRetries, retryDelaySeconds, globalSpeedLimitBytesPerSecond, globalSpeedLimitMode, defaultConnectionCount, minimumSegmentSizeBytes, dynamicSegmentation, sparseFiles, useServerTimestamp, deletePartialOnCancel, trackDeletedFiles, preventSleepDuringTransfers, allowInvalidTLSCertificates, userAgent, proxyMode, proxyScheme, proxyHost, proxyPort, proxyUsername, proxyPasswordAccount, proxyBypass, pacURL, dnsMode, dohURL, apiEnabled, apiPort, apiRequiresKey, apiKeyAccount, hostRules, extensionSettings, showProgressWindow, showCompletionWindow, soundEnabled, normalSoundPath, successSoundPath, errorSoundPath, systemNotificationsEnabled, loginItemEnabled, menuBarEnabled, lastUsedQueueID, updatesEnabled, updateManifestURL, lastUpdateCheck
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultDownloadDirectory = try c.decodeIfPresent(String.self, forKey: .defaultDownloadDirectory) ?? defaultDownloadDirectory
        appearance = try c.decodeIfPresent(AppearanceChoice.self, forKey: .appearance) ?? appearance
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? theme
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? fontName
        sizeUnit = try c.decodeIfPresent(String.self, forKey: .sizeUnit) ?? sizeUnit
        speedUnit = try c.decodeIfPresent(String.self, forKey: .speedUnit) ?? speedUnit
        averageSpeedEnabled = try c.decodeIfPresent(Bool.self, forKey: .averageSpeedEnabled) ?? averageSpeedEnabled
        scalePercent = try c.decodeIfPresent(Int.self, forKey: .scalePercent) ?? scalePercent
        autoCategorizeNewDownloads = try c.decodeIfPresent(Bool.self, forKey: .autoCategorizeNewDownloads) ?? autoCategorizeNewDownloads
        compactToolbar = try c.decodeIfPresent(Bool.self, forKey: .compactToolbar) ?? compactToolbar
        showToolbarLabels = try c.decodeIfPresent(Bool.self, forKey: .showToolbarLabels) ?? showToolbarLabels
        useRelativeDates = try c.decodeIfPresent(Bool.self, forKey: .useRelativeDates) ?? useRelativeDates
        maxManualDownloads = try c.decodeIfPresent(Int.self, forKey: .maxManualDownloads) ?? maxManualDownloads
        maximumRetries = try c.decodeIfPresent(Int.self, forKey: .maximumRetries) ?? maximumRetries
        retryDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .retryDelaySeconds) ?? retryDelaySeconds
        globalSpeedLimitBytesPerSecond = try c.decodeIfPresent(Int64.self, forKey: .globalSpeedLimitBytesPerSecond) ?? globalSpeedLimitBytesPerSecond
        globalSpeedLimitMode = try c.decodeIfPresent(GlobalSpeedLimitMode.self, forKey: .globalSpeedLimitMode) ?? globalSpeedLimitMode
        defaultConnectionCount = try c.decodeIfPresent(Int.self, forKey: .defaultConnectionCount) ?? defaultConnectionCount
        minimumSegmentSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .minimumSegmentSizeBytes) ?? minimumSegmentSizeBytes
        dynamicSegmentation = try c.decodeIfPresent(Bool.self, forKey: .dynamicSegmentation) ?? dynamicSegmentation
        sparseFiles = try c.decodeIfPresent(Bool.self, forKey: .sparseFiles) ?? sparseFiles
        useServerTimestamp = try c.decodeIfPresent(Bool.self, forKey: .useServerTimestamp) ?? useServerTimestamp
        deletePartialOnCancel = try c.decodeIfPresent(Bool.self, forKey: .deletePartialOnCancel) ?? deletePartialOnCancel
        trackDeletedFiles = try c.decodeIfPresent(Bool.self, forKey: .trackDeletedFiles) ?? trackDeletedFiles
        preventSleepDuringTransfers = try c.decodeIfPresent(Bool.self, forKey: .preventSleepDuringTransfers) ?? preventSleepDuringTransfers
        allowInvalidTLSCertificates = try c.decodeIfPresent(Bool.self, forKey: .allowInvalidTLSCertificates) ?? allowInvalidTLSCertificates
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? userAgent
        proxyMode = try c.decodeIfPresent(ProxyMode.self, forKey: .proxyMode) ?? proxyMode
        proxyScheme = try c.decodeIfPresent(ProxyScheme.self, forKey: .proxyScheme) ?? proxyScheme
        proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost) ?? proxyHost
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? proxyPort
        proxyUsername = try c.decodeIfPresent(String.self, forKey: .proxyUsername) ?? proxyUsername
        proxyPasswordAccount = try c.decodeIfPresent(String.self, forKey: .proxyPasswordAccount) ?? proxyPasswordAccount
        proxyBypass = try c.decodeIfPresent([String].self, forKey: .proxyBypass) ?? proxyBypass
        pacURL = try c.decodeIfPresent(String.self, forKey: .pacURL) ?? pacURL
        dnsMode = try c.decodeIfPresent(DNSMode.self, forKey: .dnsMode) ?? dnsMode
        dohURL = try c.decodeIfPresent(String.self, forKey: .dohURL) ?? dohURL
        apiEnabled = try c.decodeIfPresent(Bool.self, forKey: .apiEnabled) ?? apiEnabled
        apiPort = try c.decodeIfPresent(Int.self, forKey: .apiPort) ?? apiPort
        apiRequiresKey = try c.decodeIfPresent(Bool.self, forKey: .apiRequiresKey) ?? apiRequiresKey
        apiKeyAccount = try c.decodeIfPresent(String.self, forKey: .apiKeyAccount) ?? apiKeyAccount
        hostRules = try c.decodeIfPresent([HostRule].self, forKey: .hostRules) ?? hostRules
        extensionSettings = try c.decodeIfPresent(ExtensionSettings.self, forKey: .extensionSettings) ?? extensionSettings
        showProgressWindow = try c.decodeIfPresent(Bool.self, forKey: .showProgressWindow) ?? showProgressWindow
        showCompletionWindow = try c.decodeIfPresent(Bool.self, forKey: .showCompletionWindow) ?? showCompletionWindow
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? soundEnabled
        normalSoundPath = try c.decodeIfPresent(String.self, forKey: .normalSoundPath) ?? normalSoundPath
        successSoundPath = try c.decodeIfPresent(String.self, forKey: .successSoundPath) ?? successSoundPath
        errorSoundPath = try c.decodeIfPresent(String.self, forKey: .errorSoundPath) ?? errorSoundPath
        systemNotificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .systemNotificationsEnabled) ?? systemNotificationsEnabled
        loginItemEnabled = try c.decodeIfPresent(Bool.self, forKey: .loginItemEnabled) ?? loginItemEnabled
        menuBarEnabled = try c.decodeIfPresent(Bool.self, forKey: .menuBarEnabled) ?? menuBarEnabled
        lastUsedQueueID = try c.decodeIfPresent(Int64.self, forKey: .lastUsedQueueID)
        updatesEnabled = try c.decodeIfPresent(Bool.self, forKey: .updatesEnabled) ?? updatesEnabled
        updateManifestURL = try c.decodeIfPresent(String.self, forKey: .updateManifestURL) ?? updateManifestURL
        lastUpdateCheck = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
    }
}

public struct IdempotencyRecord: Codable, Hashable, Sendable {
    public var requestID: String
    public var bodyDigest: String
    public var taskIDs: [Int64]
    public var acceptedAt: Date
    public var itemCount: Int?
    public var itemResults: [ImportRequestItemResult]?

    public init(requestID: String, bodyDigest: String, taskIDs: [Int64], acceptedAt: Date,
                itemCount: Int? = nil, itemResults: [ImportRequestItemResult]? = nil) {
        self.requestID = requestID
        self.bodyDigest = bodyDigest
        self.taskIDs = taskIDs
        self.acceptedAt = acceptedAt
        self.itemCount = itemCount
        self.itemResults = itemResults
    }
}

/// Outcome for one item in a bridge/CLI import request. The index refers to the
/// item's zero-based position in the original request body.
public struct ImportRequestItemResult: Codable, Hashable, Sendable, Identifiable {
    public var index: Int
    public var taskID: Int64?
    public var error: String?
    public var id: Int { index }
    public var isAccepted: Bool { taskID != nil }

    public init(index: Int, taskID: Int64? = nil, error: String? = nil) {
        self.index = index
        self.taskID = taskID
        self.error = error
    }
}

/// Durable per-item results for a bridge/CLI request.
public struct ImportRequestResult: Codable, Hashable, Sendable {
    public var items: [ImportRequestItemResult]
    public var acceptedTaskIDs: [Int64] { items.compactMap(\.taskID) }
    public var acceptedCount: Int { acceptedTaskIDs.count }
    public var accepted: Bool { acceptedCount > 0 }

    public init(items: [ImportRequestItemResult]) { self.items = items }
}

public struct DownloadHistoryRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sourceURL: String
    public var displayName: String
    public var destinationDirectory: String
    public var completedAt: Date
    public init(id: UUID = UUID(), sourceURL: String, displayName: String, destinationDirectory: String, completedAt: Date) {
        self.id = id; self.sourceURL = sourceURL; self.displayName = displayName
        self.destinationDirectory = destinationDirectory; self.completedAt = completedAt
    }
}

public struct AppData: Codable, Sendable {
    public var schemaVersion: Int
    public var tasks: [DownloadRecord]
    public var queues: [QueueRecord]
    public var categories: [CategoryRecord]
    public var history: [DownloadHistoryRecord]
    public var settings: AppSettings
    public var idempotency: [IdempotencyRecord]
    public var nextTaskID: Int64
    public var nextQueueID: Int64
    public var nextCategoryID: Int64
    public var importedLegacyAt: Date?

    public init() {
        schemaVersion = 2
        tasks = []
        queues = [QueueRecord(id: 0, name: "Main", order: 0)]
        categories = Self.defaultCategories(root: AppSettings().defaultDownloadDirectory)
        history = []
        settings = AppSettings()
        idempotency = []
        nextTaskID = 1
        nextQueueID = 1
        nextCategoryID = (categories.map(\.id).max() ?? 0) + 1
        importedLegacyAt = nil
    }

    public static func defaultCategories(root: String) -> [CategoryRecord] {
        let values: [(String, String)] = [
            ("压缩包", "archivebox.fill"), ("程序", "app.badge"), ("视频", "film"),
            ("音乐", "music.note"), ("图片", "photo"), ("文档", "doc.text")
        ]
        let extensions = [
            "zip rar 7z tar gz bz2 xz iso dmg tgz", "apk exe msi bat sh jar app deb rpm bin",
            "mp4 avi mkv mov wmv flv webm m4v 3gp mpeg ts", "mp3 wav aac flac ogg aiff wma m4a",
            "jpg jpeg png gif bmp tiff tif svg webp heic ico raw psd",
            "doc docx pdf txt rtf odt xls xlsx ppt pptx csv epub pages"
        ]
        return values.enumerated().map { index, value in
            CategoryRecord(id: Int64(index + 1), name: value.0, symbol: value.1,
                           extensions: extensions[index].split(separator: " ").map(String.init),
                           destinationDirectory: URL(fileURLWithPath: root).appendingPathComponent(value.0, isDirectory: true).path,
                           order: index)
        }
    }
}

public struct CreateDownloadRequest: Sendable {
    public var kind: TransferKind
    public var sourceURL: URL
    public var pageURL: URL?
    public var displayName: String?
    public var destinationDirectory: URL?
    public var headers: [String: String]
    public var queueID: Int64?
    public var categoryID: Int64?
    public var startImmediately: Bool
    public var conflictPolicy: ConflictPolicy
    public var expectedChecksum: String?
    public var speedLimitBytesPerSecond: Int64
    public var connectionCount: Int?
    public var sourceDescription: String?

    public init(kind: TransferKind = .http, sourceURL: URL, pageURL: URL? = nil, displayName: String? = nil,
                destinationDirectory: URL? = nil, headers: [String: String] = [:], queueID: Int64? = 0,
                categoryID: Int64? = nil, startImmediately: Bool = false, conflictPolicy: ConflictPolicy = .rename,
                expectedChecksum: String? = nil, speedLimitBytesPerSecond: Int64 = 0,
                connectionCount: Int? = nil, sourceDescription: String? = nil) {
        self.kind = kind; self.sourceURL = sourceURL; self.pageURL = pageURL; self.displayName = displayName
        self.destinationDirectory = destinationDirectory; self.headers = headers; self.queueID = queueID
        self.categoryID = categoryID; self.startImmediately = startImmediately; self.conflictPolicy = conflictPolicy
        self.expectedChecksum = expectedChecksum; self.speedLimitBytesPerSecond = max(0, speedLimitBytesPerSecond)
        self.connectionCount = connectionCount.map { max(1, min($0, 256)) }
        self.sourceDescription = sourceDescription
    }
}
