import AppKit
import XCTest

/// Native interaction checks use the explicitly selected offline demo provider.
/// They verify the UI/runtime boundary, not model memory intelligence.
@MainActor
final class EverydayConversationUITests: XCTestCase {
    func testMathFallbackEnglishLight() throws {
        try exerciseMathFallback(language: "en", dark: false)
    }

    func testMathFallbackChineseDarkMinimumWindow() throws {
        try exerciseMathFallback(language: "zh-CN", dark: true)
    }

    private func exerciseMathFallback(language: String, dark: Bool) throws {
        try withApplication(language: language, extraArguments: ["-app.displayMode", dark ? "dark" : "light"]) { app in
            if dark {
                let window = app.windows.firstMatch
                let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                    .withOffset(CGVector(dx: -2, dy: -2))
                let target = window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: 848, dy: 618))
                corner.press(forDuration: 0.1, thenDragTo: target)
            }
            let source = #"Synthetic formulas: $\frac{a}{b}+x^2$; empty geometry: $\quad$; tail remains visible."#
            try enter(source, in: app)
            app.buttons["conversation.send"].click()
            let reply = app.staticTexts.matching(NSPredicate(
                format: "value CONTAINS %@ AND value CONTAINS %@",
                "Mira Local Demo", "Deterministic local streaming"
            )).firstMatch
            try require(reply.waitForExistence(timeout: 45), "The completed formula reply did not appear.")
            XCTAssertTrue((reply.value as? String)?.contains(source) == true)
            try require(app.buttons["conversation.send"].waitForExistence(timeout: 45), "The formula reply did not finish.")
            XCTAssertEqual(app.state, .runningForeground)
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = "Math fallback - \(language) - completed"
            attachment.lifetime = .keepAlways
            add(attachment)
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation.row."))
            try require(rows.firstMatch.waitForExistence(timeout: 10), "The formula conversation was not persisted.")
            let rowID = rows.firstMatch.identifier
            app.terminate()
            try launchWindow(app)
            try require(app.buttons[rowID].waitForExistence(timeout: 10), "The formula conversation identity was lost.")
            app.buttons[rowID].click()
            try require(app.descendants(matching: .any)["conversation.transcript"].waitForExistence(timeout: 10),
                        "The formula conversation did not reopen.")
            try require(reply.waitForExistence(timeout: 10), "The persisted formula reply did not reappear.")
            XCTAssertTrue((reply.value as? String)?.contains(source) == true)
            XCTAssertTrue(app.buttons["conversation.send"].exists)
        }
    }

    func testEnglishConversationPersistsAfterRelaunch() throws {
        try exerciseConversation(language: "en", sendLabel: "Send")
    }

    func testChineseConversationPersistsAfterRelaunch() throws {
        try exerciseConversation(language: "zh-CN", sendLabel: "发送") // i18n-fixture: Assert the supported Chinese UI label using the same stable identifiers.
    }

    func testDeferredNavigationPreservesConversationDraft() throws {
        try withApplication(language: "en") { app in
            let showSidebar = app.toolbars.buttons["Show Sidebar"]
            if showSidebar.exists { showSidebar.click() }
            let newConversation = app.buttons["conversation.new"]
            try require(newConversation.waitForExistence(timeout: 5), "The new conversation action is unavailable.")
            XCTAssertTrue(newConversation.isEnabled)
            newConversation.click()
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation.row."))
            try require(rows.firstMatch.waitForExistence(timeout: 10), "New conversation did not appear in the sidebar.")
            XCTAssertEqual(rows.count, 1)
            for identifier in ["conversation.new", "conversation.inspector", "conversation.knowledge"] {
                XCTAssertTrue(app.buttons[identifier].exists)
            }
            let draft = "Keep this unsent draft while selecting deferred navigation."
            try enter(draft, in: app)
            for identifier in ["sidebar.memories", "sidebar.knowledge", "sidebar.tasks", "conversation.knowledge"] {
                let entry = app.buttons[identifier]
                try require(entry.waitForExistence(timeout: 5), "A deferred navigation entry is missing: \(identifier).")
                entry.click()
                let composer = app.descendants(matching: .any)["conversation.composer"]
                XCTAssertTrue(composer.exists, "Deferred navigation must keep the conversation visible.")
                XCTAssertEqual(composer.value as? String, draft)
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(app.windows.count, 1)
                XCTAssertEqual(app.sheets.count, 0)
            }
        }
    }

    func testCancelLeavesComposerUsable() throws {
        try withApplication(language: "en") { app in
            let scenario = try scenario(language: "en")
            try enter(scenario.followUp, in: app)
            app.buttons["conversation.send"].click()
            let stop = app.buttons["conversation.stop"]
            try require(stop.waitForExistence(timeout: 10), "The stream did not expose its cancel control.")
            stop.click()
            try require(app.buttons["conversation.send"].waitForExistence(timeout: 10), "Cancellation did not restore the send control.")
            XCTAssertFalse(stop.exists)
            try enter(scenario.statement, in: app)
            XCTAssertTrue(app.buttons["conversation.send"].isEnabled)
            XCTAssertEqual(app.descendants(matching: .any)["conversation.composer"].value as? String, scenario.statement)
        }
    }

    private func exerciseConversation(language: String, sendLabel: String) throws {
        try withApplication(language: language) { app in
            let scenario = try scenario(language: language)
            XCTAssertEqual(app.buttons["conversation.send"].label, sendLabel)
            try enter(scenario.statement, in: app)
            app.buttons["conversation.send"].click()
            try require(app.buttons["conversation.stop"].waitForExistence(timeout: 10), "The conversation did not begin streaming.")
            try require(app.buttons["conversation.send"].waitForExistence(timeout: 45), "The offline reply did not finish.")
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation.row."))
            try require(rows.firstMatch.waitForExistence(timeout: 10), "No persisted conversation appeared in the sidebar.")
            XCTAssertEqual(rows.count, 1)
            let rowID = rows.firstMatch.identifier

            app.terminate()
            try launchWindow(app)
            try require(app.buttons[rowID].waitForExistence(timeout: 15), "Relaunch lost the conversation identity.")
            app.buttons[rowID].click()
            try require(app.staticTexts[scenario.statement].waitForExistence(timeout: 10), "Relaunch lost the exact user message.")
            try require(app.buttons["conversation.inspector"].waitForExistence(timeout: 10), "The execution inspector is unavailable.")
            XCTAssertTrue(app.buttons["conversation.inspector"].isEnabled)
            XCTAssertFalse(app.buttons["conversation.stop"].exists, "Reopening must not automatically repeat a completed request.")
            XCTAssertEqual(app.buttons["conversation.send"].label, sendLabel)
        }
    }

    private func withApplication(language: String, extraArguments: [String] = [], body: (XCUIApplication) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-UI-\(UUID())", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--data-directory", directory.path, "-app.language", language, "-AppleLanguages", "(en)"] + extraArguments
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            try launchWindow(app)
            try require(app.descendants(matching: .any)["conversation.composer"].waitForExistence(timeout: 15), "Mira did not display its composer.")
            try body(app)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Everyday conversation - \(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Failed native workflow - \(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
            throw error
        }
    }

    private func launchWindow(_ app: XCUIApplication) throws {
        app.launch()
        app.activate()
        // A macOS app can be running with every window closed. Exercise its
        // standard New Window command rather than relying on restoration state.
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.menuBars.menuBarItems["File"].click()
            app.menuItems["New Window"].click()
        }
        try require(app.windows.firstMatch.waitForExistence(timeout: 10), "Mira did not open a window.")
    }

    private func enter(_ text: String, in app: XCUIApplication) throws {
        let input = app.descendants(matching: .any)["conversation.composer"]
        input.click()
        // Paste supports arbitrary authored Unicode independently of the active
        // keyboard layout. Restore all clipboard representations after delivery.
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
        input.typeKey("a", modifierFlags: .command)
        input.typeKey("v", modifierFlags: .command)
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: input)
        try require(XCTWaiter.wait(for: [inserted], timeout: 5) == .completed, "The composer did not receive the exact fixture text.")
        try require(app.buttons["conversation.send"].isEnabled, "The composer did not enable sending.")
    }

    private func scenario(language: String) throws -> Scenario {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "scenarios", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        return try XCTUnwrap(corpus.scenarios.first { $0.language == language && $0.expectation == "active" })
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "MiraUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private struct Corpus: Decodable { let scenarios: [Scenario] }
    private struct Scenario: Decodable {
        let language: String
        let statement: String
        let followUp: String
        let expectation: String
    }
}
