import XCTest
@testable import ABDownloadManagerCore

final class IsolationTests: XCTestCase {
    func testDownloadDirectoryOverrideWinsOverLegacyDefaults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMIsolation-\(UUID().uuidString)")
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let downloadDirectory = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "ABDMIsolationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set("/Users/fixture/Downloads/ABDM", forKey: "downloadLocation")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacySettings = SettingsMigration().importLegacyDefaults(defaults)
        XCTAssertEqual(legacySettings.defaultDownloadFolder, "/Users/fixture/Downloads/ABDM")
        let categories = DefaultCategories.make(downloadRoot: legacySettings.defaultDownloadFolder)
        let fixtureState = PersistedAppState(
            categories: categories,
            settings: legacySettings,
            nextCategoryID: Int64(categories.count),
            defaultCategoriesInitialized: true
        )

        let environment = [
            "ABDM_STATE_DIRECTORY": stateDirectory.path,
            "ABDM_DOWNLOAD_DIRECTORY": downloadDirectory.path,
            "ABDM_USER_DEFAULTS_SUITE": suiteName,
            "ABDM_INTEGRATION_PORT": "25251",
            "ABDM_SUPPRESS_CLIPBOARD_MONITOR": "1"
        ]
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(fixtureState).write(to: stateDirectory.appendingPathComponent("state.json"))

        let store = try AppStateStore(directory: stateDirectory, environment: environment)
        let snapshot = await store.snapshot()

        XCTAssertEqual(snapshot.settings.defaultDownloadFolder, downloadDirectory.standardizedFileURL.path)
        XCTAssertEqual(snapshot.settings.integration.port, 25251)
        XCTAssertFalse(snapshot.settings.clipboardMonitoring)
        XCTAssertTrue(snapshot.categories.allSatisfy {
            $0.categoryPath == downloadDirectory.appendingPathComponent($0.name, isDirectory: true).standardizedFileURL.path
        })

        let reloaded = try AppStateStore(directory: stateDirectory, environment: environment)
        let persisted = await reloaded.snapshot()
        XCTAssertEqual(persisted.settings.defaultDownloadFolder, downloadDirectory.standardizedFileURL.path)
    }

    func testIsolatedSettingsPreserveContainedFoldersAndRejectEscapingPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMIsolation-\(UUID().uuidString)")
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let downloadDirectory = root.appendingPathComponent("downloads", isDirectory: true)
        let programs = downloadDirectory.appendingPathComponent("Programs", isDirectory: true)
        let videos = downloadDirectory.appendingPathComponent("Videos", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: programs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "ABDMIsolationTests.\(UUID().uuidString)"
        let environment = [
            "ABDM_STATE_DIRECTORY": stateDirectory.path,
            "ABDM_DOWNLOAD_DIRECTORY": downloadDirectory.path,
            "ABDM_USER_DEFAULTS_SUITE": suiteName,
            "ABDM_INTEGRATION_PORT": "25253"
        ]
        var fixture = PersistedAppState(settings: AppSettings(defaultDownloadFolder: programs.path))
        fixture.defaultCategoriesInitialized = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(fixture).write(to: stateDirectory.appendingPathComponent("state.json"))

        let store = try AppStateStore(directory: stateDirectory, environment: environment)
        let initialSnapshot = await store.snapshot()
        XCTAssertEqual(initialSnapshot.settings.defaultDownloadFolder, programs.standardizedFileURL.path)

        var edited = initialSnapshot.settings
        edited.defaultDownloadFolder = videos.path
        try await store.setSettings(edited)
        let reloaded = try AppStateStore(directory: stateDirectory, environment: environment)
        let reloadedSnapshot = await reloaded.snapshot()
        XCTAssertEqual(reloadedSnapshot.settings.defaultDownloadFolder, videos.standardizedFileURL.path)

        edited.defaultDownloadFolder = outside.path
        try await reloaded.setSettings(edited)
        let outsideSnapshot = await reloaded.snapshot()
        XCTAssertEqual(outsideSnapshot.settings.defaultDownloadFolder, downloadDirectory.standardizedFileURL.path)

        let escapingLink = downloadDirectory.appendingPathComponent("outside-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: escapingLink.path, withDestinationPath: outside.path)
        edited.defaultDownloadFolder = escapingLink.path
        try await reloaded.setSettings(edited)
        let symlinkSnapshot = await reloaded.snapshot()
        XCTAssertEqual(symlinkSnapshot.settings.defaultDownloadFolder, downloadDirectory.standardizedFileURL.path)
    }

    func testIsolatedProfileRejectsTasksPointingOutsideDownloadRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMIsolation-\(UUID().uuidString)")
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let downloadDirectory = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var state = PersistedAppState()
        state.tasks = [DownloadTask(
            id: 7,
            source: DownloadSource(url: try XCTUnwrap(URL(string: "https://example.test/file.bin"))),
            folderPath: "/Users/fixture/Downloads/ABDM",
            fileName: "file.bin"
        )]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: stateDirectory.appendingPathComponent("state.json"))

        let environment = [
            "ABDM_STATE_DIRECTORY": stateDirectory.path,
            "ABDM_DOWNLOAD_DIRECTORY": downloadDirectory.path,
            "ABDM_USER_DEFAULTS_SUITE": "ABDMIsolationTests.\(UUID().uuidString)"
        ]
        XCTAssertThrowsError(try AppStateStore(directory: stateDirectory, environment: environment)) {
            XCTAssertEqual($0 as? AppStateIsolationError, .taskOutsideIsolatedDownloads(taskID: 7))
        }
    }

    func testIsolatedStateRequiresSeparateDefaultsSuite() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMIsolation-\(UUID().uuidString)")
        XCTAssertThrowsError(try AppStateStore(
            directory: root,
            environment: ["ABDM_STATE_DIRECTORY": root.path]
        )) {
            XCTAssertEqual($0 as? AppStateIsolationError, .missingIsolatedDefaultsSuite)
        }
    }

    func testVerificationBundleFailsClosedWhenAnyIsolationOverrideIsMissing() {
        let complete: [String: String] = [
            "ABDM_STATE_DIRECTORY": "/tmp/abdm-test/state",
            "ABDM_DOWNLOAD_DIRECTORY": "/tmp/abdm-test/downloads",
            "ABDM_USER_DEFAULTS_SUITE": "ABDMVerificationTests.fixture",
            "ABDM_INTEGRATION_PORT": "25251"
        ]
        for missingKey in complete.keys {
            var environment = complete
            environment.removeValue(forKey: missingKey)
            XCTAssertThrowsError(try VerificationLaunchConfiguration.validateIfRequired(
                marker: "YES",
                bundleIdentifier: "com.zjx.download.verification",
                environment: environment,
                homeDirectory: URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
            ), "Expected missing \(missingKey) to fail closed")
        }
    }

    func testVerificationBundleRequiresSeparateBundleAndUserDirectories() throws {
        let environment = [
            "ABDM_STATE_DIRECTORY": "/Users/fixture/Library/Application Support/ABDownloadManager/state",
            "ABDM_DOWNLOAD_DIRECTORY": "/tmp/abdm-test/downloads",
            "ABDM_USER_DEFAULTS_SUITE": "ABDMVerificationTests.fixture",
            "ABDM_INTEGRATION_PORT": "25251"
        ]
        XCTAssertThrowsError(try VerificationLaunchConfiguration.validateIfRequired(
            marker: "YES", bundleIdentifier: "com.zjx.download", environment: environment,
            homeDirectory: URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        ))
        var productionDefaults = environment
        productionDefaults["ABDM_USER_DEFAULTS_SUITE"] = "com.zjx.download"
        XCTAssertThrowsError(try VerificationLaunchConfiguration.validateIfRequired(
            marker: "YES", bundleIdentifier: "com.zjx.download.verification", environment: productionDefaults,
            homeDirectory: URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        ))
        XCTAssertThrowsError(try VerificationLaunchConfiguration.validateIfRequired(
            marker: "YES", bundleIdentifier: "com.zjx.download.verification", environment: environment,
            homeDirectory: URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        ))
    }

    func testUnmarkedProductionBuildDoesNotRequireVerificationOverrides() throws {
        XCTAssertNil(try VerificationLaunchConfiguration.validateIfRequired(
            marker: "NO",
            bundleIdentifier: "com.zjx.download",
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        ))
    }
}
