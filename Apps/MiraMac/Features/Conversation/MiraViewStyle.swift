import SwiftUI

/// Shared spacing roles from the prototype's portable SwiftUI mapping.
enum MiraLayout {
    static let micro: CGFloat = 2
    static let tiny: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let section: CGFloat = 24
    static let gutter: CGFloat = 32
    static let readingWidth: CGFloat = 820
}

enum MiraSurface {
    static let content = Color(nsColor: .textBackgroundColor)
    // Tahoe resolves controlBackgroundColor to the same color as the page.
    // The system's alternating content surface preserves the prototype's subtle
    // card separation in both appearances without copying its RGB/alpha values.
    static let subtle = Color(nsColor: .alternatingContentBackgroundColors[1])
}
