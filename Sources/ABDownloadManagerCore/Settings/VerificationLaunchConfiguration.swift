import Foundation

/// Fail-closed launch requirements for locally verified application bundles.
/// Ordinary production builds carry a `NO` marker and continue to use the
/// normal Application Support, UserDefaults, and Downloads locations.
public struct VerificationLaunchConfiguration: Sendable, Equatable {
    public let stateDirectory: URL
    public let downloadDirectory: URL
    public let userDefaultsSuite: String
    public let integrationPort: UInt16

    public enum ValidationError: Error, LocalizedError, Equatable {
        case requiresSeparateBundleIdentifier
        case missingSetting(String)
        case invalidAbsolutePath(String)
        case overlapsProductionDirectory(String)
        case stateAndDownloadDirectoriesOverlap
        case productionDefaultsSuite
        case invalidIntegrationPort

        public var errorDescription: String? {
            switch self {
            case .requiresSeparateBundleIdentifier:
                "A verification build must use a separate bundle identifier."
            case .missingSetting(let name):
                "A verification build requires " + name + "."
            case .invalidAbsolutePath(let name):
                "A verification build requires an absolute " + name + "."
            case .overlapsProductionDirectory(let name):
                "The verification " + name + " overlaps a production user-data directory."
            case .stateAndDownloadDirectoriesOverlap:
                "The verification state and download directories must be separate."
            case .productionDefaultsSuite:
                "A verification build requires a separate UserDefaults suite."
            case .invalidIntegrationPort:
                "A verification build requires an integration port from 1024 through 65535."
            }
        }
    }

    /// Returns nil for normal builds. For a marked verification build, every
    /// override is checked before AppStateStore, Keychain, or UserDefaults use.
    public static func validateIfRequired(
        marker: String?,
        bundleIdentifier: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> VerificationLaunchConfiguration? {
        guard marker == "YES" else { return nil }
        guard let bundleIdentifier, bundleIdentifier != "com.zjx.download" else {
            throw ValidationError.requiresSeparateBundleIdentifier
        }

        func required(_ key: String) throws -> String {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw ValidationError.missingSetting(key)
            }
            return value
        }

        func absoluteURL(_ key: String) throws -> URL {
            let value = try required(key)
            guard value.hasPrefix("/") else { throw ValidationError.invalidAbsolutePath(key) }
            return URL(fileURLWithPath: value, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        }

        let stateDirectory = try absoluteURL("ABDM_STATE_DIRECTORY")
        let downloadDirectory = try absoluteURL("ABDM_DOWNLOAD_DIRECTORY")
        let userDefaultsSuite = try required("ABDM_USER_DEFAULTS_SUITE")
        let portText = try required("ABDM_INTEGRATION_PORT")
        guard userDefaultsSuite != "com.zjx.download", userDefaultsSuite != "NSGlobalDomain" else {
            throw ValidationError.productionDefaultsSuite
        }
        guard let portNumber = UInt16(portText), portNumber >= 1024 else {
            throw ValidationError.invalidIntegrationPort
        }

        let appSupport = homeDirectory.appendingPathComponent("Library/Application Support/ABDownloadManager", isDirectory: true).standardizedFileURL
        let productionDownloads = homeDirectory.appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL
        guard !containsOrEquals(stateDirectory, appSupport), !containsOrEquals(downloadDirectory, productionDownloads) else {
            throw ValidationError.overlapsProductionDirectory("state or download directory")
        }
        guard !containsOrEquals(stateDirectory, downloadDirectory), !containsOrEquals(downloadDirectory, stateDirectory) else {
            throw ValidationError.stateAndDownloadDirectoriesOverlap
        }

        return VerificationLaunchConfiguration(
            stateDirectory: stateDirectory,
            downloadDirectory: downloadDirectory,
            userDefaultsSuite: userDefaultsSuite,
            integrationPort: portNumber
        )
    }

    private static func containsOrEquals(_ candidate: URL, _ protected: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let protectedPath = protected.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == protectedPath || candidatePath.hasPrefix(protectedPath + "/")
    }
}
