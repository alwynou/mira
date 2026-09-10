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

/// Own the app-wide override in one place so native panes and SwiftUI inherit together.
struct MiraAppAppearance: ViewModifier {
    @AppStorage(AppDisplayMode.preferenceKey) private var preference = AppDisplayMode.initialValue.rawValue
    private var mode: AppDisplayMode { .resolve(stored: preference) }

    func body(content: Content) -> some View {
        // A second SwiftUI color-scheme preference can leave hosted panes dark after returning to nil.
        content
            .onChange(of: mode, initial: true) { _, mode in
                if NSApp.appearance?.name != mode.appearanceName {
                    NSApp.appearance = mode.appearanceName.flatMap { NSAppearance(named: $0) }
                }
            }
    }
}
