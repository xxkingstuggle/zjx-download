import AppIntents
import CryptoKit
import Foundation

public struct UpdateManifest: Codable, Sendable, Equatable {
    public let version: String
    public let downloadURL: URL
    public let sha256: String
    /// Publisher metadata for display and policy checks. The downloader does
    /// not claim that this field verifies the archive's code signature.
    public let signingTeamID: String?

    public init(version: String, downloadURL: URL, sha256: String, signingTeamID: String? = nil) {
        self.version = version
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.signingTeamID = signingTeamID
    }
}

public struct SecureUpdatePolicy: Sendable {
    public enum UpdateError: Error, LocalizedError, Equatable {
        case updatesDisabled
        case invalidManifest
        case insecureURL
        case badResponse
        case artifactTooLarge
        case checksumMismatch
        case invalidFile

        public var errorDescription: String? {
            switch self {
            case .updatesDisabled: "Updates are disabled."
            case .invalidManifest: "The update manifest is invalid."
            case .insecureURL: "Update URLs must use HTTPS."
            case .badResponse: "The update server returned an invalid response."
            case .artifactTooLarge: "The update artifact exceeds the 512 MiB safety limit."
            case .checksumMismatch: "The downloaded update did not match its SHA-256 checksum."
            case .invalidFile: "The update server did not provide a valid archive file."
            }
        }
    }

    public typealias ArtifactDownload = @Sendable (URL) async throws -> (file: URL, response: HTTPURLResponse)

    public let channel: UpdateChannel
    public let maximumArtifactBytes: Int64

    public init(channel: UpdateChannel = .disabled, maximumArtifactBytes: Int64 = 512 * 1024 * 1024) {
        self.channel = channel
        self.maximumArtifactBytes = maximumArtifactBytes
    }

    public func fetchManifest(from url: URL, session: URLSession = .shared) async throws -> UpdateManifest {
        guard channel != .disabled else { throw UpdateError.updatesDisabled }
        guard Self.isHTTPS(url) else { throw UpdateError.insecureURL }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zjx-download-macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.url.map(Self.isHTTPS) == true else { throw UpdateError.badResponse }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        try validate(manifest)
        return manifest
    }

    public func validate(_ manifest: UpdateManifest) throws {
        guard channel != .disabled else { throw UpdateError.updatesDisabled }
        guard Self.isHTTPS(manifest.downloadURL) else { throw UpdateError.insecureURL }
        let version = manifest.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version.count <= 80,
              !version.contains("/"), !version.contains("\\"),
              !version.contains(".."), manifest.sha256.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else {
            throw UpdateError.invalidManifest
        }
        if let teamID = manifest.signingTeamID,
           teamID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) == nil {
            throw UpdateError.invalidManifest
        }
    }

    public func downloadAndVerify(
        _ manifest: UpdateManifest,
        to directory: URL,
        fileName: String? = nil,
        fileManager: FileManager = .default,
        download: ArtifactDownload
    ) async throws -> URL {
        try validate(manifest)
        let (temporaryFile, response) = try await download(manifest.downloadURL)
        defer { try? fileManager.removeItem(at: temporaryFile) }
        guard (200..<300).contains(response.statusCode), response.url.map(Self.isHTTPS) == true else {
            throw UpdateError.badResponse
        }

        let values = try temporaryFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0 else { throw UpdateError.invalidFile }
        guard Int64(fileSize) <= maximumArtifactBytes else { throw UpdateError.artifactTooLarge }
        guard try await Self.sha256(of: temporaryFile).caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            throw UpdateError.checksumMismatch
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = Self.safeArtifactName(fileName ?? manifest.downloadURL.lastPathComponent)
        let destination = Self.availableURL(directory: directory, fileName: safeName, fileManager: fileManager)
        try fileManager.moveItem(at: temporaryFile, to: destination)
        return destination
    }

    public func verify(data: Data, expectedSHA256: String) -> Bool {
        guard expectedSHA256.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else { return false }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    private static func safeArtifactName(_ proposed: String) -> String {
        let leaf = URL(fileURLWithPath: proposed).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        let sanitized = String(leaf.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else { return "zjx-download-update.zip" }
        return sanitized
    }

    private static func availableURL(directory: URL, fileName: String, fileManager: FileManager) -> URL {
        let original = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: original.path) else { return original }
        let base = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        for index in 2...10_000 {
            let candidate = directory.appendingPathComponent("\(base)-\(index)").appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
    }

    private nonisolated static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

public struct SettingsMigration: Sendable {
    public static let currentVersion = 1
    public init() {}
    public func migrate(_ settings: AppSettings) -> AppSettings {
        var value = settings
        value.normalize()
        value.settingsVersion = Self.currentVersion
        return value
    }
    public func importLegacyDefaults(_ defaults: UserDefaults = .standard) -> AppSettings {
        var settings = AppSettings()
        if let folder = defaults.string(forKey: "downloadLocation"), !folder.isEmpty { settings.defaultDownloadFolder = folder }
        if defaults.object(forKey: "maxConcurrentDownloads") != nil { settings.maxConcurrentDownloads = defaults.integer(forKey: "maxConcurrentDownloads") }
        if defaults.object(forKey: "threadCount") != nil { settings.threadCount = defaults.integer(forKey: "threadCount") }
        if let theme = defaults.string(forKey: "theme"), let mode = ThemeMode(rawValue: theme) { settings.theme = mode }
        settings.normalize()
        return settings
    }
}
