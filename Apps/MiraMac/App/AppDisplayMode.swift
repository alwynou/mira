import AppKit
import SwiftUI

/// Application-wide presentation preference; it never enters the conversation runtime.
enum AppDisplayMode: String {
    case light
    case dark
    case system

    static let preferenceKey = "app.displayMode"

    static var initialValue: Self {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--design-preview-dark") { return .dark }
        #endif
        return .system
    }

    static func resolve(stored: String, fallback: Self = initialValue) -> Self {
        Self(rawValue: stored) ?? fallback
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    var appearanceName: NSAppearance.Name? {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        case .system: nil
        }
    }
}
