import XCTest
import AppKit

@MainActor
final class ConversationSwitchUITests: XCTestCase {
    func testConversationSwitchingEnglishLight() throws {
        try runFixture(language: "en", dark: false)
    }

    func testConversationSwitchingChineseDarkMinimumWindow() throws {
        try runFixture(language: "zh-CN", dark: true)
    }

    func testRepeatedNewConversationClicksKeepOneDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-New-Draft-\(UUID())", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--data-directory", directory.path, "-app.language", "en", "-AppleLanguages", "(en)"]
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        let newConversation = app.buttons["sidebar.newConversation"]
        XCTAssertTrue(newConversation.waitForExistence(timeout: 10))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation.row."))
        let initialFormalRowCount = rows.count
        let composer = app.textFields["conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        try enter("Unsent draft survives repeated new conversation actions", in: composer)
        for _ in 0..<4 { newConversation.click() }
        XCTAssertEqual(rows.count, initialFormalRowCount, "An unsent draft must not add a persisted sidebar conversation.")
        XCTAssertEqual(composer.value as? String, "Unsent draft survives repeated new conversation actions")

        app.buttons["conversation.send"].click()
        let promoted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in MainActor.assumeIsolated { rows.count == initialFormalRowCount + 1 } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [promoted], timeout: 10), .completed)
        XCTAssertTrue(app.scrollViews["conversation.transcript"].waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "")
        newConversation.click()
        newConversation.click()
        XCTAssertEqual(composer.value as? String, "")
        XCTAssertEqual(rows.count, initialFormalRowCount + 1, "Only a sent draft should create a formal conversation.")
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
        XCTAssertEqual(json?["firstListReused"] as? Bool, true)
        XCTAssertEqual(json?["secondListDistinct"] as? Bool, true)
        XCTAssertEqual(json?["firstComposerPreserved"] as? Bool, true)
        XCTAssertEqual(json?["snapshotLoadCountAfterReturn"] as? Int, json?["snapshotLoadCountBeforeReturn"] as? Int)
        XCTAssertEqual(json?["snapshotLoadCount"] as? Int, json?["snapshotLoadCountBeforeReturn"] as? Int)
        XCTAssertEqual(json?["anchorPreserved"] as? Bool, true)
        XCTAssertTrue((json?["firstMessageCount"] as? Int ?? 0) > 0)
        XCTAssertTrue((json?["secondMessageCount"] as? Int ?? 0) > 0)
        if let ids = json?["conversationIDs"] as? [String], ids.count == 2 {
            try exerciseNativeScrolling(app, conversationIDs: ids)
        } else { XCTFail("Synthetic conversation identities are missing.") }
    }

    private func exerciseNativeScrolling(_ app: XCUIApplication, conversationIDs: [String]) throws {
        let transcript = app.scrollViews["conversation.transcript"]
        let composer = app.descendants(matching: .any)["conversation.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Synthetic composer draft", "The active page should expose its retained draft.")
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
        let restoredTranscript = app.scrollViews["conversation.transcript"]
        let restored = try visibleUserMessage(in: restoredTranscript, matching: scrolled.text)
        XCTAssertEqual(restored.text, scrolled.text)
        XCTAssertEqual(restored.y, scrolled.y, accuracy: 2)
        XCTAssertEqual(composer.value as? String, "Synthetic composer draft", "The draft must survive returning from another history page.")

        try exerciseJumpButton(app)

        let formalRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation.row."))
        let formalRowCount = formalRows.count
        let newConversation = app.buttons["sidebar.newConversation"]
        XCTAssertTrue(newConversation.waitForExistence(timeout: 5))
        newConversation.click()
        let unsentDraft = "UI draft survives history navigation"
        try enter(unsentDraft, in: composer)
        first.click()
        newConversation.click()
        XCTAssertEqual(composer.value as? String, unsentDraft, "Returning to the unique draft must preserve its text.")
        newConversation.click()
        XCTAssertEqual(composer.value as? String, unsentDraft, "Repeated New Conversation must not clear the existing draft.")
        XCTAssertEqual(formalRows.count, formalRowCount, "The unsent draft must not create a persisted sidebar row.")
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

    private func exerciseJumpButton(_ app: XCUIApplication) throws {
        let jump = app.buttons["conversation.jumpToLatest"]
        try require(jump.waitForExistence(timeout: 5), "The floating action should be visible while reading history.")
        let composer = app.descendants(matching: .any)["conversation.composer"]
        XCTAssertEqual(jump.frame.width, 36, accuracy: 1)
        XCTAssertEqual(jump.frame.height, jump.frame.width, accuracy: 1)
        XCTAssertEqual(jump.frame.midX, composer.frame.midX, accuracy: 1)
        XCTAssertLessThan(jump.frame.maxY, composer.frame.minY)

        let transcript = app.scrollViews["conversation.transcript"]
        for delta in [80.0, -60.0, 100.0, -80.0] {
            transcript.scroll(byDeltaX: 0, deltaY: delta)
            XCTAssertTrue(jump.isHittable, "A scroll burst must not hide the history navigation action.")
        }
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Centered glass jump action while reading history"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // The native geometry monitor should already be idle before activation.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        jump.click()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: jump)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(jump.exists, "The action must remain hidden once the explicit jump settles.")
        let scroller = transcript.scrollBars.firstMatch
        let reachedBottom = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let value = (scroller.value as? NSNumber)?.doubleValue ?? Double(scroller.value as? String ?? "") ?? 0
                return value >= 0.999
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reachedBottom], timeout: 5), .completed, "The button must move the native viewport to the latest content after scrolling becomes idle.")
        transcript.scroll(byDeltaX: 0, deltaY: 500)
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "Scrolling back into history should reveal the action again.")
    }

    private func enter(_ text: String, in composer: XCUIElement) throws {
        composer.click()
        // Deliver committed fixture text independently of the current input method.
        let pasteboard = NSPasteboard.general
        let previous = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            if !previous.isEmpty { pasteboard.writeObjects(previous) }
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        composer.typeKey("a", modifierFlags: .command)
        composer.typeKey("v", modifierFlags: .command)
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: composer)
        try require(XCTWaiter.wait(for: [inserted], timeout: 5) == .completed, "The composer did not receive the exact fixture text before navigation.")
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "MiraUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
