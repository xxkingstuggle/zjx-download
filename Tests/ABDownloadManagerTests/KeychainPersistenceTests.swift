import CryptoKit
import Foundation
import XCTest
@testable import ABDownloadManagerCore

final class KeychainPersistenceTests: XCTestCase {
    func testLegacySecretsMoveToKeychainAndStateFileIsScrubbed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMKeychainMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = AppSettings()
        settings.integration.apiKey = "legacy-api-secret"
        settings.proxy.password = "legacy-proxy-secret"
        let task = DownloadTask(
            id: 1,
            source: DownloadSource(
                url: URL(string: "https://example.test/private.bin")!,
                headers: ["Authorization": "Bearer legacy-header-secret", "Cookie": "session=legacy-cookie"]
            ),
            folderPath: root.path,
            fileName: "private.bin"
        )
        let legacy = PersistedAppState(tasks: [task], settings: settings, nextTaskID: 2)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: root.appendingPathComponent("state.json"))

        let prefix = credentialPrefix(for: root)
        defer { removeCredentials(prefix: prefix, taskIDs: [1]) }

        let store = try AppStateStore(directory: root)
        let recovered = await store.snapshot()
        XCTAssertEqual(recovered.settings.integration.apiKey, "legacy-api-secret")
        XCTAssertEqual(recovered.settings.proxy.password, "legacy-proxy-secret")
        XCTAssertNil(recovered.tasks.first?.source.headers["Authorization"], "list snapshots must not hydrate task secrets")
        XCTAssertNil(recovered.tasks.first?.source.headers["Cookie"], "list snapshots must not hydrate task secrets")
        let hydrated = try await store.taskForExecution(id: task.id)
        XCTAssertEqual(hydrated?.source.headers["Authorization"], "Bearer legacy-header-secret")
        XCTAssertEqual(hydrated?.source.headers["Cookie"], "session=legacy-cookie")

        let onDisk = try String(contentsOf: root.appendingPathComponent("state.json"), encoding: .utf8)
        for secret in ["legacy-api-secret", "legacy-proxy-secret", "legacy-header-secret", "legacy-cookie"] {
            XCTAssertFalse(onDisk.contains(secret), "secret was left in state.json: \(secret)")
        }
        let reopened = try AppStateStore(directory: root)
        let reloaded = await reopened.snapshot()
        XCTAssertEqual(reloaded.settings.integration.apiKey, "legacy-api-secret")
        XCTAssertEqual(reloaded.settings.proxy.password, "legacy-proxy-secret")
        XCTAssertNil(reloaded.tasks.first?.source.headers["Authorization"])
        let reopenedTask = try await reopened.taskForExecution(id: task.id)
        XCTAssertEqual(reopenedTask?.source.headers["Authorization"], "Bearer legacy-header-secret")
    }

    func testHostCredentialsPersistAndAreAppliedToNewTasks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMHostCredential-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = credentialPrefix(for: root)
        defer { removeCredentials(prefix: prefix, taskIDs: [1]) }

        let store = try AppStateStore(directory: root)
        try await store.upsertHostOverride(HostOverride(
            host: "example.test",
            userAgent: "NativeClient/1.0",
            authUsername: "alice",
            authPassword: "host-secret"
        ))
        let reloaded = try AppStateStore(directory: root)
        let override = await reloaded.matchingHostOverride(for: URL(string: "https://example.test/file.zip")!)
        XCTAssertEqual(override?.authPassword, "host-secret")
        let task = try await reloaded.addTask(DownloadRequest(source: DownloadSource(url: URL(string: "https://example.test/file.zip")!)))
        XCTAssertEqual(task.source.headers["User-Agent"], "NativeClient/1.0")
        XCTAssertNil(task.source.headers["Authorization"], "new task results expose only public headers")
        let hydratedTask = try await reloaded.taskForExecution(id: task.id)
        XCTAssertEqual(hydratedTask?.source.headers["Authorization"], "Basic YWxpY2U6aG9zdC1zZWNyZXQ=")

        let onDisk = try String(contentsOf: root.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(onDisk.contains("host-secret"))
    }

    private func credentialPrefix(for root: URL) -> String {
        SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(24)
            .description
    }

    private func removeCredentials(prefix: String, taskIDs: [Int64]) {
        let store = KeychainCredentialStore()
        try? store.remove(account: "\(prefix).integration.apiKey")
        try? store.remove(account: "\(prefix).proxy.password")
        try? store.remove(account: "\(prefix).host.example.test.password")
        for id in taskIDs { try? store.remove(account: "\(prefix).task.\(id).headers") }
    }
}
