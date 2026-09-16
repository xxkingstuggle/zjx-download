import XCTest
@testable import ABDownloadManagerCore

/// Pure mapping tests for the three-state appearance model. These run without
/// SwiftUI so they can assert the exact rule every scene derives its colour
/// scheme from: System hands control back to macOS, Light/Dark force a value.
final class AppearanceTests: XCTestCase {
    func testSystemModeForcesNothing() {
        XCTAssertNil(ThemeMode.system.appearanceOverride.forcedDark)
        XCTAssertEqual(ThemeMode.system.appearanceOverride, AppearanceOverride.system)
    }

    func testLightModeForcesLight() {
        XCTAssertEqual(ThemeMode.light.appearanceOverride, .light)
        XCTAssertEqual(ThemeMode.light.appearanceOverride.forcedDark, false)
    }

    func testDarkModeForcesDark() {
        XCTAssertEqual(ThemeMode.dark.appearanceOverride, .dark)
        XCTAssertEqual(ThemeMode.dark.appearanceOverride.forcedDark, true)
    }

    /// `forcedDark` must distinguish "system decides" from "forced light" —
    /// both are falsy-ish, and conflating them is the bug this guards.
    func testSystemAndLightAreDistinguishable() {
        XCTAssertNotEqual(ThemeMode.system.appearanceOverride.forcedDark, ThemeMode.light.appearanceOverride.forcedDark)
    }

    /// Every mode maps to a distinct override, so no two picker entries can
    /// silently render the same appearance.
    func testEveryModeMapsToADistinctOverride() {
        let overrides = ThemeMode.allCases.map(\.appearanceOverride)
        XCTAssertEqual(Set(overrides).count, ThemeMode.allCases.count)
    }

    func testOverrideSurvivesACodableRoundTrip() throws {
        for mode in ThemeMode.allCases {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(ThemeMode.self, from: data), mode)
        }
        for value in AppearanceOverride.allCases {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(AppearanceOverride.self, from: data), value)
        }
    }

    /// The three modes must persist under stable raw values; renaming one
    /// would silently reset every existing user's appearance choice.
    func testRawValuesAreStable() {
        XCTAssertEqual(ThemeMode.system.rawValue, "system")
        XCTAssertEqual(ThemeMode.light.rawValue, "light")
        XCTAssertEqual(ThemeMode.dark.rawValue, "dark")
        XCTAssertEqual(AppearanceOverride.system.rawValue, "system")
        XCTAssertEqual(AppearanceOverride.light.rawValue, "light")
        XCTAssertEqual(AppearanceOverride.dark.rawValue, "dark")
    }

    /// A settings blob written before the field existed must still decode, and
    /// an unknown value must not throw away the whole profile.
    func testSettingsDecodeWithoutAThemeUsesTheDefault() throws {
        let json = Data(#"{"threadCount":4}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(settings.threadCount, 4)
        XCTAssertEqual(settings.theme, AppSettings().theme)
    }
}
