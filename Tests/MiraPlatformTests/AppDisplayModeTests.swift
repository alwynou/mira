import AppKit
import SwiftUI
import XCTest

final class AppDisplayModeTests: XCTestCase {
    func testSavedChoiceOverridesPreviewDefault() {
        XCTAssertEqual(AppDisplayMode.resolve(stored: "light", fallback: .dark), .light)
        XCTAssertEqual(AppDisplayMode.resolve(stored: "dark", fallback: .light), .dark)
        XCTAssertEqual(AppDisplayMode.resolve(stored: "system", fallback: .dark), .system)
        XCTAssertNil(AppDisplayMode.system.colorScheme)
        XCTAssertNil(AppDisplayMode.system.appearanceName)
        XCTAssertEqual(AppDisplayMode.resolve(stored: "", fallback: .dark), .dark)
        XCTAssertEqual(AppDisplayMode.resolve(stored: "invalid", fallback: .light), .light)
    }

    @MainActor
    func testExplicitAppearanceReturnsToSystemAcrossHostedPanes() async throws {
        let app = NSApplication.shared
        let originalAppearance = app.appearance
        let name = "mira.appearance-transition-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set("system", forKey: AppDisplayMode.preferenceKey)
        app.appearance = nil
        let systemName = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let probe = AppearanceProbeState()
        let shell = MiraWindowShell(
            sidebar: AnyView(AppearanceProbe(state: probe, pane: "sidebar")),
            detail: AnyView(AppearanceProbe(state: probe, pane: "detail")),
            inspector: AnyView(EmptyView()), title: "Appearance fixture", locale: Locale(identifier: "en"),
            canInspect: false, showsInspector: .constant(false), newConversation: {})
        let host = NSHostingController(rootView: shell.modifier(MiraAppAppearance()).defaultAppStorage(defaults))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 850, height: 620))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            app.appearance = originalAppearance
            defaults.removePersistentDomain(forName: name)
        }
        for choice in [AppDisplayMode.dark, .system, .light, .system, .dark, .system] {
            defaults.set(choice.rawValue, forKey: AppDisplayMode.preferenceKey)
            try await Task.sleep(for: .milliseconds(350))
            let expected = choice.appearanceName ?? systemName
            let scheme: ColorScheme = expected == .darkAqua ? .dark : .light
            XCTAssertEqual(app.appearance?.name, choice.appearanceName, choice.rawValue)
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected, choice.rawValue)
            XCTAssertEqual(probe.schemes["sidebar"], scheme, "sidebar: \(choice.rawValue)")
            XCTAssertEqual(probe.schemes["detail"], scheme, "detail: \(choice.rawValue)")
        }
    }

    func testPreferenceSurvivesReloadWithoutChangingLanguage() throws {
        let name = "mira.display-mode-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        for mode in [AppDisplayMode.dark, .light, .system] {
            defaults.set(mode.rawValue, forKey: AppDisplayMode.preferenceKey)
            let reloaded = try XCTUnwrap(UserDefaults(suiteName: name))
            XCTAssertEqual(AppDisplayMode.resolve(stored: reloaded.string(forKey: AppDisplayMode.preferenceKey) ?? ""), mode)
            XCTAssertEqual(reloaded.string(forKey: AppLanguage.preferenceKey), "en")
        }
    }
}

@MainActor
private final class AppearanceProbeState {
    var schemes: [String: ColorScheme] = [:]
}

private struct AppearanceProbe: View {
    @Environment(\.colorScheme) private var scheme
    let state: AppearanceProbeState
    let pane: String

    var body: some View {
        Color.clear.onChange(of: scheme, initial: true) { _, value in state.schemes[pane] = value }
    }
}
