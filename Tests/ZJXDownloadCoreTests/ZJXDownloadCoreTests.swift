import CryptoKit
import Darwin
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

    @MainActor
    func testUniqueNameKeepsOriginalFileNameWhenNoConflictExists() throws {
        let folder = tempDirectory.appendingPathComponent("unique-name-test", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertEqual(TaskCoordinator.uniqueName("archive.tar.gz", in: folder, tasks: []), "archive.tar.gz")

        let existingFile = folder.appendingPathComponent("archive.tar.gz")
        try Data("occupied".utf8).write(to: existingFile)
        XCTAssertEqual(TaskCoordinator.uniqueName("archive.tar.gz", in: folder, tasks: []), "archive.tar_1.gz")
    }

    @MainActor
    func testDefaultDownloadDirectoryUsesMacDownloadsAndMigratesLegacySubfolder() throws {
        let settings = AppSettings()
        XCTAssertEqual(settings.defaultDownloadDirectory, AppSettings.macDefaultDownloadsDirectory)
        XCTAssertTrue(AppData().categories.allSatisfy { $0.destinationDirectory == nil })

        let storeDir = tempDirectory.appendingPathComponent("legacy-dir-store", isDirectory: true)
        let store = try StateStore(directory: storeDir)
        var legacyData = AppData()
        legacyData.settings.defaultDownloadDirectory = AppSettings.legacySubdirectoryDefault
        legacyData.categories[0].destinationDirectory = AppSettings.legacySubdirectoryDefault + "/压缩包"
        try store.save(legacyData)

        let loaded = try store.load()
        XCTAssertEqual(loaded.settings.defaultDownloadDirectory, AppSettings.macDefaultDownloadsDirectory)
        XCTAssertNil(loaded.categories[0].destinationDirectory)
    }

    func testNetworkConfigurationWildcardHandlesLeadingTrailingAndMultiStar() {
        XCTAssertTrue(NetworkConfiguration.wildcard("*.example.com", value: "cdn.example.com"))
        XCTAssertTrue(NetworkConfiguration.wildcard("*.example.com", value: "a.b.EXAMPLE.COM"))
        XCTAssertFalse(NetworkConfiguration.wildcard("*.example.com", value: "example.com"))
        XCTAssertTrue(NetworkConfiguration.wildcard("cdn*", value: "cdn-01.example.net"))
        XCTAssertTrue(NetworkConfiguration.wildcard("*alpha*beta*", value: "xx-alpha-mid-beta-yy"))
        XCTAssertFalse(NetworkConfiguration.wildcard("*alpha*beta*", value: "xx-beta-alpha-yy"))
        XCTAssertTrue(NetworkConfiguration.wildcard("exact.host", value: "EXACT.HOST"))
        XCTAssertFalse(NetworkConfiguration.wildcard("", value: "anything"))
    }

    func testNetworkConfigurationProxyDictionariesAndLoopback() {
        var socksSettings = AppSettings()
        socksSettings.proxyMode = .manual
        socksSettings.proxyScheme = .socks5
        socksSettings.proxyHost = "127.0.0.1"
        socksSettings.proxyPort = 1080
        let socksConfig = URLSessionConfiguration.ephemeral
        NetworkConfiguration.applyProxy(settings: socksSettings, proxyPassword: "", to: socksConfig)
        let socksDict = socksConfig.connectionProxyDictionary as? [String: Any]
        XCTAssertEqual(socksDict?[kCFNetworkProxiesSOCKSEnable as String] as? Int, 1)
        XCTAssertEqual(socksDict?[kCFNetworkProxiesSOCKSProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(socksDict?[kCFNetworkProxiesSOCKSPort as String] as? Int, 1080)
        XCTAssertEqual(socksDict?[kCFNetworkProxiesHTTPEnable as String] as? Int, 0)
        XCTAssertEqual(socksDict?[kCFNetworkProxiesHTTPSEnable as String] as? Int, 0)

        var httpSettings = AppSettings()
        httpSettings.proxyMode = .manual
        httpSettings.proxyScheme = .http
        httpSettings.proxyHost = "127.0.0.1"
        httpSettings.proxyPort = 8080
        let httpConfig = URLSessionConfiguration.ephemeral
        NetworkConfiguration.applyProxy(settings: httpSettings, proxyPassword: "", to: httpConfig)
        let httpDict = httpConfig.connectionProxyDictionary as? [String: Any]
        XCTAssertEqual(httpDict?[kCFNetworkProxiesHTTPEnable as String] as? Int, 1)
        XCTAssertEqual(httpDict?[kCFNetworkProxiesHTTPPort as String] as? Int, 8080)
        XCTAssertEqual(httpDict?[kCFNetworkProxiesHTTPSEnable as String] as? Int, 1)
        XCTAssertEqual(httpDict?[kCFNetworkProxiesSOCKSEnable as String] as? Int, 0)

        var directSettings = AppSettings()
        directSettings.proxyMode = .direct
        let directConfig = URLSessionConfiguration.ephemeral
        NetworkConfiguration.applyProxy(settings: directSettings, proxyPassword: "", to: directConfig)
        let directDict = directConfig.connectionProxyDictionary as? [String: Any]
        XCTAssertEqual(directDict?[kCFNetworkProxiesHTTPEnable as String] as? Int, 0)
        XCTAssertEqual(directDict?[kCFNetworkProxiesHTTPSEnable as String] as? Int, 0)
        XCTAssertEqual(directDict?[kCFNetworkProxiesSOCKSEnable as String] as? Int, 0)

        let loopback = NetworkConfiguration.loopbackSessionConfiguration()
        let loopbackDict = loopback.connectionProxyDictionary as? [String: Any]
        XCTAssertEqual(loopbackDict?[kCFNetworkProxiesHTTPEnable as String] as? Int, 0)
        XCTAssertEqual(loopbackDict?[kCFNetworkProxiesHTTPSEnable as String] as? Int, 0)
        XCTAssertEqual(loopbackDict?[kCFNetworkProxiesSOCKSEnable as String] as? Int, 0)
    }

    func testNetworkConfigurationConstantTimeEqual() {
        XCTAssertTrue(NetworkConfiguration.constantTimeEqual(Data("secret-token-123".utf8), Data("secret-token-123".utf8)))
        XCTAssertFalse(NetworkConfiguration.constantTimeEqual(Data("secret-token-123".utf8), Data("secret-token-124".utf8)))
        XCTAssertFalse(NetworkConfiguration.constantTimeEqual(Data("short".utf8), Data("short-extra".utf8)))
        XCTAssertTrue(NetworkConfiguration.constantTimeEqual(Data(), Data()))
        XCTAssertFalse(NetworkConfiguration.constantTimeEqual(Data(), Data("a".utf8)))
    }

    func testChecksumServiceZlibCRC32MatchesStandardVector() throws {
        let file = tempDirectory.appendingPathComponent("crc32-vector.txt")
        try Data("123456789".utf8).write(to: file)
        XCTAssertEqual(try ChecksumService.calculate(file: file, algorithm: "CRC-32"), "cbf43926")
    }

    func testInputImportParsesCurlCookiesAndExchangeDeduplicatesReferer() throws {
        let curl = """
        curl -b 'sid=alpha' --cookie 'theme=dark' -H 'User-Agent: CustomAgent/1.0' -e 'https://ref.example.com/page' 'https://files.example.com/archive.zip'
        """
        let parsed = InputImport.parse(curl)
        XCTAssertTrue(parsed.errors.isEmpty)
        XCTAssertEqual(parsed.items.count, 1)
        let item = try XCTUnwrap(parsed.items.first)
        XCTAssertEqual(item.headers["Cookie"], "sid=alpha; theme=dark")
        XCTAssertEqual(item.userAgent, "CustomAgent/1.0")
        XCTAssertEqual(item.downloadPage?.absoluteString, "https://ref.example.com/page")

        let record = DownloadRecord(
            id: 7,
            kind: .http,
            sourceURL: "https://files.example.com/archive.zip",
            pageURL: "https://ref.example.com/page",
            displayName: "archive.zip",
            destinationDirectory: tempDirectory.path,
            requestHeaders: ["Referer": "https://ref.example.com/page", "Accept": "*/*"]
        )
        let command = ExchangeCodec.curl(for: record)
        let refererOccurrences = command.components(separatedBy: "Referer:").count - 1
        XCTAssertEqual(refererOccurrences, 1)
    }

    func testHLSPlaylistParserStripsBOMAndRejectsLivePlaylist() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://cdn.example.com/video/playlist.m3u8"))
        let vod = """
        \u{FEFF}#EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:10
        #EXTINF:5.5,
        seg10.ts
        #EXTINF:4.5,
        seg11.ts
        #EXT-X-ENDLIST
        """
        let playlist = try HLSService.parse(vod, baseURL: baseURL)
        XCTAssertEqual(playlist.mediaSequence, 10)
        XCTAssertEqual(playlist.segments.map(\.absoluteString), [
            "https://cdn.example.com/video/seg10.ts",
            "https://cdn.example.com/video/seg11.ts"
        ])

        let live = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        live01.ts
        """
        XCTAssertThrowsError(try HLSService.parse(live, baseURL: baseURL))
    }

    @MainActor
    func testQueueSchedulerDeduplicatesSameMinuteAndHandlesCrossMidnightStop() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let scheduler = QueueScheduler()
        var started: [Int64] = []
        var stopped: [Int64] = []
        scheduler.onStartQueue = { started.append($0) }
        scheduler.onStopQueue = { stopped.append($0) }

        let monday2300 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23, minute: 0)))
        let tuesday0200 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 2, minute: 0)))
        let schedule = QueueSchedule(days: [1], startEnabled: true, startHour: 23, startMinute: 0,
                                     stopEnabled: true, stopHour: 2, stopMinute: 0)

        let queues = (1...140).map { index in
            QueueRecord(id: Int64(index), name: "Q\(index)", isRunning: false, schedule: schedule, order: index)
        }
        scheduler.tick(queues: queues, now: monday2300, calendar: calendar)
        scheduler.tick(queues: queues, now: monday2300, calendar: calendar)
        XCTAssertEqual(started.count, 140)

        let runningQueue = QueueRecord(id: 1, name: "Night", isRunning: true, schedule: schedule, order: 0)
        scheduler.tick(queues: [runningQueue], now: tuesday0200, calendar: calendar)
        XCTAssertEqual(stopped, [1])

        let next = scheduler.nextEvent(for: runningQueue, after: monday2300, calendar: calendar)
        XCTAssertEqual(next?.kind, "停止")
        XCTAssertEqual(next?.date, tuesday0200)
    }

    @MainActor
    func testStateStoreReadOnlyRecoveryBlocksResumeDataMutation() throws {
        let storeDir = tempDirectory.appendingPathComponent("ro-resume-store", isDirectory: true)
        let writable = try StateStore(directory: storeDir)
        let savedName = try writable.saveResumeData(Data("resume-bytes".utf8), taskID: 42)
        let savedFile = writable.resumeDataURL(for: savedName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedFile.path))

        let readOnly = StateStore.readOnlyRecovery(directory: storeDir)
        XCTAssertThrowsError(try readOnly.saveResumeData(Data("overwrite".utf8), taskID: 42))
        readOnly.removeResumeData(named: savedName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedFile.path))
    }

    @MainActor
    func testTransferLiveStateAndCoordinatorCleanupPreventEntryLeak() throws {
        let live = TransferLiveState()
        live.update(taskID: 1, received: 500, total: 1000, metric: TransferMetric(bytesPerSecond: 100, averageBytesPerSecond: 80))
        live.update(taskID: 2, received: 250, total: 1000, metric: TransferMetric(bytesPerSecond: 200, averageBytesPerSecond: 150))
        XCTAssertEqual(live.totalActiveSpeed, 300)

        live.clear(taskID: 1)
        XCTAssertNil(live.receivedBytes[1])
        XCTAssertNil(live.totalBytes[1])
        XCTAssertNil(live.metrics[1])
        XCTAssertEqual(live.totalActiveSpeed, 200)

        live.prune(keeping: [])
        XCTAssertTrue(live.receivedBytes.isEmpty)
        XCTAssertTrue(live.totalBytes.isEmpty)
        XCTAssertTrue(live.metrics.isEmpty)
        XCTAssertEqual(live.totalActiveSpeed, 0)

        let storeDir = tempDirectory.appendingPathComponent("live-cleanup-store", isDirectory: true)
        do {
            let seedStore = try StateStore(directory: storeDir)
            var seed = AppData()
            seed.settings.defaultDownloadDirectory = tempDirectory.path
            seed.tasks = [
                DownloadRecord(id: 10, kind: .http, sourceURL: "http://127.0.0.1:9/done.bin",
                               displayName: "done.bin", destinationDirectory: tempDirectory.path, status: .completed),
                DownloadRecord(id: 11, kind: .http, sourceURL: "http://127.0.0.1:9/paused.bin",
                               displayName: "paused.bin", destinationDirectory: tempDirectory.path, status: .paused)
            ]
            seed.nextTaskID = 12
            try seedStore.save(seed)
        }
        let coordinator = TaskCoordinator(directory: storeDir, credentialService: "com.zjx.download.test.\(UUID().uuidString)")
        coordinator.liveState.update(taskID: 10, received: 10, total: 10, metric: TransferMetric(bytesPerSecond: 10))
        coordinator.liveState.update(taskID: 11, received: 5, total: 10, metric: TransferMetric(bytesPerSecond: 5))

        XCTAssertTrue(coordinator.clearCompletedTasks().isEmpty)
        XCTAssertNil(coordinator.liveState.metrics[10])
        XCTAssertNotNil(coordinator.liveState.metrics[11])

        XCTAssertTrue(coordinator.remove([11], removeCompletedFiles: false).isEmpty)
        XCTAssertTrue(coordinator.liveState.metrics.isEmpty)
    }

    @MainActor
    func testDownloadEngineProbeFallsBackFromHead403AndParsesRFC5987Filename() async throws {
        let stub = try LocalHTTPStubServer { requestLine in
            if requestLine.hasPrefix("HEAD ") {
                if requestLine.contains("/partial") {
                    return "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                }
                return "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            if requestLine.contains("/partial") {
                return "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/1024\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx"
            }
            let body = String(repeating: "x", count: 42)
            return "HTTP/1.1 200 OK\r\nContent-Length: 42\r\nAccept-Ranges: bytes\r\nContent-Disposition: attachment; filename*=UTF-8''%E6%B5%8B%E8%AF%95%20%E6%96%87%E4%BB%B6.zip\r\nConnection: close\r\n\r\n\(body)"
        }
        defer { stub.stop() }
        let port = try await stub.waitUntilReady()
        let engine = DownloadEngine()
        var settings = AppSettings()
        settings.proxyMode = .direct
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/download"))
        let info = try await engine.probe(url, headers: [:], userAgent: "zjx-test", settings: settings)
        XCTAssertEqual(info.suggestedName, "测试 文件.zip")
        XCTAssertEqual(info.contentLength, 42)
        XCTAssertTrue(info.supportsRanges)

        let partialURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/partial"))
        let partialInfo = try await engine.probe(partialURL, headers: [:], userAgent: "zjx-test", settings: settings)
        XCTAssertEqual(partialInfo.contentLength, 1024)
        XCTAssertTrue(partialInfo.supportsRanges)
    }

    @MainActor
    func testIntegrationServerHotReloadAuthAndStatusTasksEndpoints() async throws {
        let storeDir = tempDirectory.appendingPathComponent("integration-store", isDirectory: true)
        let serviceName = "com.zjx.download.test.\(UUID().uuidString)"
        let coordinator = TaskCoordinator(directory: storeDir, credentialService: serviceName)
        let server = IntegrationServer(coordinator: coordinator)
        let port = try allocateLoopbackPort()
        let apiKey = "zjx-test-key-\(UUID().uuidString)"
        let keyAccount = coordinator.data.settings.apiKeyAccount
        defer {
            server.stop()
            do { try coordinator.credentials.write(nil, account: keyAccount) } catch {}
        }

        var settings = coordinator.data.settings
        settings.apiEnabled = true
        settings.apiPort = port
        settings.apiRequiresKey = false
        server.restart(settings: settings)

        var readyPort: UInt16?
        for _ in 0..<60 {
            if let bound = server.listeningPort { readyPort = bound; break }
            if let error = server.lastError { XCTFail("IntegrationServer failed to bind: \(error)"); break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(readyPort, UInt16(port))
        let initialGeneration = server.activeListenerGeneration
        XCTAssertGreaterThan(initialGeneration, 0)
        let socketBefore = try listeningSocketIdentity(port: port)

        let session = URLSession(configuration: NetworkConfiguration.loopbackSessionConfiguration())
        var pingReq = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/ping")))
        pingReq.httpMethod = "POST"
        let (pingData, pingResp) = try await session.data(for: pingReq)
        XCTAssertEqual((pingResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: pingData, encoding: .utf8), "pong")

        let (statusData, statusResp) = try await session.data(from: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/status")))
        XCTAssertEqual((statusResp as? HTTPURLResponse)?.statusCode, 200)
        let statusJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: statusData) as? [String: Any])
        XCTAssertEqual(statusJSON["ok"] as? Bool, true)
        XCTAssertEqual(statusJSON["listeningPort"] as? Int, port)

        let (tasksData, tasksResp) = try await session.data(from: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/tasks")))
        XCTAssertEqual((tasksResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: tasksData) as? [[String: Any]])

        // Hot-reload auth without rebuilding NWListener
        try coordinator.credentials.write(apiKey, account: keyAccount)
        settings.apiRequiresKey = true
        server.restart(settings: settings)
        XCTAssertEqual(server.activeListenerGeneration, initialGeneration)
        XCTAssertEqual(server.listeningPort, UInt16(port))
        XCTAssertEqual(try listeningSocketIdentity(port: port), socketBefore)

        let (_, unauthResp) = try await session.data(for: pingReq)
        XCTAssertEqual((unauthResp as? HTTPURLResponse)?.statusCode, 401)

        var authedReq = pingReq
        authedReq.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let (authedData, authedResp) = try await session.data(for: authedReq)
        XCTAssertEqual((authedResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: authedData, encoding: .utf8), "pong")

        let rotatedKey = "zjx-rotated-\(UUID().uuidString)"
        try coordinator.credentials.write(rotatedKey, account: keyAccount)
        server.restart(settings: settings)
        XCTAssertEqual(server.activeListenerGeneration, initialGeneration)
        XCTAssertEqual(try listeningSocketIdentity(port: port), socketBefore)

        let (_, staleResp) = try await session.data(for: authedReq)
        XCTAssertEqual((staleResp as? HTTPURLResponse)?.statusCode, 401)

        var rotatedReq = pingReq
        rotatedReq.setValue(rotatedKey, forHTTPHeaderField: "X-API-Key")
        let (rotatedData, rotatedResp) = try await session.data(for: rotatedReq)
        XCTAssertEqual((rotatedResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: rotatedData, encoding: .utf8), "pong")
    }

    private func listeningSocketIdentity(port: Int) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", String(ProcessInfo.processInfo.processIdentifier), "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else {
            throw NSError(domain: "ZJXDownloadCoreTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing LISTEN socket for port \(port): \(output)"])
        }
        let columns = lines[1].split(whereSeparator: \.isWhitespace).map(String.init)
        guard columns.count >= 9 else {
            throw NSError(domain: "ZJXDownloadCoreTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unexpected lsof line: \(lines[1])"])
        }
        return "\(columns[3])|\(columns[5])|\(columns[8])"
    }

    private func allocateLoopbackPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var boundAddress = address
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, length) }
        }
        guard bindResult == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(descriptor, $0, &length) }
        }
        guard nameResult == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }
}

private final class LocalHTTPStubServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.zjx.download.test.stub")
    private let lock = NSLock()
    private let handler: @Sendable (String) -> String
    private var readyPort: UInt16?

    init(handler: @escaping @Sendable (String) -> String) throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.lock.lock()
            self.readyPort = self.listener.port?.rawValue
            self.lock.unlock()
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let firstLine = text.components(separatedBy: "\r\n").first ?? ""
                let response = self.handler(firstLine)
                connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
    }

    func waitUntilReady() async throws -> UInt16 {
        for _ in 0..<60 {
            if let port = currentPort() { return port }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "LocalHTTPStubServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stub server did not become ready."])
    }

    private func currentPort() -> UInt16? {
        lock.withLock { readyPort }
    }

    func stop() {
        listener.cancel()
    }
}
