import AppKit
import XCTest

/// Exercises memory management with the offline demo library and authored synthetic content only.
@MainActor
final class MemoryManagementUITests: XCTestCase {
    func testMemoryManagementEnglishLight() throws {
        try exercise(language: "en", appearance: "light")
    }

    func testMemoryManagementChineseDarkAtMinimumSize() throws {
        try exercise(language: "zh-CN", appearance: "dark")
    }

    private func exercise(language: String, appearance: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mira-MemoryManagement-UI-\(UUID())", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo", "--data-directory", directory.path,
            "-app.language", language, "-app.displayMode", appearance, "-AppleLanguages", "(en)",
            "-NSAutomaticTextCompletionEnabled", "NO", "-NSAutomaticSpellingCorrectionEnabled", "NO"
        ]
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
        let window = app.windows.firstMatch
        try require(window.waitForExistence(timeout: 15), "Mira did not open a window.")
        let composer = app.descendants(matching: .any)["conversation.composer"]
        try require(composer.waitForExistence(timeout: 10), "The conversation composer is unavailable.")
        if language == "en" {
            app.menuBars.menuBarItems["Window"].click()
            app.menuItems["Fill"].click()
            try require(waitUntil(timeout: 5) { window.frame.width >= 1100 && window.frame.height >= 740 },
                        "The English fixture requires a wide window for simultaneous list and detail.")
        } else {
            // Native window/sheet layout may exceed the content minimum; locally it settles at 881 x 672.
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -2, dy: -2))
            let target = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 848, dy: 618))
            corner.press(forDuration: 0.1, thenDragTo: target)
            XCTAssertGreaterThanOrEqual(window.frame.width, 850)
            XCTAssertLessThanOrEqual(window.frame.width, 900)
            XCTAssertGreaterThanOrEqual(window.frame.height, 620)
            XCTAssertLessThanOrEqual(window.frame.height, 700)
        }

        let draft = "Keep this unsent draft while managing synthetic memories."
        try paste(draft, into: composer)

        let memoriesNavigation = app.buttons["sidebar.memories"]
        try require(memoriesNavigation.waitForExistence(timeout: 10), "Memory navigation is unavailable.")
        memoriesNavigation.click()
        try require(app.descendants(matching: .any)["memory.management"].waitForExistence(timeout: 10),
                    "The memory management screen did not open.")
        capture(app, name: "Memory list - \(language) - \(appearance)")

        app.buttons["memory.add"].click()
        let content = app.descendants(matching: .any)["memory.editor.content"]
        try require(content.waitForExistence(timeout: 10), "The memory editor did not open.")
        let remoteUse = app.descendants(matching: .any)["memory.editor.remoteUse"]
        try require(remoteUse.waitForExistence(timeout: 5), "The remote-use choice is unavailable.")
        let remoteValue = String(describing: remoteUse.value ?? "")
        XCTAssertTrue(["0", "false", "off"].contains(remoteValue.lowercased()),
                      "A manually added memory must default to local-only, got \(remoteValue).")
        let original = "I prefer tea in the morning."
        try paste(original, into: content)
        capture(app, name: "Memory editor - \(language) - \(appearance)")
        app.buttons["memory.editor.save"].click()
        let originalRow = try waitForRow(containing: original, in: app, timeout: 15)
        originalRow.click()
        try require(app.descendants(matching: .any)["memory.content"].waitForExistence(timeout: 10),
                    "Selecting the row did not show its detail.")
        XCTAssertTrue(label(of: app.descendants(matching: .any)["memory.content"]).contains(original))
        capture(app, name: "Memory detail - \(language) - \(appearance)")

        app.buttons["memory.edit"].click()
        try require(content.waitForExistence(timeout: 5), "The wording editor did not open.")
        let edited = "I prefer green tea in the morning."
        try paste(edited, into: content)
        capture(app, name: "Edit memory wording - \(language) - \(appearance)")
        app.buttons["memory.editor.save"].click()
        try require(waitUntil(timeout: 15) {
            label(of: app.descendants(matching: .any)["memory.content"]).contains(edited)
        }, "Editing wording did not update the selected detail.")

        app.buttons["memory.replace"].click()
        try require(content.waitForExistence(timeout: 5), "The replacement editor did not open.")
        let replacement = "I now prefer coffee in the morning."
        try paste(replacement, into: content)
        app.buttons["memory.editor.save"].click()
        let replacementRow = try waitForRow(containing: "coffee", in: app, timeout: 15)
        replacementRow.click()
        try require(waitUntil(timeout: 10) {
            label(of: app.descendants(matching: .any)["memory.content"]).contains(replacement)
        }, "The replacement memory did not become current.")

        if app.buttons["memory.back"].exists { app.buttons["memory.back"].click() }
        let search = app.textFields["memory.search"]
        try require(search.waitForExistence(timeout: 5), "Memory search is unavailable.")
        try paste("coffee", into: search)
        try require(waitUntil(timeout: 10) {
            matchingRow(containing: replacement, in: app) != nil
        }, "Search did not filter to the replacement memory.")
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        try require(waitUntil(timeout: 10) {
            matchingRow(containing: replacement, in: app) != nil
        }, "Clearing search did not restore the memory list.")

        let history = localized(language, english: "History", chinese: "历史记录") // i18n-fixture: Assert supported Chinese UI copy.
        let historyButton = app.radioButtons[history]
        try require(historyButton.waitForExistence(timeout: 5), "The memory history section is unavailable.")
        historyButton.click()
        let historicalRow = try waitForRow(containing: edited, in: app, timeout: 10)
        try require(historicalRow.waitForExistence(timeout: 10), "The replaced memory did not appear in history.")
        historicalRow.click()
        try require(waitUntil(timeout: 10) {
            label(of: app.descendants(matching: .any)["memory.content"]).contains(edited)
        }, "History did not preserve the wording that was current before replacement.")

        app.scrollViews["memory.detail"].scroll(byDeltaX: 0, deltaY: -1200)
        app.buttons["memory.forget"].click()
        let confirmForget = app.buttons["memory.forget.confirm"]
        try require(confirmForget.waitForExistence(timeout: 5), "The forget confirmation did not appear.")
        capture(app, name: "Forget confirmation - \(language) - \(appearance)")
        confirmForget.click()
        try require(waitUntil(timeout: 20) {
            matchingRow(containing: localized(language, english: "Forgotten memory", chinese: "已遗忘的记忆"), in: app) != nil // i18n-fixture: Assert supported Chinese UI copy.
        }, "Forgetting did not replace the historical row with its body-free tombstone.")
        let tombstoneRow = try waitForRow(
            containing: localized(language, english: "Forgotten memory", chinese: "已遗忘的记忆"), in: app, timeout: 5) // i18n-fixture: Assert supported Chinese UI copy.
        tombstoneRow.click()
        let forgottenDetail = app.descendants(matching: .any)["memory.detail"]
        try require(waitUntil(timeout: 10) {
            label(of: forgottenDetail).contains(localized(language,
                english: "The content and source excerpts have been cleared.",
                chinese: "内容和来源摘录已清除。")) // i18n-fixture: Assert supported Chinese UI copy.
        }, "The forgotten detail did not explain that its content was cleared.")
        let detailText = label(of: forgottenDetail)
        XCTAssertFalse(detailText.contains(original))
        XCTAssertFalse(detailText.contains(edited))
        capture(app, name: "Forgotten tombstone - \(language) - \(appearance)")

        let newConversation = app.buttons["conversation.new"]
        try require(newConversation.waitForExistence(timeout: 5), "New conversation is unavailable from memory management.")
        newConversation.click()
        try require(waitUntil(timeout: 10) { (composer.value as? String) == draft },
                    "Switching through memory management and New Conversation lost the unsent draft.")
        XCTAssertTrue(app.buttons["conversation.send"].exists,
                      "Returning to the conversation must leave the draft available for explicit submission.")
    }

    private func waitForRow(containing term: String, in app: XCUIApplication,
                            timeout: TimeInterval) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let match = matchingRow(containing: term, in: app)
            if let match { return match }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let listAX = app.descendants(matching: .any)["memory.list"].debugDescription
        throw NSError(domain: "MiraUITests", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "No memory row contained \(term). List AX: \(listAX)"])
    }

    private func matchingRow(containing text: String, in app: XCUIApplication) -> XCUIElement? {
        let rows = app.descendants(matching: .any)["memory.list"].descendants(matching: .any)
        return rows.allElementsBoundByIndex.first { row in
            [row.label, row.value as? String ?? "", row.descendants(matching: .any).allElementsBoundByIndex
                .map { "\($0.label) \(String(describing: $0.value ?? ""))" }.joined(separator: " ")]
                .joined(separator: " ").localizedCaseInsensitiveContains(text)
        }
    }

    private func paste(_ text: String, into element: XCUIElement) throws {
        element.click()
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
        // Keep keyboard events on the focused app while AppKit rebuilds text selection accessibility.
        let app = XCUIApplication()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 5) { (element.value as? String) == text },
                      "The native text control did not receive the exact synthetic text.")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func label(of element: XCUIElement) -> String {
        [element.label, element.value as? String ?? "", element.descendants(matching: .any).allElementsBoundByIndex
            .map { "\($0.label) \($0.value as? String ?? "")" }.joined(separator: " ")]
            .joined(separator: " ")
    }

    // i18n-fixture: Expected labels for the two supported UI languages.
    private func localized(_ language: String, english: String, chinese: String) -> String {
        language == "en" ? english : chinese
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "MiraUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
