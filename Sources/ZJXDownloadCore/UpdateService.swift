import CryptoKit
import Foundation

public struct UpdateManifest: Codable, Sendable, Equatable {
    public let version: String
    public let downloadURL: URL
    public let sha256: String
    public let signingTeamID: String?
    public let releaseNotes: String?
    public let platform: String?
    public let architectures: [String]?

    public init(version: String, downloadURL: URL, sha256: String, signingTeamID: String? = nil,
                releaseNotes: String? = nil, platform: String? = nil, architectures: [String]? = nil) {
        self.version = version
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.signingTeamID = signingTeamID
        self.releaseNotes = releaseNotes
        self.platform = platform
        self.architectures = architectures
    }
}

public struct UpdateCheckResult: Sendable {
    public let manifest: UpdateManifest
    public let updateAvailable: Bool
}

public enum UpdateServiceError: Error, LocalizedError, Sendable {
    case invalidManifest
    case insecureURL
    case badResponse
    case artifactTooLarge
    case checksumMismatch
    case invalidFile
    case noCompatibleAsset

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: "更新清单字段无效。"
        case .insecureURL: "更新清单和下载地址必须使用 HTTPS。"
        case .badResponse: "更新服务器返回了无效响应。"
        case .artifactTooLarge: "更新文件超过 512 MiB 安全上限。"
        case .checksumMismatch: "下载文件的 SHA-256 与清单不一致。"
        case .invalidFile: "更新服务器没有提供有效文件。"
        case .noCompatibleAsset: "更新清单没有适用于当前 macOS 架构的安装包。"
        }
    }
}

public enum UpdateService {
    public static let maximumArtifactBytes: Int64 = 512 * 1024 * 1024

    public static func check(manifestURL: URL, currentVersion: String, session: URLSession = .shared) async throws -> UpdateCheckResult {
        guard isHTTPS(manifestURL) else { throw UpdateServiceError.insecureURL }
        var request = URLRequest(url: manifestURL, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zjx-download-macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), http.url.map(isHTTPS) == true else {
            throw UpdateServiceError.badResponse
        }
        guard data.count <= 256 * 1024 else { throw UpdateServiceError.invalidManifest }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        try validate(manifest)
        guard isCompatibleWithCurrentMac(manifest) else { throw UpdateServiceError.noCompatibleAsset }
        return UpdateCheckResult(manifest: manifest, updateAvailable: isNewer(manifest.version, than: currentVersion))
    }

    public static func downloadAndVerify(_ manifest: UpdateManifest, to directory: URL,
                                         session: URLSession = .shared, fileManager: FileManager = .default) async throws -> URL {
        try validate(manifest)
        let (temporary, response) = try await session.download(from: manifest.downloadURL)
        defer { try? fileManager.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), http.url.map(isHTTPS) == true else {
            throw UpdateServiceError.badResponse
        }
        let values = try temporary.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0 else { throw UpdateServiceError.invalidFile }
        guard Int64(fileSize) <= maximumArtifactBytes else { throw UpdateServiceError.artifactTooLarge }
        let actual = try await sha256(of: temporary)
        guard actual.caseInsensitiveCompare(manifest.sha256) == .orderedSame else { throw UpdateServiceError.checksumMismatch }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = safeName(manifest.downloadURL.lastPathComponent)
        let destination = uniqueURL(directory: directory, name: name, fileManager: fileManager)
        try fileManager.moveItem(at: temporary, to: destination)
        return destination
    }

    public static func validate(_ manifest: UpdateManifest) throws {
        guard isHTTPS(manifest.downloadURL) else { throw UpdateServiceError.insecureURL }
        let version = manifest.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version.count <= 80, !version.contains("/"), !version.contains("\\"),
              !version.contains(".."), manifest.sha256.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else {
            throw UpdateServiceError.invalidManifest
        }
        if let team = manifest.signingTeamID, team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) == nil {
            throw UpdateServiceError.invalidManifest
        }
        if let platform = manifest.platform, !["macos", "darwin"].contains(platform.lowercased()) {
            throw UpdateServiceError.noCompatibleAsset
        }
        if let architectures = manifest.architectures,
           architectures.contains(where: { !["arm64", "aarch64", "x86_64", "x64"].contains($0.lowercased()) }) {
            throw UpdateServiceError.invalidManifest
        }
    }

    public static func isCompatibleWithCurrentMac(_ manifest: UpdateManifest) -> Bool {
        guard manifest.platform.map({ ["macos", "darwin"].contains($0.lowercased()) }) ?? true else { return false }
        guard let architectures = manifest.architectures else { return true }
        #if arch(arm64)
        let current = ["arm64", "aarch64"]
        #elseif arch(x86_64)
        let current = ["x86_64", "x64"]
        #else
        return false
        #endif
        return architectures.contains { current.contains($0.lowercased()) }
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = versionParts(candidate)
        let rhs = versionParts(current)
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left > right }
        }
        if lhs.suffix == rhs.suffix { return false }
        if lhs.suffix.isEmpty { return !rhs.suffix.isEmpty }
        if rhs.suffix.isEmpty { return false }
        return lhs.suffix.localizedStandardCompare(rhs.suffix) == .orderedDescending
    }

    private static func versionParts(_ raw: String) -> (numbers: [Int], suffix: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let components = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = components.first?.split(separator: ".").map { Int($0) ?? 0 } ?? []
        let suffix = components.count > 1 ? String(components[1]) : ""
        return (numbers, suffix)
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    private static func safeName(_ proposed: String) -> String {
        let leaf = URL(fileURLWithPath: proposed).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        let cleaned = String(leaf.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "zjx-download-update.zip" : cleaned
    }

    private static func uniqueURL(directory: URL, name: String, fileManager: FileManager) -> URL {
        let first = directory.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: first.path) { return first }
        let base = first.deletingPathExtension().lastPathComponent
        let ext = first.pathExtension
        for number in 2...10_000 {
            let candidate = directory.appendingPathComponent("\(base)-\(number)").appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
