import SwiftUI

struct LibraryStartupView: View {
    @Environment(\.locale) private var locale
    let container: AppContainer

    var body: some View {
        Group {
            switch container.status.phase {
            case .starting:
                ProgressView("Opening library")
            case .closing:
                ProgressView("Closing library")
            case .closed:
                ContentUnavailableView(
                    "Library closed", systemImage: "externaldrive",
                    description: Text("The library is closed. Quit and reopen Mira to continue."))
            case .failed:
                ContentUnavailableView(
                    "Unable to Open Library", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(
                        container.startupError.map { L10n.error($0, locale: locale) }
                            ?? L10n.string("Check available storage and directory permissions.", locale: locale)))
            case .ready, .maintaining:
                ProgressView("Opening library")
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
