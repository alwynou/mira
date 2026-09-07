import SwiftUI
import AppKit

/// Shared visual tokens for the macOS host. Values are inferred from the supplied
/// reference image and are intentionally independent of any external product tokens.
enum MiraTheme {
    enum Colors {
        static var canvas: Color { dynamic(light: 0xFFFFFF, dark: 0x1B1B1B) }
        static var surface: Color { dynamic(light: 0xFFFFFF, dark: 0x252525) }
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
        static let controlHeight: CGFloat = 30
        static let rowHeight: CGFloat = 34
    }

    enum Typography {
        static let body: Font = .system(size: 14)
        static let sidebar: Font = .system(size: 14)
        static let caption: Font = .system(size: 12)
        static let section: Font = .system(size: 12)
        static let title: Font = .system(size: 20, weight: .semibold)
        static let welcome: Font = .system(size: 28)
    }
}
