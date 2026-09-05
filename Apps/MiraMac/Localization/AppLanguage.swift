import Foundation

/// UI preferences never affect model prompts, stored records, or user content.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-CN"

    static let preferenceKey = "app.language"
    var id: String { rawValue }
    var bundleIdentifier: String { self == .english ? "en" : "zh-Hans" }
    var locale: Locale { Locale(identifier: self == .english ? "en" : "zh_Hans_CN") }

    static func resolve(stored: String, preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        if let choice = Self(rawValue: stored) { return choice }
        for identifier in preferredLanguages {
            let parts = identifier.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-")
            if parts.first == "en" { return .english }
            if parts.first == "zh", !parts.contains("hant"), !parts.contains("tw"), !parts.contains("hk"), !parts.contains("mo") {
                return .simplifiedChinese
            }
        }
        return .english
    }
}
