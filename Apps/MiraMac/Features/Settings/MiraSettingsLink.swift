import SwiftUI

enum MiraSettingsWindow {
    static let id = "mira.settings"
}

extension EnvironmentValues {
    // Carry the scene action across the conversation's AppKit hosting boundary.
    @Entry var miraOpenSettingsWindow: OpenWindowAction? = nil
}

struct MiraSettingsLink<Label: View>: View {
    @Environment(\.miraOpenSettingsWindow) private var openWindow
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            openWindow?(id: MiraSettingsWindow.id)
        } label: {
            label()
        }
        .disabled(openWindow == nil)
    }
}

struct MiraSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let locale: Locale

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                openWindow(id: MiraSettingsWindow.id)
            } label: {
                Text(L10n.string("Settings…", locale: locale))
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
