import SwiftUI
import AppKit

/// Shared visual tokens for the macOS host. Values are inferred from the supplied
/// reference image and are intentionally independent of any external product tokens.
enum MiraTheme {
    enum Colors {
        static var canvas: Color { dynamic(light: 0xFFFFFF, dark: 0x1B1B1B) }
        static var surface: Color { dynamic(light: 0xFFFFFF, dark: 0x252525) }
        static var settingsSurface: Color { dynamic(light: 0xF7F7F7, dark: 0x252525) }
        static var settingsDescription: Color { dynamic(light: 0x7A7A78, dark: 0xA3A3A0) }
        static var active: Color { dynamic(light: 0x34C759, dark: 0x30D158) }
        static var modelVision: Color { dynamic(light: 0x1C64C7, dark: 0x70AFFF) }
        static var modelTools: Color { dynamic(light: 0xCE6A0F, dark: 0xFFAD5B) }
        static var modelThinking: Color { dynamic(light: 0x8050B5, dark: 0xC095E8) }
        static var inset: Color { dynamic(light: 0xF5F5F5, dark: 0x303030) }
        static var text: Color { dynamic(light: 0x202020, dark: 0xF2F2F2) }
        static var secondaryText: Color { dynamic(light: 0x666664, dark: 0xB8B8B5) }
        static var tertiaryText: Color { dynamic(light: 0x92928F, dark: 0x858582) }
        static var border: Color { dynamic(light: 0xE8E8E8, dark: 0x41413F) }
        static var hover: Color { dynamic(light: 0xE5E5E3, dark: 0x353534) }
        static var selected: Color { dynamic(light: 0xE3E3E3, dark: 0x41413F) }
        static var sidebarOverlay: Color { dynamic(light: 0x000000, dark: 0xFFFFFF) }
        static var sidebarHighlight: Color { dynamic(light: 0xEFEFEF, dark: 0x303030) }
        static var accent: Color { dynamic(light: 0x1D1D1B, dark: 0xF2F2F0) }
        static var onAccent: Color { dynamic(light: 0xFFFFFF, dark: 0x1A1A1A) }

        private static func dynamic(light: UInt32, dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(
                    calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: 1
                )
            })
        }
    }

    enum Opacity {
        static let sidebarHighlight: Double = 0.04
        static let composerBorder: Double = 0.70
        static let composerShadow: Double = 0.06
        static let composerMaterialLight: Double = 1.0
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 6
        static let row: CGFloat = 9
        static let panel: CGFloat = 16
        static let composer: CGFloat = 22
    }

    enum Layout {
        static let sidebarMin: CGFloat = 220
        static let sidebarIdeal: CGFloat = 248
        static let sidebarMax: CGFloat = 300
        static let contentMax: CGFloat = 760
        static let composerMax: CGFloat = 760
        static let composerBottomInset: CGFloat = 14
        static let composerModelMax: CGFloat = 160
        static let composerShadowRadius: CGFloat = 4
        static let composerShadowOffset: CGFloat = 2
        static let controlHeight: CGFloat = 30
        static let selectHeight: CGFloat = 28
        static let selectMinWidth: CGFloat = 100
        static let selectMaxWidth: CGFloat = 200
        static let rowHeight: CGFloat = 34
        static let settingsPageTopInset: CGFloat = 64
        static let settingsFormLabelWidth: CGFloat = 88
        static let settingsInputHeight: CGFloat = 32
        static let settingsButtonHeight: CGFloat = 32
        static let settingsSidebarWidth: CGFloat = 180
        static let providerListWidth: CGFloat = 180
        static let providerRowHeight: CGFloat = 32
        static let providerIconSize: CGFloat = 18
        static let providerHeadingIconSize: CGFloat = 36
        static let providerModelIconSize: CGFloat = 36
        static let providerModelRowMinHeight: CGFloat = 64
        static let providerModelListMaxHeight: CGFloat = 480
    }

    enum Markdown {
        static let body: CGFloat = 14
        static let code: CGFloat = 12
        static let heading: CGFloat = 20
        static let largeHeading: CGFloat = 24
        static let lineSpacing: CGFloat = 2
    }

    enum Typography {
        @MainActor static let appKitBody: NSFont = .systemFont(ofSize: 14)
        @MainActor static let appKitCaption: NSFont = .systemFont(ofSize: 12)
        static let body: Font = .system(size: 14)
        static let sidebar: Font = .system(size: 14)
        static let caption: Font = .system(size: 12)
        static let composerFootnote: Font = .system(size: 10)
        static let composerModel: Font = .system(size: 11)
        static let section: Font = .system(size: 12)
        static let title: Font = .system(size: 20, weight: .semibold)
        static let providerTitle: Font = .system(size: 16, weight: .semibold)
        static let modelCapability: Font = .system(size: 10, weight: .medium)
        static let welcome: Font = .system(size: 28)
    }
}
