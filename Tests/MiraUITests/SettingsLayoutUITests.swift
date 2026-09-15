import AppKit
import XCTest

/// Exercises standalone settings against a disposable offline library.
@MainActor
final class SettingsLayoutUITests: XCTestCase {
    func testEnglishSettingsNavigation() throws {
        try exerciseSettings(language: "en", appearance: "light")
    }

    func testChineseSettingsNavigationInDarkAppearance() throws {
        try exerciseSettings(language: "zh-CN", appearance: "dark")
    }

    private func exerciseSettings(language: String, appearance: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-NativeSettings-UI-\(UUID())", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--profile-provider-settings", "--data-directory", directory.path,
                               "-app.language", language, "-app.displayMode", appearance, "-AppleLanguages", "(en)"]
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.menuBars.menuBarItems["File"].click()
            app.menuItems["New Window"].click()
        }
        let composer = app.textFields["conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        let main = app.windows.containing(.textField, identifier: "conversation.composer").firstMatch
        let mainFrame = main.frame
        composer.click()
        paste("SyntheticDraft42", into: composer)
        app.buttons["sidebar.settings"].click()
        let settings = app.windows["mira.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertEqual(main.frame, mainFrame)
        XCTAssertEqual(composer.value as? String, "SyntheticDraft42")
        XCTAssertFalse(settings.buttons["settings.return"].exists)

        // The app command brings the existing settings window forward.
        openSettingsFromMenu(app, language: language)
        XCTAssertEqual(app.windows.count, 2)
        let languagePicker = settings.popUpButtons["settings.language"]
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 5))
        let before = languagePicker.value as? String
        languagePicker.click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(languagePicker.value as? String, before)
        XCTAssertLessThan(languagePicker.frame.width, 180, "Short selectors should not fill the detail column.")
        capture(settings, name: "General-\(language)-\(appearance)")

        resize(settings, to: CGSize(width: 760, height: 560))
        XCTAssertEqual(settings.frame.width, 760, accuracy: 2)
        // The SwiftUI minimum describes content; the native toolbar adds height.
        let toolbar = settings.toolbars.firstMatch
        XCTAssertTrue(toolbar.exists)
        XCTAssertEqual(settings.frame.height - toolbar.frame.height, 560, accuracy: 2)
        let compactFrame = settings.frame
        capture(settings, name: "General-minimum-\(language)-\(appearance)")

        for category in ["providers", "models", "memory", "data"] {
            let item = settings.descendants(matching: .any).matching(identifier: "settings.category.\(category)").firstMatch
            XCTAssertTrue(item.exists)
            item.click()
            XCTAssertEqual(settings.frame, compactFrame, "Changing pages must not resize the window")
            if category == "providers" {
                try exerciseProviderCards(settings, app: app, language: language, appearance: appearance)
                XCTAssertTrue(settings.secureTextFields["settings.provider.apiKey"].isHittable)
                XCTAssertTrue(settings.textFields["settings.provider.baseURL"].isHittable)
                XCTAssertTrue(settings.popUpButtons["settings.provider.testModel"].isHittable)
                XCTAssertTrue(settings.buttons["settings.provider.test"].exists)
            }
            capture(settings, name: "\(category)-\(language)-\(appearance)")
            if category == "providers" {
                settings.scrollViews.containing(.secureTextField, identifier: "settings.provider.apiKey")
                    .firstMatch.scroll(byDeltaX: 0, deltaY: -420)
                capture(settings, name: "providers-scrolled-\(language)-\(appearance)")
            }
        }
        settings.descendants(matching: .any).matching(identifier: "settings.category.memory").firstMatch.click()
        let limit = settings.textFields["settings.memory.tokenLimit"]
        XCTAssertTrue(limit.waitForExistence(timeout: 5))
        limit.click()
        limit.typeKey("a", modifierFlags: .command)
        paste("12000", into: limit)
        settings.descendants(matching: .any).matching(identifier: "settings.category.general").firstMatch.click()
        settings.descendants(matching: .any).matching(identifier: "settings.category.memory").firstMatch.click()
        XCTAssertEqual(limit.value as? String, "12000", "Navigation preserves the unsaved memory draft.")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(composer.exists)
        XCTAssertEqual(composer.value as? String, "SyntheticDraft42")
        app.buttons["sidebar.settings"].click()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.popUpButtons["settings.language"].waitForExistence(timeout: 5), "Reopening starts a fresh settings session.")
        settings.descendants(matching: .any).matching(identifier: "settings.category.memory").firstMatch.click()
        XCTAssertTrue(limit.waitForExistence(timeout: 5))
        XCTAssertEqual(limit.value as? String, "10000", "Closing discards unsaved settings drafts.")
        settings.descendants(matching: .any).matching(identifier: "settings.category.providers").firstMatch.click()
        XCTAssertTrue(settings.buttons["settings.catalog.openai"].isSelected)
        XCTAssertEqual(settings.secureTextFields["settings.provider.apiKey"].value as? String, "")
        XCTAssertEqual(app.windows.count, 2)

        // Settings can be opened from the app menu without an existing conversation window.
        settings.buttons[XCUIIdentifierCloseWindow].click()
        main.buttons[XCUIIdentifierCloseWindow].click()
        openSettingsFromMenu(app, language: language)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1)
    }

    private func exerciseProviderCards(_ settings: XCUIElement, app: XCUIApplication, language: String, appearance: String) throws {
        let cards = settings.scrollViews["settings.providers.cards"]
        XCTAssertTrue(cards.waitForExistence(timeout: 5))
        let openAI = settings.buttons["settings.catalog.openai"]
        let anthropic = settings.buttons["settings.catalog.anthropic"]
        XCTAssertTrue(openAI.isSelected)
        anthropic.hover()
        capture(settings, name: "provider-hover-\(language)-\(appearance)")
        let key = settings.secureTextFields["settings.provider.apiKey"]
        key.click()
        paste("synthetic-unsaved-key", into: key)
        // A plain button must also accept the padded region outside its icon and name.
        anthropic.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).click()
        XCTAssertTrue(anthropic.isSelected)
        XCTAssertTrue((settings.textFields["settings.provider.baseURL"].value as? String)?.contains("anthropic.com") == true)
        XCTAssertEqual(settings.secureTextFields["settings.provider.apiKey"].value as? String, "")

        cards.scroll(byDeltaX: -600, deltaY: 0)
        let openRouter = settings.buttons["settings.catalog.openrouter"]
        XCTAssertTrue(openRouter.isHittable)
        openRouter.click()
        XCTAssertTrue(openRouter.isSelected)
        XCTAssertTrue((settings.textFields["settings.provider.baseURL"].value as? String)?.contains("openrouter.ai") == true)
        XCTAssertFalse(settings.descendants(matching: .any)["settings.providers.status"].exists)
        capture(settings, name: "provider-cards-end-\(language)-\(appearance)")

        // Keep a transient draft while the lazy collection scrolls its editor offscreen.
        let openRouterKey = settings.secureTextFields["settings.provider.apiKey"]
        openRouterKey.click()
        paste("synthetic-scrolling-draft", into: openRouterKey)
        // The system input-source indicator is transient and may expose a stale
        // dialog snapshot immediately after entering a native secure field.
        XCTAssertTrue(app.dialogs.firstMatch.waitForNonExistence(timeout: 5))
        let vertical = settings.scrollViews["settings.providers.page"]
        vertical.scroll(byDeltaX: 0, deltaY: -600)
        let scrolled = vertical.scrollBars.firstMatch.value as? String
        settings.descendants(matching: .any).matching(identifier: "settings.category.general").firstMatch.click()
        settings.descendants(matching: .any).matching(identifier: "settings.category.providers").firstMatch.click()
        XCTAssertTrue(openRouter.isSelected, "The provider selection survives category navigation.")
        XCTAssertEqual(vertical.scrollBars.firstMatch.value as? String, scrolled, "The scroll position survives category navigation.")
        for _ in 0..<3 {
            vertical.scroll(byDeltaX: 0, deltaY: -360)
            vertical.scroll(byDeltaX: 0, deltaY: 360)
        }
        capture(settings, name: "provider-scroll-retained-\(language)-\(appearance)")
        vertical.scroll(byDeltaX: 0, deltaY: 2400)
        XCTAssertFalse((settings.secureTextFields["settings.provider.apiKey"].value as? String)?.isEmpty ?? true)

        let deepSeek = settings.buttons["settings.catalog.deepseek"]
        for _ in 0..<3 {
            deepSeek.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.92)).click()
            XCTAssertTrue(deepSeek.isSelected)
            openRouter.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).click()
            XCTAssertTrue(openRouter.isSelected)
        }

        cards.scroll(byDeltaX: 600, deltaY: 0)
        openAI.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.92)).click()
        XCTAssertTrue(openAI.isSelected)
        XCTAssertFalse((settings.secureTextFields["settings.provider.apiKey"].value as? String)?.isEmpty ?? true,
                       "Switching providers preserves each provider's key draft until the window closes.")
    }

    private func openSettingsFromMenu(_ app: XCUIApplication, language: String) {
        app.menuBars.menuBarItems["Mira"].click()
        let title = language == "zh-CN" ? "设置…" : "Settings…" // i18n-fixture: The app-owned settings menu label.
        app.menuItems[title].click()
    }

    private func resize(_ window: XCUIElement, to size: CGSize) {
        // Drag past the minimum so native edge-drag hysteresis cannot stop the
        // gesture slightly early; assert the window's actual clamped size above.
        let overshoot: CGFloat = 80
        let right = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.6))
            .withOffset(CGVector(dx: -1, dy: 0))
        right.press(forDuration: 0.1, thenDragTo: right.withOffset(CGVector(dx: size.width - window.frame.width - overshoot, dy: 0)))
        let bottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -1))
        bottom.press(forDuration: 0.1, thenDragTo: bottom.withOffset(CGVector(dx: 0, dy: size.height - window.frame.height - overshoot)))
    }

    /// Pasting keeps the fixture independent of the user's active input method.
    private func paste(_ text: String, into field: XCUIElement) {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        field.typeKey("v", modifierFlags: .command)
        if field.elementType == .secureTextField {
            XCTAssertFalse((field.value as? String)?.isEmpty ?? true)
        } else {
            XCTAssertEqual(field.value as? String, text)
        }
    }

    private func capture(_ window: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Native Settings \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
