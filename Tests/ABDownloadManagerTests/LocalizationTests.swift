import XCTest
@testable import ABDownloadManagerCore

/// Guards the localization tables against the two failure modes that reached
/// the running UI: a key referenced by a view but absent from a table (which
/// renders the raw key, e.g. `toolbar.inspector` instead of "检查器"), and a
/// key present in one language but missing from another.
///
/// The tables are read from the source tree rather than a bundle so every
/// locale offered by Settings stays complete in both SwiftPM and Xcode builds.
final class LocalizationTests: XCTestCase {
    private static let languages = SupportedAppLanguage.all.map(\.code)

    private var packageRoot: URL {
        // .../Tests/ABDownloadManagerTests/<this file> -> package root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var appSourceRoot: URL {
        packageRoot.appendingPathComponent("Sources/ABDownloadManagerApp")
    }

    private func table(for language: String) throws -> [String: String] {
        let url = appSourceRoot.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        let contents = try String(contentsOf: url, encoding: .utf8)
        var entries: [String: String] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let separator = trimmed.range(of: "\" = \"") else { continue }
            let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<separator.lowerBound])
            entries[key] = trimmed
        }
        return entries
    }

    /// Every explicit localized key used by SwiftUI, AppLocalization, or a
    /// table column definition must exist in all shipped language tables.
    private func referencedKeys() throws -> Set<String> {
        let enumerator = FileManager.default.enumerator(at: appSourceRoot, includingPropertiesForKeys: nil)
        var keys: Set<String> = []
        let patterns = [
            #"LocalizedStringKey\("([^"\\]+)"\)"#,
            #"AppLocalization\.(?:string|format)\("([^"\\]+)""#,
            #"titleKey:\s*"([^"\\]+)""#,
        ]
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for pattern in patterns {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(source.startIndex..., in: source)
                for match in regex.matches(in: source, range: range) {
                    guard let captured = Range(match.range(at: 1), in: source) else { continue }
                    keys.insert(String(source[captured]))
                }
            }
        }
        return keys
    }

    func testEveryReferencedKeyExistsInEveryLanguage() throws {
        let keys = try referencedKeys()
        XCTAssertFalse(keys.isEmpty, "no localization keys were discovered — the scanner is broken")
        for language in Self.languages {
            let entries = try table(for: language)
            let missing = keys.subtracting(entries.keys).sorted()
            XCTAssertTrue(
                missing.isEmpty,
                "\(language).lproj/Localizable.strings is missing keys referenced by the UI: \(missing)"
            )
        }
    }

    /// Chinese and English have fully translated macOS UI strings; inherited
    /// translation rows may exist in Chinese without an English counterpart.
    func testEnglishTableIsCoveredByChinese() throws {
        let english = Set(try table(for: "en").keys)
        let chinese = Set(try table(for: "zh-Hans").keys)
        XCTAssertEqual(
            english.subtracting(chinese).sorted(), [],
            "keys present in en but missing from zh-Hans"
        )
    }

    /// A duplicated key silently shadows to whichever line wins, so a stale
    /// entry can survive an edit unnoticed.
    func testTablesHaveNoDuplicateKeys() throws {
        for language in Self.languages {
            let url = appSourceRoot.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
            let contents = try String(contentsOf: url, encoding: .utf8)
            var seen: Set<String> = []
            var duplicates: Set<String> = []
            for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("\""), let separator = trimmed.range(of: "\" = \"") else { continue }
                let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<separator.lowerBound])
                if !seen.insert(key).inserted { duplicates.insert(key) }
            }
            XCTAssertEqual(duplicates.sorted(), [], "\(language) table has duplicate keys")
        }
    }

    /// Every offered locale should include the inherited catalog and the
    /// app's macOS-only fallback strings.
    func testTablesAreNotEmpty() throws {
        for language in Self.languages {
            XCTAssertGreaterThan(try table(for: language).count, 100, "\(language) table looks truncated")
        }
    }

    func testSupportedLanguageMappingMatchesEveryBundledLocale() throws {
        let root = appSourceRoot.appendingPathComponent("Resources")
        let bundled = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
        XCTAssertEqual(SupportedAppLanguage.all.map(\.code).sorted(), bundled)
        XCTAssertEqual(Set(SupportedAppLanguage.all.map(\.code)).count, SupportedAppLanguage.all.count)
    }
}
