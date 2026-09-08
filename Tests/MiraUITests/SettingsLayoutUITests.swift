import XCTest

/// Settings navigation and controls are exercised with an isolated offline library.
@MainActor
final class SettingsLayoutUITests: XCTestCase {
    func testEnglishSettingsNavigation() throws {
        try exerciseSettings(language: "en", poolLabel: "Model Pool", dark: false)
    }

    func testChineseSettingsNavigationInDarkAppearance() throws {
        try exerciseSettings(language: "zh-CN", poolLabel: "模型池", dark: true) // i18n-fixture: Chinese segmented-control label in the supported locale.
    }

    func testReadingPositionAcrossSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-Reading-UI-\(UUID())", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--data-directory", directory.path, "-app.language", "en", "-AppleLanguages", "(en)"]
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
        composer.click()
        composer.typeText("1234567890")
        composer.typeKey(.tab, modifierFlags: [])
        app.buttons["sidebar.settings"].click()
        try exerciseConversationReturn(app)
    }

    private func exerciseSettings(language: String, poolLabel: String, dark: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-Settings-UI-\(UUID())", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--data-directory", directory.path, "-app.language", language, "-AppleLanguages", "(en)"]
        if dark { app.launchArguments.append("--design-preview-dark") }
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
        guard app.descendants(matching: .any)["conversation.composer"].waitForExistence(timeout: 15) else {
            XCTFail("The conversation window did not finish opening.")
            return
        }
        let mainWindow = app.windows.firstMatch
        let originalFrame = mainWindow.frame
        let composer = app.textFields["conversation.composer"]
        composer.click()
        composer.typeText("1234567890")
        composer.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(composer.value as? String, "1234567890")
        let mainClose = mainWindow.buttons[XCUIIdentifierCloseWindow].frame
        let mainCloseOffset = CGPoint(x: mainClose.minX - mainWindow.frame.minX, y: mainClose.minY - mainWindow.frame.minY)
        openSettings(app, language: language)
        let providers = app.buttons["settings.category.providers"]
        guard providers.waitForExistence(timeout: 15) else {
            XCTFail("The native Settings command did not open the settings mode.")
            return
        }
        XCTAssertFalse(app.buttons["settings.back"].exists)
        XCTAssertFalse(app.buttons["settings.forward"].exists)
        let window = app.windows.firstMatch
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertFalse(composer.exists)
        XCTAssertTrue(window.exists)
        let close = window.buttons[XCUIIdentifierCloseWindow]
        let zoom = window.buttons[XCUIIdentifierFullScreenWindow]
        XCTAssertTrue(close.isEnabled)
        XCTAssertTrue(zoom.isEnabled)
        XCTAssertEqual(close.frame.minX - window.frame.minX, mainCloseOffset.x, accuracy: 2)
        XCTAssertEqual(close.frame.minY - window.frame.minY, mainCloseOffset.y, accuracy: 2)
        let sidebarToggle = window.toolbars.buttons.firstMatch
        XCTAssertEqual(window.toolbars.buttons.count, 1, "Settings must have only the native sidebar toggle in its toolbar.")
        XCTAssertEqual(sidebarToggle.frame.midY, close.frame.midY, accuracy: 2)
        XCTAssertGreaterThan(sidebarToggle.frame.minX, zoom.frame.maxX)
        sidebarToggle.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: providers)], timeout: 5), .completed)
        XCTAssertTrue(window.toolbars.buttons["settings.return"].waitForExistence(timeout: 5), "Collapsed settings must retain a return action.")
        sidebarToggle.click()
        XCTAssertTrue(providers.waitForExistence(timeout: 5))
        if dark {
            let size = window.frame.size
            let rightEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.6)).withOffset(CGVector(dx: -1, dy: 0))
            rightEdge.press(forDuration: 0.1, thenDragTo: rightEdge.withOffset(CGVector(dx: 850 - size.width, dy: 0)))
            let bottomEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 1)).withOffset(CGVector(dx: 0, dy: -1))
            bottomEdge.press(forDuration: 0.1, thenDragTo: bottomEdge.withOffset(CGVector(dx: 0, dy: 642 - window.frame.height)))
            XCTAssertEqual(window.frame.width, 850, accuracy: 2)
            XCTAssertEqual(window.frame.height - window.toolbars.firstMatch.frame.height, 620, accuracy: 2)
        }

        providers.click()
        let search = app.textFields["settings.providers.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("OpenAI")
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["settings.catalog.openai"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.catalog.anthropic"].exists)
        app.buttons["settings.catalog.openai"].click()
        guard app.secureTextFields["settings.provider.apiKey"].waitForExistence(timeout: 5) else {
            XCTFail("The provider detail did not expose its secure field.")
            return
        }
        XCTAssertFalse(app.buttons["settings.provider.save"].isEnabled)
        let providerCapture = XCTAttachment(screenshot: window.screenshot())
        providerCapture.name = "Settings provider - \(language)"
        providerCapture.lifetime = .keepAlways
        add(providerCapture)
        providers.click()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.buttons["settings.catalog.openai"].click()
        XCTAssertTrue(app.secureTextFields["settings.provider.apiKey"].waitForExistence(timeout: 5))

        app.buttons["settings.category.models"].click()
        let conversationModel = app.descendants(matching: .any).matching(identifier: "settings.models.default.conversation").firstMatch
        XCTAssertTrue(conversationModel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings.models.default.memoryExtraction"].exists)
        conversationModel.click()
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["settings.category.models"].click()
        let modelCapture = XCTAttachment(screenshot: window.screenshot())
        modelCapture.name = "Settings purpose defaults - \(language)"
        modelCapture.lifetime = .keepAlways
        add(modelCapture)
        app.radioButtons[poolLabel].click()
        XCTAssertFalse(conversationModel.exists)

        app.buttons["settings.category.memory"].click()
        XCTAssertTrue(app.popUpButtons["settings.memory.mode"].waitForExistence(timeout: 5))
        let tokenLimit = app.textFields["settings.memory.tokenLimit"]
        XCTAssertTrue(tokenLimit.exists)
        tokenLimit.click()
        tokenLimit.typeKey("a", modifierFlags: .command)
        tokenLimit.typeText("12000")
        tokenLimit.typeKey(.tab, modifierFlags: [])
        app.buttons["settings.category.data"].click()
        XCTAssertTrue(app.buttons["settings.data.export"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.data.restore"].exists)
        XCTAssertFalse(tokenLimit.exists, "Inactive preference pages must be unmounted.")
        app.buttons["settings.category.memory"].click()
        XCTAssertEqual(tokenLimit.value as? String, "12000", "Changing categories must retain an unsaved preference draft.")
        app.buttons["settings.category.general"].click()
        app.buttons["settings.return"].click()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "1234567890")
        XCTAssertFalse(tokenLimit.exists, "Inactive pages must leave the view hierarchy.")
        openSettings(app, language: language)
        XCTAssertTrue(app.buttons["settings.category.general"].waitForExistence(timeout: 5))
        app.buttons["settings.category.memory"].click()
        XCTAssertEqual(tokenLimit.value as? String, "12000", "Leaving settings must retain an unsaved preference draft.")
        openSettings(app, language: language)
        XCTAssertEqual(app.windows.count, 1, "Repeated entry must reuse the main window.")
        app.buttons["settings.return"].click()
        app.buttons["sidebar.settings"].click()
        XCTAssertTrue(tokenLimit.waitForExistence(timeout: 5))
    }

    private func exerciseConversationReturn(_ app: XCUIApplication) throws {
        app.buttons["settings.return"].click()
        app.buttons["conversation.send"].click()
        XCTAssertTrue(app.buttons["conversation.stop"].waitForExistence(timeout: 5))
        app.buttons["sidebar.settings"].click()
        XCTAssertFalse(app.textFields["conversation.composer"].exists)
        app.buttons["settings.return"].click()
        XCTAssertTrue(app.buttons["conversation.send"].waitForExistence(timeout: 45), "The runtime must finish its offline reply after leaving settings.")
        let transcript = app.scrollViews.matching(identifier: "conversation.transcript").firstMatch
        XCTAssertTrue(transcript.exists)
        transcript.scroll(byDeltaX: 0, deltaY: 400)
        XCTAssertTrue(app.buttons["Jump to latest"].waitForExistence(timeout: 5))
        let bar = transcript.descendants(matching: .scrollBar).firstMatch
        let offset = try XCTUnwrap(scrollValue(bar))
        XCTAssertLessThan(offset, 0.95, "The fixture must be reading history before switching modes.")
        let before = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        before.name = "Conversation reading position before settings"
        before.lifetime = .keepAlways
        add(before)
        app.buttons["sidebar.settings"].click()
        app.buttons["settings.return"].click()
        XCTAssertTrue(app.buttons["Jump to latest"].waitForExistence(timeout: 5))
        XCTAssertEqual(try XCTUnwrap(scrollValue(bar)), offset, accuracy: 0.03)
        let after = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        after.name = "Conversation reading position after settings"
        after.lifetime = .keepAlways
        add(after)
    }

    private func scrollValue(_ element: XCUIElement) -> Double? {
        if let value = element.value as? NSNumber { return value.doubleValue }
        if let value = element.value as? String { return Double(value) }
        return nil
    }

    private func openSettings(_ app: XCUIApplication, language: String) {
        app.menuBars.menuBarItems["Mira"].click()
        let title = language == "zh-CN" ? "设置…" : "Settings…" // i18n-fixture: App-owned menu label in the supported locale.
        app.menuItems[title].click()
    }

}
