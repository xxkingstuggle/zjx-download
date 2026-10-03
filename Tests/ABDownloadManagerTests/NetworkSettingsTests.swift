import Foundation
import XCTest
@testable import ABDownloadManagerCore

final class NetworkSettingsTests: XCTestCase {
    func testProxySettingsDecodeWithoutPACFields() throws {
        let decoded = try JSONDecoder().decode(ProxySettings.self, from: Data(#"{"mode":"manual","host":"proxy.test","port":8080}"#.utf8))
        XCTAssertEqual(decoded.mode, .manual)
        XCTAssertEqual(decoded.host, "proxy.test")
        XCTAssertEqual(decoded.pacURL, "")
        XCTAssertEqual(decoded.bypassList, "")
    }

    func testEncryptedDNSConfigurationValidatesAndAppliesPerProcess() throws {
        var dns = DNSSettings(mode: .https, httpsURL: "https://dns.example.test/query", bootstrapAddresses: "192.0.2.1, 2001:db8::1")
        XCTAssertNoThrow(try dns.resolverConfiguration())
        XCTAssertNoThrow(try dns.applyToDefaultPrivacyContext())

        dns.mode = .tls
        dns.tlsHost = "dns.example.test"
        XCTAssertNoThrow(try dns.resolverConfiguration())
        XCTAssertNoThrow(try dns.applyToDefaultPrivacyContext())

        dns.mode = .https
        dns.httpsURL = "http://dns.example.test/query"
        XCTAssertThrowsError(try dns.resolverConfiguration())

        dns.mode = .system
        XCTAssertNil(try dns.resolverConfiguration())
        XCTAssertNoThrow(try dns.applyToDefaultPrivacyContext())
    }
}
