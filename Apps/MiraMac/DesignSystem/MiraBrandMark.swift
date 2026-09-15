import SwiftUI

/// Reuses the selected Contour Silver identity in both system appearances.
struct MiraBrandMark: View {
    var body: some View {
        Image(decorative: "MiraMark")
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}
