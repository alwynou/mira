import AppKit
import SwiftUI
import Testing

@MainActor
@Suite("Native settings selection", .serialized)
struct MiraSettingsSelectTests {
    @Test("the native popup preserves an unselected and empty state")
    func unselectedAndEmptyDoNotSelectFirstItem() throws {
        _ = NSApplication.shared
        let state = SelectionState()
        let fixture = SelectFixture(state: state, options: options(), locale: Locale(identifier: "en"))
        let (host, window) = try host(fixture)
        defer { window.close() }

        let button = try #require(popup(in: host))
        #expect(button.cell is NSPopUpButtonCell)
        #expect(button.title == "Select an option")
        #expect(state.value.isEmpty)

        host.rootView = SelectFixture(state: state, options: [], locale: Locale(identifier: "en"))
        pump(host)
        #expect(button.title == "Select an option")
        #expect(button.itemArray.contains { $0.title == "No options available" })
        #expect(!button.isEnabled)
        #expect(state.value.isEmpty)
    }

    @Test("native menu actions update the binding and reselecting stays selected")
    func nativeChoiceAndReselection() throws {
        _ = NSApplication.shared
        let state = SelectionState()
        let fixture = SelectFixture(state: state, options: options(), locale: Locale(identifier: "en"))
        let (host, window) = try host(fixture)
        defer { window.close() }
        let button = try #require(popup(in: host))
        let second = try #require(button.itemArray.first { $0.title == "Second" })

        try choose(second)
        #expect(state.value == "second")

        host.rootView = SelectFixture(state: state, options: options(), locale: Locale(identifier: "en"))
        pump(host)
        #expect(button.title == "Second")

        try choose(second)
        #expect(state.value == "second")
        host.rootView = SelectFixture(state: state, options: options(), locale: Locale(identifier: "en"))
        pump(host)
        #expect(button.title == "Second")
    }

    @Test("clear selection is explicit and does not appear while unselected")
    func explicitClearSelection() throws {
        _ = NSApplication.shared
        let state = SelectionState(value: "first")
        let fixture = SelectFixture(state: state, options: options(), locale: Locale(identifier: "en"), clearTitle: "Clear Selection")
        let (host, window) = try host(fixture)
        defer { window.close() }
        let button = try #require(popup(in: host))
        #expect(button.itemArray.contains { $0.title == "Clear Selection" })

        let clear = try #require(button.itemArray.first { $0.title == "Clear Selection" })
        try choose(clear)
        #expect(state.value.isEmpty)

        host.rootView = SelectFixture(state: state, options: options(), locale: Locale(identifier: "en"), clearTitle: "Clear Selection")
        pump(host)
        #expect(button.title == "Select an option")
        #expect(button.itemArray.allSatisfy { $0.title != "Clear Selection" })
    }

    @Test("option removal, locale labels, and disabled state update the native control")
    func dynamicOptionsLocaleAndDisabledState() throws {
        _ = NSApplication.shared
        let state = SelectionState(value: "second")
        let initial = SelectFixture(state: state, options: options(), locale: Locale(identifier: "en"))
        let (host, window) = try host(initial)
        defer { window.close() }
        let button = try #require(popup(in: host))
        #expect(button.itemArray.map(\.title) == ["First", "Second"])

        host.rootView = SelectFixture(state: state, options: options().filter { $0.id == "first" }, locale: Locale(identifier: "en"))
        pump(host)
        #expect(button.title == "Select an option")
        #expect(button.itemArray.map(\.title).contains("First"))
        #expect(!button.itemArray.map(\.title).contains("Second"))
        #expect(state.value == "second", "Removing an option must not silently rewrite the binding.")

        let localizedOptions = [
            MiraSettingsSelect.Option(id: "english", title: "English"),
            MiraSettingsSelect.Option(id: "chinese", title: LocalizedStringResource("Chinese (Simplified)", bundle: .atURL(Bundle(for: SelectionTestResources.self).bundleURL))),
            MiraSettingsSelect.Option(id: "model", verbatimTitle: "Model")
        ]
        host.rootView = SelectFixture(state: state, options: localizedOptions, locale: Locale(identifier: "zh-Hans"))
        pump(host)
        #expect(button.itemArray.map(\.title).suffix(3) == ["English", "简体中文", "Model"]) // i18n-fixture: Localized option beside a verbatim model name.

        host.rootView = SelectFixture(state: state, options: localizedOptions, locale: Locale(identifier: "zh-Hans"), isEnabled: false)
        pump(host)
        #expect(button.isEnabled == false)
        host.rootView = SelectFixture(state: state, options: localizedOptions, locale: Locale(identifier: "zh-Hans"), isEnabled: true)
        pump(host)
        #expect(button.isEnabled)
    }

    private func options() -> [MiraSettingsSelect.Option] {
        [
            .init(id: "first", title: "First"),
            .init(id: "second", title: "Second")
        ]
    }

    private func host(_ fixture: SelectFixture) throws -> (NSHostingView<SelectFixture>, NSWindow) {
        let host = NSHostingView(rootView: fixture)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.frame = window.contentView?.bounds ?? .zero
        pump(host)
        return (host, window)
    }

    private func popup(in view: NSView) -> NSPopUpButton? {
        if let button = view as? NSPopUpButton { return button }
        return view.subviews.lazy.compactMap(popup(in:)).first
    }

    private func choose(_ item: NSMenuItem) throws {
        let action = try #require(item.action)
        let target = try #require(item.target)
        #expect(NSApp.sendAction(action, to: target, from: item))
    }

    private func pump(_ host: NSHostingView<SelectFixture>) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class SelectionState {
    var value: String

    init(value: String = "") { self.value = value }
}

@MainActor
private struct SelectFixture: View {
    let state: SelectionState
    let options: [MiraSettingsSelect.Option]
    let locale: Locale
    var clearTitle: LocalizedStringResource?
    var isEnabled = true

    var body: some View {
        MiraSettingsSelect(title: "Display Language",
                           selection: Binding(get: { state.value }, set: { state.value = $0 }),
                           options: options, identifier: "settings.select",
                           clearSelectionTitle: clearTitle)
            .environment(\.locale, locale)
            .disabled(!isEnabled)
    }
}

private final class SelectionTestResources: NSObject {}
