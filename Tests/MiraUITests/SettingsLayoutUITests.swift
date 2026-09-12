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
        app.launchArguments = ["--demo", "--data-directory", directory.path,
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
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(composer.exists)
        XCTAssertEqual(composer.value as? String, "SyntheticDraft42")
        app.buttons["sidebar.settings"].click()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertEqual(limit.value as? String, "12000")
        XCTAssertEqual(app.windows.count, 2)

        // Settings can be opened from the app menu without an existing conversation window.
        settings.buttons[XCUIIdentifierCloseWindow].click()
        main.buttons[XCUIIdentifierCloseWindow].click()
        openSettingsFromMenu(app, language: language)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1)
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
        XCTAssertEqual(field.value as? String, text)
    }

    private func capture(_ window: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Native Settings \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
