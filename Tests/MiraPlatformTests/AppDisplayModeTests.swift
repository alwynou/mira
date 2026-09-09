import XCTest

final class AppDisplayModeTests: XCTestCase {
    func testSavedChoiceOverridesPreviewDefault() {
        XCTAssertEqual(AppDisplayMode.resolve(stored: "light", fallback: .dark), .light)
        XCTAssertEqual(AppDisplayMode.resolve(stored: "dark", fallback: .light), .dark)
        XCTAssertEqual(AppDisplayMode.resolve(stored: "system", fallback: .dark), .system)
        XCTAssertNil(AppDisplayMode.system.colorScheme)
        XCTAssertNil(AppDisplayMode.system.appearanceName)
        XCTAssertEqual(AppDisplayMode.resolve(stored: "", fallback: .dark), .dark)
        XCTAssertEqual(AppDisplayMode.resolve(stored: "invalid", fallback: .light), .light)
    }

    func testPreferenceSurvivesReloadWithoutChangingLanguage() throws {
        let name = "mira.display-mode-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        for mode in [AppDisplayMode.dark, .light, .system] {
            defaults.set(mode.rawValue, forKey: AppDisplayMode.preferenceKey)
            let reloaded = try XCTUnwrap(UserDefaults(suiteName: name))
            XCTAssertEqual(AppDisplayMode.resolve(stored: reloaded.string(forKey: AppDisplayMode.preferenceKey) ?? ""), mode)
            XCTAssertEqual(reloaded.string(forKey: AppLanguage.preferenceKey), "en")
        }
    }
}
