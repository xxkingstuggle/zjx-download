import CryptoKit
import Foundation
import Network
import XCTest
@testable import ZJXDownloadCore

final class ZJXDownloadCoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zjx-download-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try? FileManager.default.trashItem(at: tempDirectory, resultingItemURL: nil)
        }
    }

    func testChecksumServiceComputesDigests() throws {
        let file = tempDirectory.appendingPathComponent("payload.bin")
        let payload = Data("zjx-download-verification-payload".utf8)
        try payload.write(to: file)

        let expectedSHA256 = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try ChecksumService.calculate(file: file, algorithm: "SHA-256"), expectedSHA256)
        XCTAssertEqual(try ChecksumService.calculate(file: file, algorithm: "CRC-32").count, 8)
    }

    @MainActor
    func testStateStorePersistenceAndReadOnlyRecovery() throws {
        let storeDir = tempDirectory.appendingPathComponent("store", isDirectory: true)
        let store = try StateStore(directory: storeDir)
        var data = try store.load()
        XCTAssertEqual(data.schemaVersion, 2)
        XCTAssertEqual(data.queues.first?.name, "Main")

        let record = DownloadRecord(
            id: 1,
            kind: .http,
            sourceURL: "https://example.com/archive.zip",
            displayName: "archive.zip",
            destinationDirectory: tempDirectory.path,
            status: .paused,
            totalBytes: 1024,
            receivedBytes: 512
        )
        data.tasks = [record]
        data.nextTaskID = 2
        try store.save(data)

        let recovery = StateStore.readOnlyRecovery(directory: storeDir)
        let loaded = try recovery.load()
        XCTAssertEqual(loaded.tasks.count, 1)
        XCTAssertEqual(loaded.tasks.first?.displayName, "archive.zip")
        XCTAssertThrowsError(try recovery.save(loaded))
    }

    @MainActor
    func testQueueSchedulerFiresStartAndStopEvents() {
        var started: [Int64] = []
        var stopped: [Int64] = []
        let scheduler = QueueScheduler()
        scheduler.onStartQueue = { started.append($0) }
        scheduler.onStopQueue = { stopped.append($0) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let startDate = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9, minute: 30))!
        let stopDate = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 10, minute: 0))!

        let schedule = QueueSchedule(
            days: [1],
            startEnabled: true,
            startHour: 9,
            startMinute: 30,
            stopEnabled: true,
            stopHour: 10,
            stopMinute: 0,
            stopWhenEmpty: true
        )
        var queue = QueueRecord(id: 0, name: "Main", concurrency: 2, isRunning: false, schedule: schedule, order: 0)
        scheduler.tick(queues: [queue], now: startDate, calendar: calendar)
        XCTAssertEqual(started, [0])

        queue.isRunning = true
        scheduler.tick(queues: [queue], now: stopDate, calendar: calendar)
        XCTAssertEqual(stopped, [0])
    }

    func testNetworkConfigurationStripsCrossOriginCredentials() throws {
        let originA = try XCTUnwrap(URL(string: "https://cdn.example.com/file.bin"))
        let originB = try XCTUnwrap(URL(string: "https://mirror.example.org/file.bin"))
        let headers = [
            "Authorization": "Bearer secret-token",
            "Cookie": "sid=123",
            "User-Agent": "zjx-test"
        ]
        let stripped = NetworkConfiguration.removingSensitiveHeaders(headers, from: originA, to: originB)
        XCTAssertNil(stripped["Authorization"])
        XCTAssertNil(stripped["Cookie"])
        XCTAssertEqual(stripped["User-Agent"], "zjx-test")
    }

    func testExchangeCodecAndCurlImportRoundTrip() throws {
        let record = DownloadRecord(
            id: 7,
            kind: .http,
            sourceURL: "https://example.com/pkg.dmg",
            pageURL: "https://example.com/releases",
            displayName: "pkg.dmg",
            destinationDirectory: tempDirectory.path,
            status: .queued,
            requestHeaders: ["X-Custom": "value-1"]
        )
        let curl = ExchangeCodec.curl(for: record)
        let imported = InputImport.parse(curl)
        XCTAssertEqual(imported.items.count, 1)
        XCTAssertEqual(imported.items.first?.url.absoluteString, "https://example.com/pkg.dmg")
        XCTAssertEqual(imported.items.first?.headers["X-Custom"], "value-1")
    }

    @MainActor
    func testManualConcurrencyLimitAndQueuedPause() throws {
        let storeDir = tempDirectory.appendingPathComponent("coordinator-store", isDirectory: true)
        do {
            let seedStore = try StateStore(directory: storeDir)
            var seedData = AppData()
            seedData.settings.maxManualDownloads = 1
            seedData.settings.defaultDownloadDirectory = tempDirectory.path
            seedData.tasks = [
                DownloadRecord(
                    id: 1,
                    kind: .http,
                    sourceURL: "http://127.0.0.1:9/task1.bin",
                    displayName: "task1.bin",
                    destinationDirectory: tempDirectory.path,
                    status: .paused,
                    queueID: 0
                ),
                DownloadRecord(
                    id: 2,
                    kind: .http,
                    sourceURL: "http://127.0.0.1:9/task2.bin",
                    displayName: "task2.bin",
                    destinationDirectory: tempDirectory.path,
                    status: .paused,
                    queueID: 0
                )
            ]
            seedData.queues[0].taskIDs = [1, 2]
            seedData.nextTaskID = 3
            try seedStore.save(seedData)
        }
        let coordinator = TaskCoordinator(
            directory: storeDir,
            credentialService: "com.zjx.download.test.\(UUID().uuidString)"
        )
        XCTAssertNil(coordinator.startupError)

        coordinator.start([1, 2])
        let task1 = try XCTUnwrap(coordinator.task(1))
        let task2 = try XCTUnwrap(coordinator.task(2))
        XCTAssertTrue(task1.status.isActive)
        XCTAssertNil(task1.queueID)
        XCTAssertEqual(task2.status, .queued)
        XCTAssertNil(task2.queueID)

        coordinator.pause([2])
        XCTAssertEqual(coordinator.task(2)?.status, .paused)
        coordinator.stopAll()
        XCTAssertEqual(coordinator.task(1)?.status, .paused)
    }

    @MainActor
    func testProgressBaselineResetsToVerifiedCheckpointOnNewGeneration() throws {
        let storeDir = tempDirectory.appendingPathComponent("progress-store", isDirectory: true)
        do {
            let seedStore = try StateStore(directory: storeDir)
            var seedData = AppData()
            seedData.settings.defaultDownloadDirectory = tempDirectory.path
            seedData.tasks = [
                DownloadRecord(
                    id: 1,
                    kind: .http,
                    sourceURL: "http://127.0.0.1:9/part.bin",
                    displayName: "part.bin",
                    destinationDirectory: tempDirectory.path,
                    status: .paused,
                    totalBytes: 100_000,
                    receivedBytes: 50_000,
                    etag: "\"v1\"",
                    supportsRanges: true
                )
            ]
            seedData.nextTaskID = 2
            try seedStore.save(seedData)
        }
        let coordinator = TaskCoordinator(
            directory: storeDir,
            credentialService: "com.zjx.download.test.\(UUID().uuidString)"
        )
        coordinator.start([1])
        coordinator.segmentedEngine.onProgress?(1, 1, 32_768, 100_000)
        XCTAssertEqual(coordinator.task(1)?.receivedBytes, 32_768)
        coordinator.stopAll()
    }

    @MainActor
    func testCancelRemovesCrossSessionSegmentedCheckpoint() async throws {
        let storeDir = tempDirectory.appendingPathComponent("cross-session-cancel", isDirectory: true)
        let segmentDir = storeDir
            .appendingPathComponent("range-parts-1", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)
        try Data("5".utf8).write(to: segmentDir.appendingPathComponent("active-generation"))
        try Data("partial".utf8).write(to: segmentDir.appendingPathComponent("segment-0000.part"))

        let service = SegmentedDownloadService(baseDirectory: storeDir)
        service.cancel(taskID: 1, generation: 0, deletePartial: true)
        for _ in 0..<50 where FileManager.default.fileExists(atPath: segmentDir.path) {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: segmentDir.path))
    }

    @MainActor
    func testRecoverInterruptedTasksReconcilesCommittedSegmentsAndUnpersistedSingleConnection() throws {
        let storeDir = tempDirectory.appendingPathComponent("recover-interrupted-store", isDirectory: true)
        let segmentDir = storeDir
            .appendingPathComponent("range-parts-1", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)
        let manifestJSON = """
        {
          "sourceURL": "http://127.0.0.1:9/segmented.bin",
          "etag": "\\"etag-1\\"",
          "total": 2048,
          "ranges": [
            { "index": 0, "lower": 0, "upper": 1023 },
            { "index": 1, "lower": 1024, "upper": 2047 }
          ]
        }
        """
        try Data(manifestJSON.utf8).write(to: segmentDir.appendingPathComponent("manifest.json"))
        try Data(repeating: 0x41, count: 1024).write(to: segmentDir.appendingPathComponent("segment-0000.part"))

        do {
            let seedStore = try StateStore(directory: storeDir)
            var seedData = AppData()
            seedData.settings.defaultDownloadDirectory = tempDirectory.path
            seedData.tasks = [
                DownloadRecord(
                    id: 1,
                    kind: .http,
                    sourceURL: "http://127.0.0.1:9/segmented.bin",
                    displayName: "segmented.bin",
                    destinationDirectory: tempDirectory.path,
                    status: .downloading,
                    totalBytes: 2048,
                    receivedBytes: 1700,
                    etag: "\"etag-1\"",
                    supportsRanges: true
                ),
                DownloadRecord(
                    id: 2,
                    kind: .http,
                    sourceURL: "http://127.0.0.1:9/single.bin",
                    displayName: "single.bin",
                    destinationDirectory: tempDirectory.path,
                    status: .downloading,
                    totalBytes: 2048,
                    receivedBytes: 900,
                    supportsRanges: false
                )
            ]
            seedData.nextTaskID = 3
            try seedStore.save(seedData)
        }

        let coordinator = TaskCoordinator(
            directory: storeDir,
            credentialService: "com.zjx.download.test.\(UUID().uuidString)"
        )
        let recoveredSegmented = try XCTUnwrap(coordinator.task(1))
        XCTAssertEqual(recoveredSegmented.status, .paused)
        XCTAssertEqual(recoveredSegmented.receivedBytes, 1024)

        let recoveredSingle = try XCTUnwrap(coordinator.task(2))
        XCTAssertEqual(recoveredSingle.status, .paused)
        XCTAssertEqual(recoveredSingle.receivedBytes, 0)
    }
}
