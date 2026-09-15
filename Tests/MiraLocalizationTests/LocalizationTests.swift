import Foundation
import XCTest
import MiraCore

final class LocalizationTests: XCTestCase {
    private var resources: Bundle { Bundle(for: Self.self) }

    func testLanguageSelectionAndFallback() {
        XCTAssertEqual(AppLanguage.resolve(stored: "zh-CN", preferredLanguages: ["en-US"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(stored: "en", preferredLanguages: ["zh-Hans-CN"]), .english)
        XCTAssertEqual(AppLanguage.resolve(stored: "", preferredLanguages: ["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(stored: "", preferredLanguages: ["zh_Hans_CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(stored: "invalid", preferredLanguages: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.resolve(stored: "", preferredLanguages: ["zh-Hant-TW"]), .english)
    }

    func testExplicitLocaleOverridesProcessLanguageWithoutChangingTheMessage() {
        let error = MiraError(.credentialMissing, "Enter an API key.")
        XCTAssertEqual(L10n.error(error, locale: AppLanguage.english.locale, bundle: resources), "Enter an API key.")
        let translated = "请填写 API 密钥。" // i18n-fixture: Expected Simplified Chinese validation message.
        XCTAssertNotEqual(translated, error.message)
        XCTAssertEqual(L10n.error(error, locale: AppLanguage.simplifiedChinese.locale, bundle: resources), translated)
        XCTAssertEqual(L10n.error(error, locale: AppLanguage.english.locale, bundle: resources), "Enter an API key.")
        XCTAssertEqual(error.message, "Enter an API key.")
    }

    func testUnknownMessagesHaveAnEnglishFallbackAndPreferencesSurviveReload() {
        XCTAssertEqual(L10n.string("Unknown fixture key", locale: Locale(identifier: "fr_FR"), bundle: resources), "Unknown fixture key")
        let name = "mira.language-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.preferenceKey)
        let reloaded = UserDefaults(suiteName: name)!
        XCTAssertEqual(AppLanguage.resolve(stored: reloaded.string(forKey: AppLanguage.preferenceKey) ?? "", preferredLanguages: ["en"]), .simplifiedChinese)
    }

    func testBundledCatalogHasBothLanguages() throws {
        for language in AppLanguage.allCases {
            let path = try XCTUnwrap(resources.path(forResource: language.bundleIdentifier, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            XCTAssertGreaterThan(values.count, 150)
            XCTAssertNotNil(values["Display Language"])
            XCTAssertNotNil(values["Enter an API key."])
        }
    }

    func testLocalizedFormatPreservesTypedArguments() {
        XCTAssertEqual(L10n.string("Input", locale: AppLanguage.english.locale, bundle: resources), "Input")
        XCTAssertEqual(L10n.string("Input", locale: AppLanguage.simplifiedChinese.locale, bundle: resources), "输入") // i18n-fixture: Expected Simplified Chinese tool input label.
        XCTAssertEqual(L10n.string("Thought for a while", locale: AppLanguage.simplifiedChinese.locale, bundle: resources), "思考了一会儿") // i18n-fixture: Expected Simplified Chinese reasoning-only summary.
        XCTAssertEqual(L10n.format("%lld tool calls", locale: AppLanguage.english.locale, bundle: resources, Int64(2)), "2 tool calls")
        XCTAssertEqual(L10n.format("%lld messages", locale: AppLanguage.simplifiedChinese.locale, bundle: resources, Int64(3)), "3 条消息") // i18n-fixture: Expected Simplified Chinese message count.
        XCTAssertEqual(L10n.format("%lld tool calls · %lld messages", locale: AppLanguage.english.locale, bundle: resources, Int64(2), Int64(3)), "2 tool calls · 3 messages")
        XCTAssertEqual(L10n.format("%lld tool calls · %lld messages", locale: AppLanguage.simplifiedChinese.locale, bundle: resources, Int64(2), Int64(3)), "2 次工具调用 · 3 条消息") // i18n-fixture: Expected Simplified Chinese process counts.
        XCTAssertEqual(L10n.format("Step %lld · Attempt %lld", locale: AppLanguage.english.locale, bundle: resources, Int64(2), Int64(3)), "Step 2 · Attempt 3")
        XCTAssertEqual(L10n.format("Step %lld · Attempt %lld", locale: AppLanguage.simplifiedChinese.locale, bundle: resources, Int64(2), Int64(3)), "步骤 2 · 尝试 3") // i18n-fixture: Expected Simplified Chinese format.
    }
}
