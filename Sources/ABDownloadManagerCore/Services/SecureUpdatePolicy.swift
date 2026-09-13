import AppIntents
import Foundation
import CryptoKit

public struct UpdateManifest: Codable, Sendable, Equatable {
    public let version: String
    public let downloadURL: URL
    public let sha256: String
    public let signingTeamID: String?
    public init(version: String, downloadURL: URL, sha256: String, signingTeamID: String? = nil) { self.version = version; self.downloadURL = downloadURL; self.sha256 = sha256; self.signingTeamID = signingTeamID }
}

/// Update checks are opt-in and never install an artifact. A fork must provide
/// an explicit HTTPS manifest and verify its digest/signing identity in the
/// host application before offering a replacement.
public struct SecureUpdatePolicy: Sendable {
    public let channel: UpdateChannel
    public init(channel: UpdateChannel = .disabled) { self.channel = channel }
    public func fetchManifest(from url: URL, session: URLSession = .shared) async throws -> UpdateManifest {
        guard channel != .disabled, url.scheme?.lowercased() == "https" else { throw URLError(.appTransportSecurityRequiresSecureConnection) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(UpdateManifest.self, from: data)
    }
    public func verify(data: Data, expectedSHA256: String) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }
}

public struct SettingsMigration: Sendable {
    public static let currentVersion = 1
    public init() {}
    public func migrate(_ settings: AppSettings) -> AppSettings { var value = settings; value.normalize(); value.settingsVersion = Self.currentVersion; return value }
    public func importLegacyDefaults(_ defaults: UserDefaults = .standard) -> AppSettings {
        var settings = AppSettings()
        if let folder = defaults.string(forKey: "downloadLocation"), !folder.isEmpty { settings.defaultDownloadFolder = folder }
        if defaults.object(forKey: "maxConcurrentDownloads") != nil { settings.maxConcurrentDownloads = defaults.integer(forKey: "maxConcurrentDownloads") }
        if defaults.object(forKey: "threadCount") != nil { settings.threadCount = defaults.integer(forKey: "threadCount") }
        if let theme = defaults.string(forKey: "theme"), let mode = ThemeMode(rawValue: theme) { settings.theme = mode }
        settings.normalize(); return settings
    }
}
