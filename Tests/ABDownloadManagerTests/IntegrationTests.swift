import XCTest
import Network
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
}

extension IntegrationTests {
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
        var queues = URLRequest(url: URL(string: "http://127.0.0.1:25151/queues")!); queues.httpMethod = "GET"; queues.setValue("test-key", forHTTPHeaderField: "X-Api-Key")
        let queueResponse = try await session.data(for: queues)
        XCTAssertEqual((queueResponse.1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: queueResponse.0, encoding: .utf8)?.contains("Night") == true)
        var options = URLRequest(url: URL(string: "http://127.0.0.1:25151/add")!); options.httpMethod = "OPTIONS"; options.setValue("test-key", forHTTPHeaderField: "X-Api-Key")
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
