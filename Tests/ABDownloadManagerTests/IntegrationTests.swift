import XCTest
import Network
import CryptoKit
@testable import ABDownloadManagerCore

final class IntegrationTests: XCTestCase {
    private var fixture: LocalHTTPFixture!
    private var directory: URL!

    override func setUpWithError() throws {
        fixture = try LocalHTTPFixture()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { fixture.stop(); try? FileManager.default.removeItem(at: directory) }

    func testRESTAddDefaultsRequireConfirmationAndQueuePreservesSelectedOrder() {
        let request = DownloadRequest(source: DownloadSource(url: URL(string: "http://fixture.test/one.bin")!))
        let interactive = RESTAddOperation(request: request)
        XCTAssertTrue(interactive.requiresUserConfirmation)
        XCTAssertFalse(interactive.shouldStartImmediately)

        let startAfterConfirmation = RESTAddOperation(
            request: request,
            options: RESTAddOptions(silentAdd: false, silentStart: true)
        )
        XCTAssertTrue(startAfterConfirmation.requiresUserConfirmation)
        XCTAssertTrue(startAfterConfirmation.shouldStartImmediately)

        let silent = RESTAddOperation(request: request, options: RESTAddOptions(silentAdd: true, silentStart: true))
        XCTAssertFalse(silent.requiresUserConfirmation)

        var queue = RESTAddConfirmationQueue()
        queue.enqueue(interactive)
        queue.enqueue(startAfterConfirmation)
        XCTAssertEqual(queue.count, 2)
        XCTAssertTrue(queue.current?.requiresUserConfirmation == true)
        _ = queue.resolveCurrent()
        XCTAssertTrue(queue.current?.shouldStartImmediately == true)
        _ = queue.resolveCurrent()
        XCTAssertNil(queue.current)
    }

    func testHTTPProbeAndRangeDownload() async throws {
        let store = try AppStateStore(directory: directory)
        let engine = DownloadEngine(store: store)
        let task = try await store.addTask(DownloadRequest(source: DownloadSource(url: fixture.baseURL.appendingPathComponent("file")), folderPath: directory.path, fileName: "file.bin", startImmediately: false))
        try await engine.start(taskID: task.id)
        let completed = try await waitForTask(task.id, store: store)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: completed.filePath)), fixture.body)
        XCTAssertTrue(completed.supportsRanges)
        XCTAssertGreaterThan(completed.parts.count, 1)
        XCTAssertGreaterThanOrEqual(fixture.ranges().count, 2)
    }

    func testReleaseRangeThroughputOneFourEightConnectionsAgainstURLSession() async throws {
        let store = try AppStateStore(directory: directory)
        var settings = (await store.snapshot()).settings
        settings.maxConcurrentDownloads = 1
        try await store.setSettings(settings)
        let expectedDigest = SHA256.hash(data: fixture.body).map { String(format: "%02x", $0) }.joined()

        for sample in 1...5 {
            let directURL = fixture.baseURL.appendingPathComponent("file")
            let directStart = ContinuousClock.now
            let (directFile, directResponse) = try await URLSession(configuration: .ephemeral).download(from: directURL)
            let directSeconds = Self.elapsedSeconds(from: directStart)
            let directData = try Data(contentsOf: directFile)
            try? FileManager.default.removeItem(at: directFile)
            XCTAssertEqual((directResponse as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(SHA256.hash(data: directData).map { String(format: "%02x", $0) }.joined(), expectedDigest)
            print(String(format: "PERF_URLSESSION sample=%d bytes=%d seconds=%.6f MiBps=%.2f", sample, directData.count, directSeconds, Double(directData.count) / 1_048_576 / directSeconds))

            for connections in [1, 4, 8] {
                settings.threadCount = connections
                try await store.setSettings(settings)
                let testSettings = settings
                let engine = DownloadEngine(store: store, settingsProvider: { testSettings })
                let task = try await store.addTask(DownloadRequest(
                    source: DownloadSource(url: fixture.baseURL.appendingPathComponent("file")),
                    folderPath: directory.path,
                    fileName: "throughput-\(connections)-\(sample).bin"
                ))
                let priorRangeCount = fixture.ranges().count
                let start = ContinuousClock.now
                try await engine.start(taskID: task.id)
                let result = try await waitForTask(task.id, store: store)
                let seconds = Self.elapsedSeconds(from: start)
                let rangeCount = fixture.ranges().count - priorRangeCount
                let data = try Data(contentsOf: URL(fileURLWithPath: result.filePath))
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(result.status, .completed, result.errorMessage ?? "no error")
                XCTAssertEqual(result.connectionCount, connections)
                XCTAssertEqual(result.parts.count, connections)
                XCTAssertGreaterThan(rangeCount, 0)
                XCTAssertEqual(data.count, fixture.body.count)
                XCTAssertEqual(digest, expectedDigest)
                print(String(format: "PERF_ENGINE connections=%d sample=%d ranges=%d bytes=%d seconds=%.6f MiBps=%.2f sha256=%@", connections, sample, rangeCount, data.count, seconds, Double(data.count) / 1_048_576 / seconds, digest))
            }
        }
    }

    func testPerHostConnectionsOverrideGlobalDuringRealRangeDownload() async throws {
        let store = try AppStateStore(directory: directory)
        var settings = (await store.snapshot()).settings
        settings.threadCount = 8
        try await store.setSettings(settings)
        try await store.upsertHostOverride(HostOverride(host: "127.0.0.1", threadCount: 2))
        let testSettings = settings

        let task = try await store.addTask(DownloadRequest(
            source: DownloadSource(url: fixture.baseURL.appendingPathComponent("file")),
            folderPath: directory.path,
            fileName: "host-threads.bin"
        ))
        XCTAssertEqual(task.connectionCountOverride, 2)
        XCTAssertEqual(task.connectionCount, 2)

        let engine = DownloadEngine(store: store, settingsProvider: { testSettings })
        try await engine.start(taskID: task.id)
        let result = try await waitForTask(task.id, store: store)
        XCTAssertEqual(result.status, .completed, result.errorMessage ?? "no error")
        XCTAssertEqual(result.connectionCount, 2)
        XCTAssertEqual(result.parts.count, 2)
        XCTAssertGreaterThanOrEqual(fixture.ranges().count, 2)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.filePath)), fixture.body)
    }

    func testDownloadCategoryUsesServerSuggestedFilenameWhenURLHasNoExtension() async throws {
        let store = try AppStateStore(directory: directory)
        var settings = (await store.snapshot()).settings
        settings.useCategoryByDefault = true
        try await store.setSettings(settings)

        var archive = (await store.snapshot()).categories.first(where: { $0.name == "Compressed" })!
        let categoryFolder = directory.appendingPathComponent("categorized", isDirectory: true)
        archive.categoryPath = categoryFolder.path
        try await store.upsertCategory(archive)

        let source = DownloadSource(url: fixture.baseURL.appendingPathComponent("named"))
        let task = try await store.addTask(DownloadRequest(source: source))
        XCTAssertNil(task.categoryID, "The URL itself has no extension; classification waits for probe metadata.")
        XCTAssertEqual(task.folderPath, settings.defaultDownloadFolder)

        let downloadSettings = (await store.snapshot()).settings
        let engine = DownloadEngine(store: store, settingsProvider: { downloadSettings })
        try await engine.start(taskID: task.id)
        let result = try await waitForTask(task.id, store: store)

        XCTAssertEqual(result.status, .completed, result.errorMessage ?? "no error")
        XCTAssertEqual(result.fileName, "category-proof.zip")
        XCTAssertEqual(result.categoryID, archive.id)
        XCTAssertEqual(result.folderPath, categoryFolder.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.filePath)), fixture.body)
    }

    func testDisablingDynamicPartsUsesOneRealRange() async throws {
        let store = try AppStateStore(directory: directory)
        var settings = (await store.snapshot()).settings
        settings.threadCount = 4
        settings.dynamicPartCreation = false
        try await store.setSettings(settings)
        let testSettings = settings
        let engine = DownloadEngine(store: store, settingsProvider: { testSettings })
        let task = try await store.addTask(DownloadRequest(
            source: DownloadSource(url: fixture.baseURL.appendingPathComponent("file")),
            folderPath: directory.path,
            fileName: "single-range.bin"
        ))
        try await engine.start(taskID: task.id)
        let result = try await waitForTask(task.id, store: store)
        XCTAssertEqual(result.status, .completed, result.errorMessage ?? "no error")
        XCTAssertEqual(result.connectionCount, 1)
        XCTAssertEqual(result.parts.count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.filePath)), fixture.body)
    }

    func testServerLastModifiedSettingChangesFileDate() async throws {
        let store = try AppStateStore(directory: directory)
        var settings = (await store.snapshot()).settings
        settings.useServerLastModifiedTime = true
        try await store.setSettings(settings)
        let testSettings = settings
        let engine = DownloadEngine(store: store, settingsProvider: { testSettings })
        let task = try await store.addTask(DownloadRequest(
            source: DownloadSource(url: fixture.baseURL.appendingPathComponent("file")),
            folderPath: directory.path,
            fileName: "server-date.bin"
        ))
        try await engine.start(taskID: task.id)
        let result = try await waitForTask(task.id, store: store)
        XCTAssertEqual(result.status, .completed, result.errorMessage ?? "no error")
        let values = try URL(fileURLWithPath: result.filePath).resourceValues(forKeys: [.contentModificationDateKey])
        XCTAssertEqual(values.contentModificationDate, Date(timeIntervalSince1970: 1_445_412_480))
    }

    func testNoRangeFallbackAndRedirect() async throws {
        let store = try AppStateStore(directory: directory)
        let engine = DownloadEngine(store: store)
        for (path, name) in [("norange", "plain.bin"), ("redirect", "redirect.bin")] {
            let task = try await store.addTask(DownloadRequest(source: DownloadSource(url: fixture.baseURL.appendingPathComponent(path)), folderPath: directory.path, fileName: name))
            try await engine.start(taskID: task.id)
            let result = try await waitForTask(task.id, store: store)
            XCTAssertEqual(result.status, .completed)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.filePath)), fixture.body)
        }
    }

    func testHLSAssembly() async throws {
        let store = try AppStateStore(directory: directory)
        let engine = DownloadEngine(store: store)
        let source = DownloadSource(url: fixture.baseURL.appendingPathComponent("hls/index.m3u8"))
        let task = try await store.addTask(DownloadRequest(source: source, folderPath: directory.path, fileName: "video.ts", kind: .hls))
        try await engine.start(taskID: task.id)
        let result = try await waitForTask(task.id, store: store)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.filePath)), Data("segment-onesegment-two".utf8))
    }

    func testHeadersAndBasicAuth() async throws {
        let session = URLSession(configuration: .ephemeral)
        let auth = DownloadSource(url: fixture.baseURL.appendingPathComponent("auth"), headers: ["Authorization": "Basic dGVzdDpzZWNyZXQ="])
        let authResponse = try await HTTPClient().request(url: auth.url, headers: auth.headers)
        XCTAssertEqual(authResponse.response.statusCode, 200)
        let cookieResponse = try await session.data(from: fixture.baseURL.appendingPathComponent("cookie"))
        XCTAssertEqual((cookieResponse.1 as? HTTPURLResponse)?.statusCode, 403)
        let cookie = try await HTTPClient().request(url: fixture.baseURL.appendingPathComponent("cookie"), headers: ["Cookie": "session=ok"])
        XCTAssertEqual(cookie.response.statusCode, 200)
    }

    func testEngineHydratesPersistedTaskCredentialsOnlyWhenStarted() async throws {
        let store = try AppStateStore(directory: directory)
        let task = try await store.addTask(DownloadRequest(
            source: DownloadSource(url: fixture.baseURL.appendingPathComponent("cookie"), headers: ["Cookie": "session=ok"]),
            folderPath: directory.path,
            fileName: "cookie.bin"
        ))
        XCTAssertNil(task.source.headers["Cookie"])

        let prefix = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(24)
            .description
        defer { try? KeychainCredentialStore().remove(account: "\(prefix).task.\(task.id).headers") }

        // A fresh store has no in-memory credential cache. Starting the task
        // must retrieve the saved Cookie for HTTP requests after relaunch.
        let reopened = try AppStateStore(directory: directory)
        let publicSnapshot = await reopened.snapshot()
        XCTAssertNil(publicSnapshot.tasks.first?.source.headers["Cookie"])
        let engine = DownloadEngine(store: reopened)
        try await engine.start(taskID: task.id)
        let completed = try await waitForTask(task.id, store: reopened)
        XCTAssertEqual(completed.status, .completed, completed.errorMessage ?? "no error")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: completed.filePath)), fixture.body)
    }

    func testPersistenceRecoversActiveTasks() async throws {
        let store = try AppStateStore(directory: directory)
        var task = try await store.addTask(DownloadRequest(source: DownloadSource(url: fixture.baseURL.appendingPathComponent("file")), folderPath: directory.path, fileName: "recover.bin"))
        task.status = .downloading
        try await store.updateTask(task)
        let reopened = try AppStateStore(directory: directory)
        let recovered = await reopened.task(id: task.id)
        XCTAssertEqual(recovered?.status, .paused)
    }

    private func waitForTask(_ id: Int64, store: AppStateStore) async throws -> DownloadTask {
        for _ in 0..<200 {
            if let task = await store.task(id: id), task.status == .completed || task.status == .failed || task.status == .cancelled { return task }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("fixture download did not finish before the 5-second deadline")
        throw NSError(domain: "ABDownloadManagerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture download timeout"])
    }

    private static func elapsedSeconds(from start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

extension IntegrationTests {
    func testRESTAuthenticationRejectsMissingOrWhitespaceAPIKey() throws {
        for key in ["", " \n\t"] {
            XCTAssertThrowsError(try RESTService(
                settings: IntegrationSettings(enabled: true, port: 25152, authEnabled: true, apiKey: key),
                addHandler: { _ in },
                queueProvider: { [] }
            )) { error in
                XCTAssertEqual(error as? RESTService.ConfigurationError, .missingAPIKey)
            }
        }
        XCTAssertNoThrow(try RESTService(
            settings: IntegrationSettings(enabled: true, port: 25152, authEnabled: true, apiKey: "secret"),
            addHandler: { _ in },
            queueProvider: { [] }
        ))
    }

    func testRESTCompatibility() async throws {
        let received = RequestRecorder()
        XCTAssertEqual(RESTService.bindHost, "127.0.0.1")
        let service = try RESTService(settings: IntegrationSettings(enabled: true, port: 25151, authEnabled: true, apiKey: "test-key"), addHandler: { operation in await received.append(operation) }, queueProvider: { [DownloadQueue(id: 7, name: "Night") ] })
        try await service.start()
        let endpoint = await service.boundEndpoint() ?? ""
        XCTAssertTrue(endpoint.contains("127.0.0.1"))
        defer { Task { await service.stop() } }
        let session = URLSession(configuration: .ephemeral)
        var ping = URLRequest(url: URL(string: "http://127.0.0.1:25151/ping")!); ping.httpMethod = "POST"; ping.setValue("test-key", forHTTPHeaderField: "X-Api-Key")
        let pong = try await session.data(for: ping)
        XCTAssertEqual(String(data: pong.0, encoding: .utf8), "pong")
        var add = URLRequest(url: URL(string: "http://127.0.0.1:25151/add")!); add.httpMethod = "POST"; add.setValue("test-key", forHTTPHeaderField: "X-Api-Key")
        add.httpBody = Data("{\"items\":[{\"link\":\"\(fixture.baseURL.appendingPathComponent("file").absoluteString)\"}],\"options\":{\"silentStart\":true}}".utf8)
        let added = try await session.data(for: add)
        XCTAssertEqual((added.1 as? HTTPURLResponse)?.statusCode, 200)
        var headless = URLRequest(url: URL(string: "http://127.0.0.1:25151/start-headless-download")!); headless.httpMethod = "POST"; headless.setValue("test-key", forHTTPHeaderField: "X-Api-Key")
        headless.httpBody = Data("{\"downloadSource\":{\"link\":\"\(fixture.baseURL.appendingPathComponent("file").absoluteString)\"},\"queueId\":7,\"startQueue\":true}".utf8)
        let headlessResponse = try await session.data(for: headless)
        XCTAssertEqual((headlessResponse.1 as? HTTPURLResponse)?.statusCode, 200)
        let requestCount = await received.count
        XCTAssertEqual(requestCount, 2)
        guard requestCount == 2 else { return }
        let operations = await received.operations
        XCTAssertTrue(operations[0].options.silentStart)
        XCTAssertTrue(operations[1].request.enqueue)
        XCTAssertTrue(operations[1].startQueue)

        var unauthorized = URLRequest(url: URL(string: "http://127.0.0.1:25151/ping")!); unauthorized.httpMethod = "POST"
        let denied = try await session.data(for: unauthorized)
        XCTAssertEqual((denied.1 as? HTTPURLResponse)?.statusCode, 401)
        var wrongKey = URLRequest(url: URL(string: "http://127.0.0.1:25151/ping")!); wrongKey.httpMethod = "POST"; wrongKey.setValue("wrong-test-key", forHTTPHeaderField: "X-Api-Key")
        let wrongKeyDenied = try await session.data(for: wrongKey)
        XCTAssertEqual((wrongKeyDenied.1 as? HTTPURLResponse)?.statusCode, 401)
        var queues = URLRequest(url: URL(string: "http://127.0.0.1:25151/queues")!); queues.httpMethod = "GET"; queues.setValue("test-key", forHTTPHeaderField: "X-Api-Key")
        let queueResponse = try await session.data(for: queues)
        XCTAssertEqual((queueResponse.1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: queueResponse.0, encoding: .utf8)?.contains("Night") == true)
        var options = URLRequest(url: URL(string: "http://127.0.0.1:25151/add")!); options.httpMethod = "OPTIONS"; options.setValue("http://localhost:3000", forHTTPHeaderField: "Origin"); options.setValue("X-Api-Key, Content-Type", forHTTPHeaderField: "Access-Control-Request-Headers")
        let preflight = try await session.data(for: options)
        XCTAssertEqual((preflight.1 as? HTTPURLResponse)?.statusCode, 204)
    }

    func testSchedulerHonorsQueuedIntentAndStoppedQueue() async throws {
        let store = try AppStateStore(directory: directory)
        let engine = DownloadEngine(store: store)
        let scheduler = QueueScheduler(store: store, engine: engine)
        let normal = try await store.addTask(DownloadRequest(source: DownloadSource(url: fixture.baseURL.appendingPathComponent("file")), folderPath: directory.path, fileName: "manual.bin"))
        await scheduler.scheduleNow()
        let normalState = await store.task(id: normal.id)
        XCTAssertEqual(normalState?.status, .created)
        let queue = try await store.addQueue(name: "Paused queue")
        var stopped = queue; stopped.isRunning = false; try await store.updateQueue(stopped)
        let queued = try await store.addTask(DownloadRequest(source: DownloadSource(url: fixture.baseURL.appendingPathComponent("file")), folderPath: directory.path, fileName: "queued.bin", queueID: queue.id, enqueue: true))
        await scheduler.scheduleNow()
        let queuedState = await store.task(id: queued.id)
        XCTAssertEqual(queuedState?.status, .created)
    }

    func testManualProxyBypassAndPACRoutingReachLoopbackFixture() async throws {
        var directSettings = AppSettings()
        directSettings.proxy = ProxySettings(mode: .manual, scheme: .http, host: "127.0.0.1", port: 1, bypassList: " 127.0.0.1 ; localhost ")
        let bypassed = try await HTTPClient(settings: directSettings).request(url: fixture.baseURL.appendingPathComponent("file"))
        XCTAssertEqual(bypassed.response.statusCode, 200)
        XCTAssertEqual(bypassed.data.count, fixture.body.count)

        var pacSettings = AppSettings()
        pacSettings.proxy = ProxySettings(mode: .pac, pacURL: fixture.baseURL.appendingPathComponent("proxy.pac").absoluteString)
        XCTAssertTrue(pacSettings.proxy.isUsable)
        let proxied = try await HTTPClient(settings: pacSettings).request(url: fixture.baseURL.appendingPathComponent("file"))
        XCTAssertEqual(proxied.response.statusCode, 200)
        XCTAssertEqual(proxied.data.count, fixture.body.count)
        XCTAssertNil(ProxySettings.validPACURL("file:///tmp/proxy.pac"))
        XCTAssertEqual(HTTPClient.proxyBypassHosts("a.test, b.test; c.test\nd.test"), ["a.test", "b.test", "c.test", "d.test"])
    }

    func testChecksumAndScheduleBoundaries() throws {
        let value = Data("abc".utf8)
        XCTAssertEqual(try ChecksumCalculator.hash(algorithm: .md5, data: value), "900150983cd24fb0d6963f7d28e17f72")
        let schedule = QueueSchedule(weekdays: Set(QueueSchedule.Weekday.allCases), startSeconds: 23 * 3600, endSeconds: 3600)
        let late = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: Date())!
        let early = Calendar.current.date(bySettingHour: 0, minute: 30, second: 0, of: Date())!
        XCTAssertTrue(schedule.isOpen(at: late)); XCTAssertTrue(schedule.isOpen(at: early))
    }
}

private actor RequestRecorder {
    private(set) var operations: [RESTAddOperation] = []
    var count: Int { operations.count }
    func append(_ operation: RESTAddOperation) { operations.append(operation) }
}

extension IntegrationTests {
    func testRangeStateReconcilesLongAndShortPartFiles() async throws {
        let store = try AppStateStore(directory: directory)
        let engine = DownloadEngine(store: store)
        for (suffix, actualCount) in [("long", fixture.body.count * 3 / 4), ("short", fixture.body.count / 4)] {
            let task = try await store.addTask(DownloadRequest(source: DownloadSource(url: fixture.baseURL.appendingPathComponent("file")), folderPath: directory.path, fileName: "reconcile-\(suffix).bin"))
            var persisted = task
            let half = Int64(fixture.body.count / 2)
            let part = DownloadPart(from: 0, to: Int64(fixture.body.count - 1), downloaded: half)
            persisted.parts = [part]; persisted.downloadedSize = half
            try await store.updateTask(persisted)
            let partURL = directory.appendingPathComponent(".\(persisted.fileName).abpart.\(part.id.uuidString)")
            try fixture.body.prefix(actualCount).write(to: partURL)
            try await engine.start(taskID: task.id)
            let result = try await waitForTask(task.id, store: store)
            XCTAssertEqual(result.status, .completed, result.errorMessage ?? "no error")
            if result.status == .completed { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.filePath)), fixture.body) }
        }
    }

    func testCancelCleansPartFiles() async throws {
        let store = try AppStateStore(directory: directory)
        var settings = (await store.snapshot()).settings; settings.threadCount = 1; settings.maxDownloadRetryCount = 0
        try await store.setSettings(settings)
        let testSettings = settings
        let engine = DownloadEngine(store: store, settingsProvider: { testSettings })
        let task = try await store.addTask(DownloadRequest(source: DownloadSource(url: fixture.baseURL.appendingPathComponent("file")), folderPath: directory.path, fileName: "cancel.bin", speedLimit: 1))
        try await engine.start(taskID: task.id)
        try await Task.sleep(for: .milliseconds(75))
        try await engine.cancel(taskID: task.id, deletePartial: true)
        let result = await store.task(id: task.id)
        XCTAssertEqual(result?.status, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancel.bin.abpart").path))
        if let result { for part in result.parts { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".cancel.bin.abpart.\(part.id.uuidString)").path)) } }
    }

    func testCancelDuringInFlightRangeRequestKeepsCancelledStatus() async throws {
        let store = try AppStateStore(directory: directory)
        var settings = (await store.snapshot()).settings
        settings.threadCount = 1
        settings.maxDownloadRetryCount = 0
        settings.deletePartialFileOnDownloadCancellation = true
        try await store.setSettings(settings)
        let testSettings = settings
        let engine = DownloadEngine(store: store, settingsProvider: { testSettings })
        let task = try await store.addTask(DownloadRequest(
            source: DownloadSource(url: fixture.baseURL.appendingPathComponent("slow")),
            folderPath: directory.path,
            fileName: "cancel-in-flight.bin"
        ))

        try await engine.start(taskID: task.id)
        var requestObserved = false
        for _ in 0..<100 {
            if !fixture.ranges().isEmpty { requestObserved = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(requestObserved, "expected the fixture to hold an active Range request")

        try await engine.cancel(taskID: task.id)
        try await Task.sleep(for: .milliseconds(100))
        let result = await store.task(id: task.id)
        XCTAssertEqual(result?.status, .cancelled, result?.errorMessage ?? "no error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancel-in-flight.bin").path))
        if let result {
            for part in result.parts {
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".cancel-in-flight.bin.abpart.\(part.id.uuidString)").path))
            }
        }
    }

    func testAbortCleansPartFilesWithoutHistory() async throws {
        let store = try AppStateStore(directory: directory)
        var settings = (await store.snapshot()).settings; settings.threadCount = 1; settings.maxDownloadRetryCount = 0
        try await store.setSettings(settings)
        let testSettings = settings
        let engine = DownloadEngine(store: store, settingsProvider: { testSettings })
        let task = try await store.addTask(DownloadRequest(source: DownloadSource(url: fixture.baseURL.appendingPathComponent("file")), folderPath: directory.path, fileName: "abort.bin", speedLimit: 1))
        try await engine.start(taskID: task.id)
        try await Task.sleep(for: .milliseconds(75))
        await engine.abort(taskID: task.id)
        let before = (await store.snapshot()).history.count
        try await store.removeTask(id: task.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("abort.bin.abpart").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("abort.bin.abpart.hls.json").path))
        let after = (await store.snapshot()).history.count
        XCTAssertEqual(after, before)
    }
}
