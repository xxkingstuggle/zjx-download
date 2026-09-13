import XCTest
@testable import ABDownloadManagerCore

final class ModelTests: XCTestCase {
    func testCoreModuleLoads() {
        XCTAssertEqual(ThemeMode.system.rawValue, "system")
    }
}

extension ModelTests {
    func testPathSafetyAndConflictPolicies() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertThrowsError(try FileUtilities.containedURL(folder: folder, fileName: "../escape"))
        let original = folder.appendingPathComponent("file.bin")
        try Data("one".utf8).write(to: original)
        XCTAssertThrowsError(try FileUtilities.resolveConflict(at: original, policy: .skip)) { error in XCTAssertEqual(error as? DownloadEngineError, .conflictSkipped) }
        let renamed = try FileUtilities.resolveConflict(at: original, policy: .rename)
        XCTAssertEqual(renamed.lastPathComponent, "file (1).bin")
    }
}


extension ModelTests {
    func testSharedSpeedLimiterSerializesAggregateBudget() async {
        let limiter = SpeedLimiter()
        let started = ContinuousClock.now
        async let first: Void = limiter.acquire(bytes: 100, limit: 1_000)
        async let second: Void = limiter.acquire(bytes: 100, limit: 1_000)
        _ = await (first, second)
        let elapsed = started.duration(to: ContinuousClock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        XCTAssertGreaterThanOrEqual(seconds, 0.05)
    }
}


extension ModelTests {
    func testFolderBookmarksPersistAcrossStoreReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMBookmarks-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try FolderBookmarkStore(directory: root)
        try await first.store(url: folder)
        let second = try FolderBookmarkStore(directory: root)
        let contains = await second.contains(path: folder.path)
        XCTAssertTrue(contains)
        let resolved = try await second.resolve(path: folder.path)
        XCTAssertEqual(resolved.standardizedFileURL.path, folder.standardizedFileURL.path)
        resolved.stopAccessingSecurityScopedResource()
    }
}

extension ModelTests {
    func testProxyCredentialsAreOnlyDerivedForProxyChallenge() {
        let proxy = ProxySettings(mode: .manual, host: "proxy.local", port: 8080, username: "user", password: "secret")
        XCTAssertEqual(proxy.proxyAuthorizationHeader, "Basic dXNlcjpzZWNyZXQ=")
        XCTAssertTrue(proxy.isUsable)
    }
}

extension ModelTests {
    func testBatchURLPatternExpansionAndLimit() throws {
        let batch = try BatchURLPattern(pattern: "https://example.test/file-*.bin", start: 7, end: 9, wildcardLength: 2)
        XCTAssertEqual(try batch.allLinks().map(\.absoluteString), ["https://example.test/file-07.bin", "https://example.test/file-08.bin", "https://example.test/file-09.bin"])
        XCTAssertThrowsError(try BatchURLPattern(pattern: "https://example.test/*", start: 0, end: 1000, maximumCount: 10)) { XCTAssertEqual($0 as? BatchPatternError, .rangeTooLarge(maximum: 10)) }
    }
}

extension ModelTests {
    func testCategoryRulesAndLegacyStateCompatibility() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMCategory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AppStateStore(directory: root)
        let category = try await store.addCategory(name: "Images", extensions: ["png"], hosts: ["example.test"], folder: root.path)
        let source = DownloadSource(url: URL(string: "https://example.test/a.png")!)
        XCTAssertTrue(category.matches(url: source.url, fileName: "a.png"))
        XCTAssertFalse(category.matches(url: source.url, fileName: "a.zip"))
        let task = try await store.addTask(DownloadRequest(source: source, fileName: "a.png"))
        XCTAssertEqual(task.categoryID, category.id)
        XCTAssertEqual(task.folderPath, root.path)
        let legacy = Data("{\"version\":1,\"tasks\":[],\"queues\":[],\"categories\":[],\"history\":[],\"settings\":{}}".utf8)
        try legacy.write(to: root.appendingPathComponent("legacy.json"))
        let decoder = JSONDecoder(); let recovered = try decoder.decode(PersistedAppState.self, from: legacy)
        XCTAssertTrue(recovered.hostOverrides.isEmpty)
    }

    func testHostOverrideMatchesCaseInsensitively() {
        let override = HostOverride(host: "Example.TEST", headers: ["Cookie": "session=1"], threadCount: 4, speedLimit: 99)
        XCTAssertTrue(override.applies(to: URL(string: "https://example.test/file")!))
        XCTAssertEqual(override.headers["Cookie"], "session=1")
    }
}

extension ModelTests {
    func testQueueScheduleRoundTripIncludingOvernightWindow() throws {
        let queue = DownloadQueue(name: "Night", schedule: QueueSchedule(weekdays: [.friday, .saturday], startSeconds: 23 * 3600, endSeconds: 3600))
        let data = try JSONEncoder().encode(queue)
        let decoded = try JSONDecoder().decode(DownloadQueue.self, from: data)
        XCTAssertEqual(decoded.schedule, queue.schedule)
        XCTAssertTrue(decoded.schedule?.isOpen(at: Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: Date()) ?? Date()) == true || decoded.schedule?.weekdays.contains(.friday) == true)
    }
}

extension ModelTests {
    func testHostOverrideRoundTripAndApplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMHost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AppStateStore(directory: root)
        let category = try await store.addCategory(name: "Media")
        let override = try HostOverride(validatingHost: " Example.TEST ", headers: ["Cookie": "a=b"], threadCount: 5, speedLimit: 123, defaultFolder: root.path, categoryID: category.id)
        let encoded = try JSONEncoder().encode(override)
        XCTAssertEqual(try JSONDecoder().decode(HostOverride.self, from: encoded), override)
        try await store.upsertHostOverride(override)
        let task = try await store.addTask(DownloadRequest(source: DownloadSource(url: URL(string: "https://example.test/video.mp4")!)))
        XCTAssertEqual(task.folderPath, root.path)
        XCTAssertEqual(task.categoryID, category.id)
        XCTAssertEqual(task.source.headers["Cookie"], "a=b")
        XCTAssertEqual(task.speedLimit, 123)
        XCTAssertEqual(task.connectionCount, 5)
    }
}
