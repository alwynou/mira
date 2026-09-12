import XCTest

@MainActor
final class ConversationSwitchUITests: XCTestCase {
    func testConversationSwitchingEnglishLight() throws {
        try runFixture(language: "en", dark: false)
    }

    func testConversationSwitchingChineseDarkMinimumWindow() throws {
        try runFixture(language: "zh-CN", dark: true)
    }

    private func runFixture(language: String, dark: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-Switch-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = directory.appendingPathComponent("conversation-switch.json")
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo", "--native-rendering-benchmark", "--verify-conversation-switching",
            "--data-directory", directory.appendingPathComponent("library").path, "--benchmark-report", report.path,
            "-app.language", language, "-app.displayMode", dark ? "dark" : "light", "-AppleLanguages", "(en)"
        ]
        if dark { app.launchArguments += ["--benchmark-minimum-window"] }
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
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["conversation.transcript"].waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: report.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Conversation switching - \(language) - \(dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
        try require(FileManager.default.fileExists(atPath: report.path), "Conversation switch benchmark did not write a report.")
        XCTAssertTrue(app.descendants(matching: .any)["conversation.transcript"].exists, "The native transcript is not mounted after switching.")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        let reportAttachment = XCTAttachment(data: try Data(contentsOf: report), uniformTypeIdentifier: "public.json")
        reportAttachment.name = "Conversation-switch-report-\(language)"
        reportAttachment.lifetime = .keepAlways
        add(reportAttachment)
        XCTAssertEqual(json?["passed"] as? Bool, true, "Conversation switch benchmark failed; see the attached synthetic report.")
        XCTAssertEqual(json?["sameSelectionPreserved"] as? Bool, true)
        XCTAssertEqual(json?["anchorPreserved"] as? Bool, true)
        XCTAssertTrue((json?["firstMessageCount"] as? Int ?? 0) > 0)
        XCTAssertTrue((json?["secondMessageCount"] as? Int ?? 0) > 0)
        if let ids = json?["conversationIDs"] as? [String], ids.count == 2 {
            try exerciseNativeScrolling(app, conversationIDs: ids)
        } else { XCTFail("Synthetic conversation identities are missing.") }
    }

    private func exerciseNativeScrolling(_ app: XCUIApplication, conversationIDs: [String]) throws {
        let transcript = app.scrollViews["conversation.transcript"]
        let previous = try visibleUserMessage(in: transcript)
        transcript.scroll(byDeltaX: 0, deltaY: 300)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let scrolled = try visibleUserMessage(in: transcript)
        XCTAssertTrue(previous.text != scrolled.text || abs(previous.y - scrolled.y) > 20, "A real wheel gesture must move the transcript.")
        let first = app.buttons["conversation.row.\(conversationIDs[0])"]
        let second = app.buttons["conversation.row.\(conversationIDs[1])"]
        first.click()
        first.click()
        let repeated = try visibleUserMessage(in: transcript, matching: scrolled.text)
        XCTAssertEqual(repeated.text, scrolled.text)
        XCTAssertEqual(repeated.y, scrolled.y, accuracy: 2)
        second.click()
        first.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let restored = try visibleUserMessage(in: transcript, matching: scrolled.text)
        XCTAssertEqual(restored.text, scrolled.text)
        XCTAssertEqual(restored.y, scrolled.y, accuracy: 2)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Native wheel position restored"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func visibleUserMessage(in transcript: XCUIElement, matching text: String? = nil) throws -> (text: String, y: CGFloat) {
        for element in transcript.staticTexts.allElementsBoundByIndex {
            if let value = element.value as? String, value.hasPrefix("User message "),
               text.map({ value == $0 }) ?? element.frame.intersects(transcript.frame) {
                return (value, element.frame.minY)
            }
        }
        throw NSError(domain: "MiraUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: "No synthetic user message is visible."])
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "MiraUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
