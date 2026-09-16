import Foundation

/// Size/speed display units, mirroring the original `SupportedSizeUnits`.
public enum SizeUnit: String, Codable, Sendable, CaseIterable {
    case binaryBytes
    case decimalBytes

    public var base: Double { self == .binaryBytes ? 1024 : 1000 }

    public var labels: [String] {
        self == .binaryBytes
            ? ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
            : ["B", "KB", "MB", "GB", "TB", "PB"]
    }
}

/// Appearance selection, mirroring the original theme keys
/// (`dark`, `light`, `system`).
public enum ThemeMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The appearance the app must force, or `.system` to follow macOS.
    ///
    /// Kept here as a pure mapping so it can be unit tested without importing
    /// SwiftUI, and so every scene (window, Settings, menu bar) derives its
    /// colour scheme from the same rule instead of re-deriving the ternary.
    public var appearanceOverride: AppearanceOverride {
        switch self {
        case .system: .system
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Forced appearance, decoupled from SwiftUI's `ColorScheme` so the mapping is
/// testable in the Foundation-only core module.
public enum AppearanceOverride: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark

    /// `nil` when macOS decides (system), otherwise whether dark is forced.
    public var forcedDark: Bool? {
        switch self {
        case .system: nil
        case .light: false
        case .dark: true
        }
    }
}

/// Proxy configuration. Mirrors the original's proxy settings surface.
public struct ProxySettings: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
        case none
        case system
        case manual
        public var id: String { rawValue }
    }

    public enum Scheme: String, Codable, Sendable, CaseIterable, Identifiable {
        case http
        case https
        case socks5
        public var id: String { rawValue }
    }

    public var mode: Mode
    public var scheme: Scheme
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    /// Hosts that bypass the proxy, comma separated, as entered by the user.
    public var bypassList: String

    public init(
        mode: Mode = .system,
        scheme: Scheme = .http,
        host: String = "",
        port: Int = 0,
        username: String = "",
        password: String = "",
        bypassList: String = ""
    ) {
        self.mode = mode
        self.scheme = scheme
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.bypassList = bypassList
    }

    public var isUsable: Bool {
        mode == .manual && !host.isEmpty && port > 0
    }

    /// Credentials are only used for a proxy authentication challenge; this
    /// value is never copied into an origin request's Authorization header.
    public var proxyAuthorizationHeader: String? {
        guard !username.isEmpty else { return nil }
        return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
}

/// TLS policy. The original exposes a single `ignoreSSLCertificates` switch;
/// it is modelled explicitly here so the insecure path is never implicit.
public struct TLSSettings: Codable, Sendable, Hashable {
    /// When true the app accepts any server certificate. Off by default,
    /// matching `DefaultAppSettings.ignoreSSLCertificates = false`.
    public var allowInsecureCertificates: Bool

    public init(allowInsecureCertificates: Bool = false) {
        self.allowInsecureCertificates = allowInsecureCertificates
    }
}

/// Notification preferences.
public struct NotificationSettings: Codable, Sendable, Hashable {
    public var soundEnabled: Bool
    public var generalSound: String
    public var successSound: String
    public var errorSound: String
    public var showDownloadProgressDialog: Bool
    public var showCompletionDialog: Bool

    public init(
        soundEnabled: Bool = true,
        generalSound: String = "",
        successSound: String = "",
        errorSound: String = "",
        showDownloadProgressDialog: Bool = true,
        showCompletionDialog: Bool = true
    ) {
        self.soundEnabled = soundEnabled
        self.generalSound = generalSound
        self.successSound = successSound
        self.errorSound = errorSound
        self.showDownloadProgressDialog = showDownloadProgressDialog
        self.showCompletionDialog = showCompletionDialog
    }
}

/// Local REST/integration server configuration, mirroring the original's
/// `apiEnabled` / `apiPort` / `apiAuthEnabled` / `apiAuthKey` settings.
public struct IntegrationSettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var port: Int
    public var authEnabled: Bool
    public var apiKey: String

    public init(
        enabled: Bool = true,
        port: Int = 15151,
        authEnabled: Bool = false,
        apiKey: String = ""
    ) {
        self.enabled = enabled
        self.port = port
        self.authEnabled = authEnabled
        self.apiKey = apiKey
    }

    /// The key the server actually enforces, or `nil` when auth is off.
    public var enforcedKey: String? {
        guard authEnabled, !apiKey.isEmpty else { return nil }
        return apiKey
    }
}

/// Update channel behaviour.
public enum UpdateChannel: String, Codable, Sendable, CaseIterable, Identifiable {
    case disabled
    case stable
    public var id: String { rawValue }
}

/// The complete, persisted application settings model.
///
/// Every property maps to a key from the original
/// `shared/storage/appsettings/DefaultAppSettings` (plus the sub-models the
/// desktop app persisted separately). Defaults are byte-for-byte identical to
/// the original so that a migrated profile behaves the same.
public struct AppSettings: Codable, Sendable, Equatable {
    // Appearance
    public var theme: ThemeMode
    public var language: String?
    public var uiScale: Double?
    public var showIconLabels: Bool
    public var useRelativeDateTime: Bool
    public var clipboardMonitoring: Bool

    // Download engine
    public var threadCount: Int
    public var maxConcurrentDownloads: Int
    public var maxDownloadRetryCount: Int
    public var dynamicPartCreation: Bool
    public var useServerLastModifiedTime: Bool
    public var appendExtensionToIncompleteDownloads: Bool
    public var useAverageSpeed: Bool
    public var speedLimit: Int64
    public var useCategoryByDefault: Bool
    public var userAgent: String

    // Storage
    public var defaultDownloadFolder: String
    public var trackDeletedFilesOnDisk: Bool
    public var deletePartialFileOnDownloadCancellation: Bool

    // Units
    public var sizeUnit: SizeUnit
    public var speedUnit: SizeUnit

    // System integration
    public var autoStartOnBoot: Bool
    public var notifications: NotificationSettings
    public var integration: IntegrationSettings
    public var proxy: ProxySettings
    public var tls: TLSSettings

    // Updates — disabled by default for safety on a fork (see UpdaterService).
    public var updateChannel: UpdateChannel
    public var lastUpdateCheck: Date?

    // Persistence metadata (not part of the original settings).
    public var settingsVersion: Int

    public init(
        theme: ThemeMode = .dark,
        language: String? = nil,
        uiScale: Double? = nil,
        showIconLabels: Bool = true,
        useRelativeDateTime: Bool = true,
        clipboardMonitoring: Bool = true,
        threadCount: Int = 8,
        maxConcurrentDownloads: Int = 3,
        maxDownloadRetryCount: Int = 3,
        dynamicPartCreation: Bool = true,
        useServerLastModifiedTime: Bool = false,
        appendExtensionToIncompleteDownloads: Bool = false,
        useAverageSpeed: Bool = true,
        speedLimit: Int64 = 0,
        useCategoryByDefault: Bool = true,
        userAgent: String = "",
        defaultDownloadFolder: String = AppSettings.defaultDownloadFolderPath,
        trackDeletedFilesOnDisk: Bool = false,
        deletePartialFileOnDownloadCancellation: Bool = false,
        sizeUnit: SizeUnit = .binaryBytes,
        speedUnit: SizeUnit = .binaryBytes,
        autoStartOnBoot: Bool = true,
        notifications: NotificationSettings = NotificationSettings(),
        integration: IntegrationSettings = IntegrationSettings(),
        proxy: ProxySettings = ProxySettings(),
        tls: TLSSettings = TLSSettings(),
        updateChannel: UpdateChannel = .disabled,
        lastUpdateCheck: Date? = nil,
        settingsVersion: Int = AppSettings.currentVersion
    ) {
        self.theme = theme
        self.language = language
        self.uiScale = uiScale
        self.showIconLabels = showIconLabels
        self.useRelativeDateTime = useRelativeDateTime
        self.clipboardMonitoring = clipboardMonitoring
        self.threadCount = threadCount
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.maxDownloadRetryCount = maxDownloadRetryCount
        self.dynamicPartCreation = dynamicPartCreation
        self.useServerLastModifiedTime = useServerLastModifiedTime
        self.appendExtensionToIncompleteDownloads = appendExtensionToIncompleteDownloads
        self.useAverageSpeed = useAverageSpeed
        self.speedLimit = speedLimit
        self.useCategoryByDefault = useCategoryByDefault
        self.userAgent = userAgent
        self.defaultDownloadFolder = defaultDownloadFolder
        self.trackDeletedFilesOnDisk = trackDeletedFilesOnDisk
        self.deletePartialFileOnDownloadCancellation = deletePartialFileOnDownloadCancellation
        self.sizeUnit = sizeUnit
        self.speedUnit = speedUnit
        self.autoStartOnBoot = autoStartOnBoot
        self.notifications = notifications
        self.integration = integration
        self.proxy = proxy
        self.tls = tls
        self.updateChannel = updateChannel
        self.lastUpdateCheck = lastUpdateCheck
        self.settingsVersion = settingsVersion
    }

    public static let currentVersion = 1

    /// `~/Downloads/ABDM`, matching the original's
    /// `PlatformDownloadLocationProvider.getDownloadLocation().resolve("ABDM")`.
    public static var defaultDownloadFolderPath: String {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("ABDM").path
    }

    /// Clamps values into their legal ranges. Applied after every mutation so
    /// the engine never observes a nonsensical configuration.
    public mutating func normalize() {
        threadCount = min(max(threadCount, 1), 64)
        maxConcurrentDownloads = min(max(maxConcurrentDownloads, 1), 64)
        maxDownloadRetryCount = min(max(maxDownloadRetryCount, 0), 100)
        speedLimit = max(0, speedLimit)
        if let scale = uiScale { uiScale = min(max(scale, 0.5), 3.0) }
        integration.port = min(max(integration.port, 1024), 65535)
        proxy.port = proxy.port == 0 ? 0 : min(max(proxy.port, 1), 65535)
        if defaultDownloadFolder.isEmpty {
            defaultDownloadFolder = Self.defaultDownloadFolderPath
        }
    }
}

extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case theme, language, uiScale, showIconLabels, useRelativeDateTime, clipboardMonitoring
        case threadCount, maxConcurrentDownloads, maxDownloadRetryCount, dynamicPartCreation, useServerLastModifiedTime, appendExtensionToIncompleteDownloads, useAverageSpeed, speedLimit, useCategoryByDefault, userAgent
        case defaultDownloadFolder, trackDeletedFilesOnDisk, deletePartialFileOnDownloadCancellation
        case sizeUnit, speedUnit, autoStartOnBoot, notifications, integration, proxy, tls, updateChannel, lastUpdateCheck, settingsVersion
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        theme = try c.decodeIfPresent(ThemeMode.self, forKey: .theme) ?? defaults.theme
        language = try c.decodeIfPresent(String.self, forKey: .language); uiScale = try c.decodeIfPresent(Double.self, forKey: .uiScale)
        showIconLabels = try c.decodeIfPresent(Bool.self, forKey: .showIconLabels) ?? defaults.showIconLabels
        useRelativeDateTime = try c.decodeIfPresent(Bool.self, forKey: .useRelativeDateTime) ?? defaults.useRelativeDateTime
        clipboardMonitoring = try c.decodeIfPresent(Bool.self, forKey: .clipboardMonitoring) ?? defaults.clipboardMonitoring
        threadCount = try c.decodeIfPresent(Int.self, forKey: .threadCount) ?? defaults.threadCount
        maxConcurrentDownloads = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? defaults.maxConcurrentDownloads
        maxDownloadRetryCount = try c.decodeIfPresent(Int.self, forKey: .maxDownloadRetryCount) ?? defaults.maxDownloadRetryCount
        dynamicPartCreation = try c.decodeIfPresent(Bool.self, forKey: .dynamicPartCreation) ?? defaults.dynamicPartCreation
        useServerLastModifiedTime = try c.decodeIfPresent(Bool.self, forKey: .useServerLastModifiedTime) ?? defaults.useServerLastModifiedTime
        appendExtensionToIncompleteDownloads = try c.decodeIfPresent(Bool.self, forKey: .appendExtensionToIncompleteDownloads) ?? defaults.appendExtensionToIncompleteDownloads
        useAverageSpeed = try c.decodeIfPresent(Bool.self, forKey: .useAverageSpeed) ?? defaults.useAverageSpeed
        speedLimit = try c.decodeIfPresent(Int64.self, forKey: .speedLimit) ?? defaults.speedLimit
        useCategoryByDefault = try c.decodeIfPresent(Bool.self, forKey: .useCategoryByDefault) ?? defaults.useCategoryByDefault
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? defaults.userAgent
        defaultDownloadFolder = try c.decodeIfPresent(String.self, forKey: .defaultDownloadFolder) ?? defaults.defaultDownloadFolder
        trackDeletedFilesOnDisk = try c.decodeIfPresent(Bool.self, forKey: .trackDeletedFilesOnDisk) ?? defaults.trackDeletedFilesOnDisk
        deletePartialFileOnDownloadCancellation = try c.decodeIfPresent(Bool.self, forKey: .deletePartialFileOnDownloadCancellation) ?? defaults.deletePartialFileOnDownloadCancellation
        sizeUnit = try c.decodeIfPresent(SizeUnit.self, forKey: .sizeUnit) ?? defaults.sizeUnit; speedUnit = try c.decodeIfPresent(SizeUnit.self, forKey: .speedUnit) ?? defaults.speedUnit
        autoStartOnBoot = try c.decodeIfPresent(Bool.self, forKey: .autoStartOnBoot) ?? defaults.autoStartOnBoot
        notifications = try c.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? defaults.notifications
        integration = try c.decodeIfPresent(IntegrationSettings.self, forKey: .integration) ?? defaults.integration
        proxy = try c.decodeIfPresent(ProxySettings.self, forKey: .proxy) ?? defaults.proxy; tls = try c.decodeIfPresent(TLSSettings.self, forKey: .tls) ?? defaults.tls
        updateChannel = try c.decodeIfPresent(UpdateChannel.self, forKey: .updateChannel) ?? defaults.updateChannel; lastUpdateCheck = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        settingsVersion = try c.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? defaults.settingsVersion
    }
}
