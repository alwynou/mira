import AppKit
import XCTest

/// Native interaction checks use the explicitly selected offline demo provider.
/// They verify the UI/runtime boundary, not model memory intelligence.
@MainActor
final class EverydayConversationUITests: XCTestCase {
    func testEnglishConversationPersistsAfterRelaunch() throws {
        try exerciseConversation(language: "en", sendLabel: "Send")
    }

    func testChineseConversationPersistsAfterRelaunch() throws {
        try exerciseConversation(language: "zh-CN", sendLabel: "发送") // i18n-fixture: Assert the supported Chinese UI label using the same stable identifiers.
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

    private func withApplication(language: String, body: (XCUIApplication) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-UI-\(UUID())", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--data-directory", directory.path, "-app.language", language, "-AppleLanguages", "(en)"]
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
