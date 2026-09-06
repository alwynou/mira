import AppKit
import XCTest

/// Native task interactions use the explicitly selected offline demo provider.
/// The task path is manual and must not open a model or notification permission prompt.
@MainActor
final class TaskUITests: XCTestCase {
    func testManualTaskEditCompletionReopenAndRelaunch() throws {
        try withApplication { app in
            try require(app.buttons["sidebar.tasks"].waitForExistence(timeout: 10), "The Tasks sidebar entry is unavailable.")
            app.buttons["sidebar.tasks"].click()
            try require(app.buttons["tasks.new"].waitForExistence(timeout: 10), "The Tasks sheet did not open.")

            app.buttons["tasks.new"].click()
            let titleField = app.descendants(matching: .any)["tasks.title"]
            try require(titleField.waitForExistence(timeout: 10), "The task editor did not open.")
            try replaceText(in: titleField, with: "Review project brief")
            app.buttons["tasks.save"].click()
            try require(taskRow(app, title: "Review project brief").waitForExistence(timeout: 10), "The new task did not appear in the list.")

            taskRow(app, title: "Review project brief").click()
            try require(app.buttons["tasks.edit"].waitForExistence(timeout: 10), "The saved task could not be selected.")
            app.buttons["tasks.edit"].click()
            try require(titleField.waitForExistence(timeout: 10), "The task editor did not reopen.")
            try replaceText(in: titleField, with: "Review revised brief")
            app.buttons["tasks.save"].click()
            try require(taskRow(app, title: "Review revised brief").waitForExistence(timeout: 10), "The edited task did not refresh.")

            taskRow(app, title: "Review revised brief").click()
            try require(app.buttons["tasks.complete"].waitForExistence(timeout: 10), "The task completion action is unavailable.")
            app.buttons["tasks.complete"].click()
            try require(app.descendants(matching: .any)["tasks.includeCompleted"].waitForExistence(timeout: 10), "The completed-task filter is unavailable.")
            app.descendants(matching: .any)["tasks.includeCompleted"].click()
            try require(taskRow(app, title: "Review revised brief").waitForExistence(timeout: 10), "The completed task did not appear after enabling completed tasks.")

            taskRow(app, title: "Review revised brief").click()
            try require(app.buttons["tasks.reopen"].waitForExistence(timeout: 10), "The completed task did not expose Reopen.")
            app.buttons["tasks.reopen"].click()
            try require(app.buttons["tasks.complete"].waitForExistence(timeout: 10), "The reopened task did not return to an open state.")

            app.typeKey(.escape, modifierFlags: [])
            try require(app.buttons["sidebar.tasks"].waitForExistence(timeout: 10), "The task sheet did not close.")
            app.terminate()
            try launchWindow(app)
            app.buttons["sidebar.tasks"].click()
            try require(app.buttons["tasks.new"].waitForExistence(timeout: 10), "Tasks did not reopen after relaunch.")
            try require(taskRow(app, title: "Review revised brief").waitForExistence(timeout: 10), "The task was not persisted after relaunch.")
        }
    }

    private func taskRow(_ app: XCUIApplication, title: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value CONTAINS %@", "tasks.item.", title)).firstMatch
    }

    private func withApplication(body: (XCUIApplication) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-Task-UI-\(UUID())", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--data-directory", directory.path, "-app.language", "en", "-AppleLanguages", "(en)"]
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        try launchWindow(app)
        try require(app.buttons["sidebar.tasks"].waitForExistence(timeout: 15), "Mira did not display its sidebar.")
        try body(app)
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

    private func replaceText(in element: XCUIElement, with value: String) throws {
        let pasteboard = NSPasteboard.general
        let previous = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer {
            pasteboard.clearContents()
            if !previous.isEmpty { pasteboard.writeObjects(previous) }
        }
        element.click()
        pasteboard.clearContents(); pasteboard.setString(value, forType: .string)
        element.typeKey("a", modifierFlags: .command)
        element.typeKey("v", modifierFlags: .command)
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        try require(XCTWaiter.wait(for: [inserted], timeout: 5) == .completed, "The task editor did not receive the exact fixture text.")
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "MiraUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
