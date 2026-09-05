import Foundation
import MiraCore

/// Resolves app-owned messages at presentation time. Never pass user or model content here.
enum L10n {
    static func string(_ key: String, locale: Locale, bundle: Bundle = .main) -> String {
        let language = AppLanguage.resolve(stored: "", preferredLanguages: [locale.identifier])
        let localizedBundle = bundle.path(forResource: language.bundleIdentifier, ofType: "lproj").flatMap(Bundle.init(path:))
        return (localizedBundle ?? bundle).localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, locale: Locale, bundle: Bundle = .main, _ arguments: CVarArg...) -> String {
        String(format: string(key, locale: locale, bundle: bundle), locale: locale, arguments: arguments)
    }

    static func error(_ error: MiraError, locale: Locale, bundle: Bundle = .main) -> String {
        string(error.message, locale: locale, bundle: bundle)
    }
}
