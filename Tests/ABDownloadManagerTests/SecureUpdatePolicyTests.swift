import CryptoKit
import Foundation
import XCTest
@testable import ABDownloadManagerCore

final class SecureUpdatePolicyTests: XCTestCase {
    private let updateURL = URL(string: "https://updates.example.test/stable/manifest.json")!
    private let artifactURL = URL(string: "https://cdn.example.test/zjx-download-2.0.0.zip")!

    func testManifestValidationRequiresHTTPSVersionAndSHA256() throws {
        let policy = SecureUpdatePolicy(channel: .stable)
        let valid = UpdateManifest(version: "2.0.0", downloadURL: artifactURL, sha256: String(repeating: "a", count: 64), signingTeamID: "ABCDE12345")
        XCTAssertNoThrow(try policy.validate(valid))
        XCTAssertThrowsError(try policy.validate(UpdateManifest(version: "../escape", downloadURL: artifactURL, sha256: valid.sha256)))
        XCTAssertThrowsError(try policy.validate(UpdateManifest(version: "2.0.0", downloadURL: URL(string: "http://cdn.example.test/app.zip")!, sha256: valid.sha256)))
        XCTAssertThrowsError(try policy.validate(UpdateManifest(version: "2.0.0", downloadURL: artifactURL, sha256: "not-a-hash")))
        XCTAssertThrowsError(try policy.validate(UpdateManifest(version: "2.0.0", downloadURL: artifactURL, sha256: valid.sha256, signingTeamID: "BAD")))
        XCTAssertThrowsError(try SecureUpdatePolicy(channel: .disabled).validate(valid)) { error in
            XCTAssertEqual(error as? SecureUpdatePolicy.UpdateError, .updatesDisabled)
        }
        XCTAssertThrowsError(try policy.validate(UpdateManifest(version: "2.0.0", downloadURL: URL(string: "https://user:pass@cdn.example.test/app.zip")!, sha256: valid.sha256)))
    }

    func testFetchManifestChecksHTTPSResponseAndDecodesPublisherManifest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateManifestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let policy = SecureUpdatePolicy(channel: .stable)

        let manifest = try await policy.fetchManifest(
            from: URL(string: "https://updates.example.test/valid.json")!,
            session: session
        )
        XCTAssertEqual(manifest.version, "2.1.0")
        XCTAssertEqual(manifest.downloadURL, URL(string: "https://cdn.example.test/zjx-download.zip"))
        XCTAssertEqual(manifest.sha256, String(repeating: "a", count: 64))

        do {
            _ = try await policy.fetchManifest(from: URL(string: "https://updates.example.test/missing.json")!, session: session)
            XCTFail("A non-success HTTP response was accepted")
        } catch {
            XCTAssertEqual(error as? SecureUpdatePolicy.UpdateError, .badResponse)
        }

        do {
            _ = try await policy.fetchManifest(from: URL(string: "http://updates.example.test/valid.json")!, session: session)
            XCTFail("An insecure manifest URL was accepted")
        } catch {
            XCTAssertEqual(error as? SecureUpdatePolicy.UpdateError, .insecureURL)
        }
    }

    func testDownloadVerifiesChecksumAndPreservesExistingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMUpdateTest-\(UUID().uuidString)")
        let downloads = root.appendingPathComponent("updates", isDirectory: true)
        let transport = root.appendingPathComponent("transport.zip")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let payload = Data("verified update archive".utf8)
        try payload.write(to: transport)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let policy = SecureUpdatePolicy(channel: .stable)
        let manifest = UpdateManifest(version: "2.0.0", downloadURL: artifactURL, sha256: digest)
        let response = HTTPURLResponse(url: artifactURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let expectedURL = artifactURL

        let first = try await policy.downloadAndVerify(manifest, to: downloads) { url in
            guard url == expectedURL else { throw SecureUpdatePolicy.UpdateError.badResponse }
            return (transport, response)
        }
        XCTAssertEqual(try Data(contentsOf: first), payload)
        XCTAssertEqual(first.lastPathComponent, "zjx-download-2.0.0.zip")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transport.path))

        try payload.write(to: transport)
        let second = try await policy.downloadAndVerify(manifest, to: downloads) { _ in
            (transport, response)
        }
        XCTAssertEqual(second.lastPathComponent, "zjx-download-2.0.0-2.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testDownloadRejectsWrongChecksumAndOversizedArtifact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMUpdateFailure-\(UUID().uuidString)")
        let transport = root.appendingPathComponent("transport.zip")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data("bad update".utf8)
        try payload.write(to: transport)
        let response = HTTPURLResponse(url: artifactURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let invalidDigest = UpdateManifest(version: "2.0.0", downloadURL: artifactURL, sha256: String(repeating: "0", count: 64))
        do {
            _ = try await SecureUpdatePolicy(channel: .stable).downloadAndVerify(invalidDigest, to: root) { _ in (transport, response) }
            XCTFail("download with a mismatched digest was accepted")
        } catch { XCTAssertEqual(error as? SecureUpdatePolicy.UpdateError, .checksumMismatch) }

        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let validManifest = UpdateManifest(version: "2.0.0", downloadURL: artifactURL, sha256: digest)
        do {
            _ = try await SecureUpdatePolicy(channel: .stable, maximumArtifactBytes: 1).downloadAndVerify(validManifest, to: root) { _ in (transport, response) }
            XCTFail("oversized artifact was accepted")
        } catch { XCTAssertEqual(error as? SecureUpdatePolicy.UpdateError, .artifactTooLarge) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("zjx-download-2.0.0.zip").path))
    }

    func testDownloadRejectsNonHTTPSRedirectResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ABDMUpdateRedirect-\(UUID().uuidString)")
        let transport = root.appendingPathComponent("transport.zip")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data("archive".utf8)
        try payload.write(to: transport)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let manifest = UpdateManifest(version: "2.0.0", downloadURL: artifactURL, sha256: digest)
        let response = HTTPURLResponse(url: URL(string: "http://insecure.example.test/app.zip")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        do {
            _ = try await SecureUpdatePolicy(channel: .stable).downloadAndVerify(manifest, to: root) { _ in (transport, response) }
            XCTFail("non-HTTPS final URL was accepted")
        } catch { XCTAssertEqual(error as? SecureUpdatePolicy.UpdateError, .badResponse) }
    }
}

private final class UpdateManifestURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "updates.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let expectedUserAgent = request.value(forHTTPHeaderField: "User-Agent") == "zjx-download-macOS"
        let status = url.path == "/missing.json" ? 404 : expectedUserAgent ? 200 : 403
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 200 {
            let object: [String: String] = [
                "version": "2.1.0",
                "downloadURL": "https://cdn.example.test/zjx-download.zip",
                "sha256": String(repeating: "a", count: 64)
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
