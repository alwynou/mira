import AppKit
import SwiftUI
import Testing
import Observation

@MainActor
@Suite("Settings credential field", .serialized)
struct MiraSettingsCredentialFieldTests {
    @Test("stored and replacement values use the same populated native secure field")
    func storedKeyUsesNativeSecureContent() throws {
        _ = NSApplication.shared
        let draft = CredentialDraft()
        draft.text = "synthetic-stored-key"
        let host = NSHostingView(rootView: CredentialFieldFixture(draft: draft, hasStoredKey: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        pump(host)

        let savedField = try #require(secureField(in: host))
        #expect(savedField.stringValue == "synthetic-stored-key")
        #expect(savedField.placeholderString != String(repeating: "\u{2022}", count: 8))
        #expect(savedField.alignment == .left || savedField.alignment == .natural)

        draft.text = "synthetic-replacement-key"
        pump(host)
        let replacementField = try #require(secureField(in: host))
        #expect(replacementField.stringValue == draft.text)

        draft.text = ""
        host.rootView = CredentialFieldFixture(draft: draft, hasStoredKey: false)
        pump(host)
        let emptyField = try #require(secureField(in: host))
        #expect(emptyField.placeholderString != String(repeating: "\u{2022}", count: 8))
        #expect(emptyField.stringValue.isEmpty)
        #expect(draft.text.isEmpty)
    }

    private func secureField(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField { return field }
        return view.subviews.lazy.compactMap(secureField(in:)).first
    }

    private func pump(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        view.layoutSubtreeIfNeeded()
    }
}

@MainActor
@Observable
private final class CredentialDraft {
    var text = ""
}

private struct CredentialFieldFixture: View {
    @Bindable var draft: CredentialDraft
    let hasStoredKey: Bool

    var body: some View {
        MiraSettingsCredentialField(text: $draft.text, hasStoredKey: hasStoredKey)
    }
}
