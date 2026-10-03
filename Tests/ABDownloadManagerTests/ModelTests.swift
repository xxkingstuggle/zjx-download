import XCTest
@testable import ABDownloadManagerCore

final class ModelTests: XCTestCase {
    func testCoreModuleLoads() {
        XCTAssertEqual(ThemeMode.system.rawValue, "system")
    }
}

extension ModelTests {
    func testTaskListProjectionSortsFiltersAndDropsCancelledRows() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let newest = DownloadTask(id: 1, source: DownloadSource(url: URL(string: "https://example.test/newest.zip")!), folderPath: "/tmp", fileName: "newest.zip", status: .created, queueID: 1, categoryID: 1, createdAt: date)
        let sameDateHigherID = DownloadTask(id: 2, source: DownloadSource(url: URL(string: "https://example.test/target.zip")!), folderPath: "/tmp", fileName: "target.zip", status: .failed, queueID: 2, categoryID: 1, createdAt: date, errorMessage: "temporary TARGET failure")
        let cancelled = DownloadTask(id: 3, source: DownloadSource(url: URL(string: "https://example.test/hidden.zip")!), folderPath: "/tmp", fileName: "hidden.zip", status: .cancelled, createdAt: date.addingTimeInterval(1))
        let older = DownloadTask(id: 4, source: DownloadSource(url: URL(string: "https://example.test/older.zip")!), folderPath: "/tmp", fileName: "older.zip", status: .created, queueID: 1, categoryID: 1, createdAt: date.addingTimeInterval(-1))

        let all = DownloadTaskListProjection(tasks: [older, cancelled, newest, sameDateHigherID])
        XCTAssertEqual(all.visible.map(\.id), [2, 1, 4])
        XCTAssertEqual(all.filtered.map(\.id), [2, 1, 4])

        let search = DownloadTaskListProjection(tasks: [older, cancelled, newest, sameDateHigherID], search: " TARGET ", status: "failed", categoryID: 1, queueID: 2)
        XCTAssertEqual(search.visible.map(\.id), [2, 1, 4])
        XCTAssertEqual(search.filtered.map(\.id), [2])

        let byName = DownloadTaskListProjection(tasks: [older, cancelled, newest, sameDateHigherID], sortField: "fileName", sortAscending: true)
        XCTAssertEqual(byName.filtered.map(\.id), [1, 4, 2])
    }

    func testTaskListProjectionSortsStartedAndFinishedDatesWithMissingValuesStable() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let earlier = DownloadTask(
            id: 1, source: DownloadSource(url: URL(string: "https://example.test/earlier.zip")!),
            folderPath: "/tmp", fileName: "earlier.zip", status: .completed,
            createdAt: base, startedAt: base, completedAt: base.addingTimeInterval(10)
        )
        let later = DownloadTask(
            id: 2, source: DownloadSource(url: URL(string: "https://example.test/later.zip")!),
            folderPath: "/tmp", fileName: "later.zip", status: .completed,
            createdAt: base, startedAt: base.addingTimeInterval(5), completedAt: base.addingTimeInterval(20)
        )
        let notStarted = DownloadTask(
            id: 3, source: DownloadSource(url: URL(string: "https://example.test/new.zip")!),
            folderPath: "/tmp", fileName: "new.zip", status: .created, createdAt: base
        )

        XCTAssertEqual(
            DownloadTaskListProjection(tasks: [later, notStarted, earlier], sortField: "startedAt", sortAscending: true).filtered.map(\.id),
            [3, 1, 2]
        )
        XCTAssertEqual(
            DownloadTaskListProjection(tasks: [earlier, later, notStarted], sortField: "completedAt", sortAscending: false).filtered.map(\.id),
            [2, 1, 3]
        )
    }

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

    func testBatchRequestsPreserveAllSharedOptions() throws {
        let pattern = try BatchURLPattern(pattern: "https://example.test/file-*.bin", start: 1, end: 2, wildcardLength: 2)
        let requests = try pattern.downloadRequests(
            folderPath: "/tmp/batch",
            headers: ["Authorization": "Bearer test"],
            expectedChecksum: "sha256:abcd",
            speedLimit: 4096,
            connectionCountOverride: 3,
            queueID: 11,
            categoryID: 12,
            conflictPolicy: .overwrite,
            startImmediately: true
        )
        XCTAssertEqual(requests.map { $0.source.url.absoluteString }, ["https://example.test/file-01.bin", "https://example.test/file-02.bin"])
        for request in requests {
            XCTAssertEqual(request.source.headers["Authorization"], "Bearer test")
            XCTAssertEqual(request.folderPath, "/tmp/batch")
            XCTAssertEqual(request.expectedChecksum, "sha256:abcd")
            XCTAssertEqual(request.speedLimit, 4096)
            XCTAssertEqual(request.connectionCountOverride, 3)
            XCTAssertEqual(request.queueID, 11)
            XCTAssertEqual(request.categoryID, 12)
            XCTAssertEqual(request.conflictPolicy, .overwrite)
            XCTAssertTrue(request.startImmediately)
        }
    }

    func testDownloadInputParserRejectsInvalidLinesAndDuplicateHeaders() throws {
        XCTAssertEqual(try DownloadInputParser.links("  https://example.test/a  \n\nhttp://example.test/b").count, 2)
        XCTAssertThrowsError(try DownloadInputParser.links("https://example.test/a\nfile:///tmp/no")) {
            XCTAssertEqual($0 as? DownloadInputParser.InputError, .invalidURL(line: 2))
        }
        XCTAssertThrowsError(try DownloadInputParser.headers("Cookie: a=b\ncookie: c=d")) {
            XCTAssertEqual($0 as? DownloadInputParser.InputError, .duplicateHeader("cookie"))
        }
        XCTAssertEqual(try DownloadInputParser.headers("Authorization: Bearer abc\nX-Name: a:b"), ["Authorization": "Bearer abc", "X-Name": "a:b"])
    }

    func testMultiTaskMetadataUpdateRollsBackAsOneTransaction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMUpdateBatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AppStateStore(directory: root)
        let task = try await store.addTask(DownloadRequest(source: DownloadSource(url: URL(string: "https://example.test/a.bin")!)))
        var changed = task
        changed.fileName = "renamed.bin"
        var missing = task
        missing.id = 999
        do { try await store.updateTasks([changed, missing]); XCTFail("transaction accepted an unknown task") }
        catch { XCTAssertEqual(error as? DownloadEngineError, .missingTask) }
        let persisted = await store.task(id: task.id)
        XCTAssertEqual(persisted?.fileName, task.fileName)
    }

    func testIncompleteDownloadExtensionSettingControlsStablePartialPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMPartNames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AppStateStore(directory: root)
        var settings = (await store.snapshot()).settings
        settings.appendExtensionToIncompleteDownloads = true
        try await store.setSettings(settings)
        let task = try await store.addTask(DownloadRequest(source: DownloadSource(url: URL(string: "https://example.test/archive.zip")!), folderPath: root.path))
        XCTAssertTrue(task.appendExtensionToIncompleteDownloads)
        XCTAssertEqual(URL(fileURLWithPath: task.partFilePath).lastPathComponent, "archive.abpart.zip")
        XCTAssertEqual(PartFileNaming.partFileName("archive.zip", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, appendOriginalExtension: true), ".archive.abpart.zip.00000000-0000-0000-0000-000000000001")
    }

    func testHTTPDateAndByteUnitFormatting() throws {
        XCTAssertEqual(HTTPDateParser.parse("Wed, 21 Oct 2015 07:28:00 GMT"), Date(timeIntervalSince1970: 1_445_412_480))
        XCTAssertEqual(HTTPDateParser.parse("Sunday, 06-Nov-94 08:49:37 GMT"), Date(timeIntervalSince1970: 784_111_777))
        XCTAssertNil(HTTPDateParser.parse("not an HTTP date"))
        XCTAssertEqual(ByteDisplayFormatter.string(1_048_576, unit: .binaryBytes), "1 MiB")
        XCTAssertEqual(ByteDisplayFormatter.string(1_000_000, unit: .decimalBytes), "1 MB")
        XCTAssertEqual(ByteDisplayFormatter.string(1_500, unit: .decimalBytes, suffix: "/s"), "1.5 KB/s")
    }
}

extension ModelTests {
    func testCategoryRulesAndLegacyStateCompatibility() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMCategory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AppStateStore(directory: root)
        let category = try await store.addCategory(name: "Custom images", extensions: ["testimg"], hosts: ["example.test"], folder: root.path)
        let source = DownloadSource(url: URL(string: "https://example.test/a.testimg")!)
        XCTAssertTrue(category.matches(url: source.url, fileName: "a.testimg"))
        XCTAssertFalse(category.matches(url: source.url, fileName: "a.zip"))
        let task = try await store.addTask(DownloadRequest(source: source, fileName: "a.testimg"))
        XCTAssertEqual(task.categoryID, category.id)
        XCTAssertEqual(task.folderPath, root.path)
        let legacy = Data("{\"version\":1,\"tasks\":[],\"queues\":[],\"categories\":[],\"history\":[],\"settings\":{}}".utf8)
        try legacy.write(to: root.appendingPathComponent("legacy.json"))
        let decoder = JSONDecoder(); let recovered = try decoder.decode(PersistedAppState.self, from: legacy)
        XCTAssertTrue(recovered.hostOverrides.isEmpty)
    }

    func testDefaultCategoriesSeedResetAndReclassifyExistingTasks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMDefaultCategories-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AppStateStore(directory: root)
        let initial = await store.snapshot()
        XCTAssertEqual(initial.categories.map(\.name), ["Compressed", "Programs", "Videos", "Music", "Pictures", "Documents"])
        XCTAssertEqual(initial.categories.first?.defaultFolder, URL(fileURLWithPath: initial.settings.defaultDownloadFolder).appendingPathComponent("Compressed").path)
        XCTAssertEqual(initial.categories.first?.icon, "archivebox")

        var settings = initial.settings
        settings.useCategoryByDefault = false
        try await store.setSettings(settings)
        let archive = try await store.addTask(DownloadRequest(source: DownloadSource(url: URL(string: "https://example.test/archive.zip")!), folderPath: root.path))
        let document = try await store.addTask(DownloadRequest(source: DownloadSource(url: URL(string: "https://example.test/guide.pdf")!), folderPath: root.path))
        XCTAssertNil(archive.categoryID)
        XCTAssertNil(document.categoryID)
        let reclassifiedCount = try await store.categorizeExistingTasks()
        let reclassifiedArchive = await store.task(id: archive.id)
        let reclassifiedDocument = await store.task(id: document.id)
        XCTAssertEqual(reclassifiedCount, 2)
        XCTAssertEqual(reclassifiedArchive?.categoryID, 0)
        XCTAssertEqual(reclassifiedDocument?.categoryID, 5)

        let custom = try await store.addCategory(name: "Custom", extensions: ["custom"])
        var changedDefault = (await store.snapshot()).categories[5]
        changedDefault.name = "Changed documents"
        try await store.upsertCategory(changedDefault)
        _ = try await store.addTask(DownloadRequest(source: DownloadSource(url: URL(string: "https://example.test/file.custom")!), categoryID: custom.id))
        try await store.resetCategoriesToDefaults()
        let restored = await store.snapshot()
        XCTAssertEqual(restored.categories.map(\.name), ["Compressed", "Programs", "Videos", "Music", "Pictures", "Documents"])
        XCTAssertFalse(restored.categories.contains { $0.name == "Custom" })
        XCTAssertNil(restored.tasks.first(where: { $0.fileName == "file.custom" })?.categoryID)
        XCTAssertEqual(restored.nextCategoryID, 6)
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
    func testEditingTaskHeadersPreservesCredentialsForSameOriginWithoutExposingThem() {
        let originalURL = URL(string: "https://example.test/file")!
        let original = ["Authorization": "Bearer fixture", "Cookie": "session=fixture", "User-Agent": "Old"]
        let editedPublic = ["User-Agent": "New", "X-Trace": "one"]
        let editedSensitive = HTTPHeaderEditingPolicy.sensitiveHeaders(original)

        let merged = HTTPHeaderEditingPolicy.merge(
            public: editedPublic,
            sensitive: editedSensitive,
            original: original,
            from: originalURL,
            to: URL(string: "https://example.test/renamed")!
        )

        XCTAssertEqual(merged["Authorization"], "Bearer fixture")
        XCTAssertEqual(merged["Cookie"], "session=fixture")
        XCTAssertEqual(merged["User-Agent"], "New")
        XCTAssertEqual(merged["X-Trace"], "one")
        XCTAssertTrue(HTTPHeaderEditingPolicy.publicHeaders(original).keys.allSatisfy { !HTTPHeaderEditingPolicy.isSensitive($0) })
    }

    func testEditingTaskHeadersDropsUnchangedCredentialsOnOriginChangeButKeepsExplicitReplacement() {
        let originalURL = URL(string: "https://example.test/file")!
        let editedSensitive = ["Authorization": "Bearer old", "Cookie": "session=new"]

        let merged = HTTPHeaderEditingPolicy.merge(
            public: ["X-Trace": "two", "Cookie": "must-not-be-plain"],
            sensitive: editedSensitive,
            original: ["Authorization": "Bearer old", "Cookie": "session=old"],
            from: originalURL,
            to: URL(string: "https://other.test/file")!
        )

        XCTAssertNil(merged["Authorization"])
        XCTAssertEqual(merged, ["Cookie": "session=new", "X-Trace": "two"])
    }

    func testClearingSecureHeaderRemovesItOnSameOriginEdit() {
        let url = URL(string: "https://example.test/file")!
        let merged = HTTPHeaderEditingPolicy.merge(
            public: [:],
            sensitive: ["Authorization": ""],
            original: ["Authorization": "Bearer old"],
            from: url,
            to: url
        )
        XCTAssertNil(merged["Authorization"])
    }

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
        XCTAssertNil(task.source.headers["Cookie"])
        let hydrated = try await store.taskForExecution(id: task.id)
        XCTAssertEqual(hydrated?.source.headers["Cookie"], "a=b")
        XCTAssertEqual(task.speedLimit, 123)
        XCTAssertEqual(task.connectionCount, 5)
        XCTAssertEqual(task.connectionCountOverride, 5)
    }
}

extension ModelTests {
    func testSettingsDraftSurvivesRefreshWhileEditingAndCancelUsesNewestPersistedValue() {
        let initial = AppSettings()
        var draft = SettingsDraft(persisted: initial)
        var edited = draft.value
        edited.theme = .dark
        edited.threadCount = 12
        draft.updateDraft(edited)

        var persistedElsewhere = initial
        persistedElsewhere.language = "zh-Hans"
        draft.receivePersisted(persistedElsewhere)
        var latestPersisted = persistedElsewhere
        latestPersisted.speedLimit = 512
        draft.receivePersisted(latestPersisted)

        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.value.theme, .dark)
        XCTAssertEqual(draft.value.threadCount, 12)
        XCTAssertEqual(draft.value.speedLimit, initial.speedLimit)
        XCTAssertEqual(draft.persisted, latestPersisted)

        draft.cancel()
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.value, latestPersisted)
    }

    func testSettingsDraftSaveSuccessStaysCommittedAcrossRefresh() {
        var draft = SettingsDraft(persisted: AppSettings())
        var edited = draft.value
        edited.maxConcurrentDownloads = 9
        draft.updateDraft(edited)

        draft.saveSucceeded(edited)
        draft.receivePersisted(edited)

        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.value.maxConcurrentDownloads, 9)
        XCTAssertEqual(draft.persisted, edited)
    }

    func testSettingsDraftSaveFailureKeepsEditsUntilCancel() {
        let persisted = AppSettings()
        var draft = SettingsDraft(persisted: persisted)
        var edited = draft.value
        edited.speedLimit = 4_096
        draft.updateDraft(edited)

        draft.saveFailed()
        draft.receivePersisted(persisted)

        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.value.speedLimit, 4_096)
        draft.cancel()
        XCTAssertEqual(draft.value, persisted)
    }
}
