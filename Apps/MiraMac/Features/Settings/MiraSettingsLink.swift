import SwiftUI
import Observation
import AppKit

/// Navigation is local to a main window; commands target the focused scene.
@MainActor @Observable
final class WindowNavigation {
    private(set) var showsSettings = false
    var readingState = ConversationReadingState()

    func openSettings() { setSettingsVisible(true) }
    func returnToConversation() { setSettingsVisible(false) }

    private func setSettingsVisible(_ visible: Bool) {
        // Commit any marked text before its native editor leaves the view hierarchy.
        guard visible != showsSettings else { return }
        guard NSApp.keyWindow?.makeFirstResponder(nil) != false else { return }
        if visible { readingState.leave() }
        showsSettings = visible
    }
}

private struct WindowNavigationKey: FocusedValueKey {
    typealias Value = WindowNavigation
}

extension FocusedValues {
    var miraNavigation: WindowNavigation? {
        get { self[WindowNavigationKey.self] }
        set { self[WindowNavigationKey.self] = newValue }
    }
}

struct MiraSettingsLink<Label: View>: View {
    @Environment(WindowNavigation.self) private var navigation
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { navigation.openSettings() } label: { label() }
    }
}

struct MiraSettingsCommands: Commands {
    let locale: Locale
    @FocusedValue(\.miraNavigation) private var navigation

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L10n.string("Settings…", locale: locale)) { navigation?.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(navigation == nil)
        }
    }
}
