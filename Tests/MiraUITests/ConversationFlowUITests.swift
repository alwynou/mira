import AppKit
import XCTest

/// Deterministic native checks for activity and process presentation using
/// local model output and synthetic read-only tool results.
@MainActor
final class ConversationFlowUITests: XCTestCase {
    func testModelSelectionPolicyEnglishLight() throws {
        try exerciseModelSelection(language: "en", dark: false, extended: true)
    }

    func testModelSelectionGroupsChineseDark() throws {
        try exerciseModelSelection(language: "zh-CN", dark: true, extended: false)
    }

    func testCompactModelMenuEnglishLight() throws {
        try exerciseModelSelection(language: "en", dark: false, extended: false, captureOnly: true)
    }

    func testCompactModelMenuChineseDark() throws {
        try exerciseModelSelection(language: "zh-CN", dark: true, extended: false, captureOnly: true)
    }

    private func exerciseModelSelection(language: String, dark: Bool, extended: Bool, captureOnly: Bool = false) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-Model-Selection-\(UUID())")
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--verify-model-selection", "--data-directory", directory.path,
            "-app.language", language, "-app.displayMode", dark ? "dark" : "light", "-AppleLanguages", "(en)"]
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        try launchWindow(app)
        let picker = app.descendants(matching: .any)["conversation.modelPicker"]
        try require(picker.waitForExistence(timeout: 15), "The model selector is missing.")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 848, dy: 670)))
        func expectModel(_ name: String) throws {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", name), object: picker)
            try require(XCTWaiter.wait(for: [expectation], timeout: 10) == .completed,
                        "The selected model label should be \(name).")
        }
        func choose(_ suffix: String) throws {
            picker.click()
            let option = app.menuItems["conversation.modelOption.0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E" + suffix]
            try require(option.waitForExistence(timeout: 5), "The model option is missing.")
            option.click()
        }
        func setDefault(_ title: String) throws {
            app.buttons["sidebar.settings"].click()
            let settings = app.windows["mira.settings"]
            try require(settings.waitForExistence(timeout: 10), "The settings window is missing.")
            settings.descendants(matching: .any)["settings.category.models"].click()
            let menu = settings.popUpButtons["settings.models.default.mira.conversation"]
            try require(menu.waitForExistence(timeout: 10), "The conversation default is missing.")
            menu.click()
            let option = app.menuItems[title]
            try require(option.waitForExistence(timeout: 5), "The default policy option is missing.")
            option.click()
            let save = settings.buttons[language == "zh-CN" ? "保存" : "Save"] // i18n-fixture: Localized save action.
            try require(save.waitForExistence(timeout: 5), "The default policy has no save action.")
            save.click()
            let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)
            try require(XCTWaiter.wait(for: [saved], timeout: 10) == .completed, "The default policy was not saved.")
            let capture = XCTAttachment(screenshot: settings.screenshot())
            capture.name = "Model defaults - \(language)"
            capture.lifetime = .keepAlways
            add(capture)
            settings.buttons[XCUIIdentifierCloseWindow].click()
        }
        try expectModel("Mira Local Demo")
        picker.click()
        try require(app.menuItems["conversation.modelOption.0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E212"].waitForExistence(timeout: 5),
                    "The second provider model is missing.")
        XCTAssertTrue(app.menuItems["Demo Provider B"].exists)
        XCTAssertEqual(app.menuItems.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation.modelOption.")).count, 3)
        // Native menus can extend beyond the window; capture the screen to include every menu row.
        let menuCapture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        menuCapture.name = "Model provider groups - \(language)"
        menuCapture.lifetime = .keepAlways
        add(menuCapture)
        app.typeKey(.escape, modifierFlags: [])
        if captureOnly { return }
        try choose("212")
        try expectModel("Demo Fast")
        app.buttons["sidebar.newConversation"].click()
        try expectModel("Mira Local Demo")
        let following = language == "zh-CN" ? "跟随上一个选择模型" : "Follow last selected model" // i18n-fixture: Localized model-default policy.
        try setDefault(following)
        app.buttons["sidebar.newConversation"].click()
        try expectModel("Demo Fast")
        try choose("211")
        app.buttons["sidebar.newConversation"].click()
        try expectModel("Demo Balanced")
        if extended {
            app.terminate()
            try launchWindow(app)
            try expectModel("Demo Balanced")
            try setDefault("Demo Fast · Demo Provider B")
            app.buttons["sidebar.newConversation"].click()
            try expectModel("Demo Fast")
            try choose("211")
            try expectModel("Demo Balanced")
            app.buttons["sidebar.newConversation"].click()
            try expectModel("Demo Fast")
        }
        capture(app, name: "Resolved model name - \(language)")
    }

    func testModelInformationEnglishLight() throws {
        try exerciseModelInformation(language: "en", dark: false)
    }

    func testModelInformationChineseDark() throws {
        try exerciseModelInformation(language: "zh-CN", dark: true)
    }

    private func exerciseModelInformation(language: String, dark: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-Model-Information-\(UUID())")
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--verify-model-information", "--data-directory", directory.path,
            "-app.language", language, "-app.displayMode", dark ? "dark" : "light", "-AppleLanguages", "(en)"]
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        try launchWindow(app)
        let settingsButton = app.buttons["sidebar.settings"]
        try require(settingsButton.waitForExistence(timeout: 10), "The settings action is missing.")
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["mira.settings"]
        try require(settings.waitForExistence(timeout: 10), "The settings window is missing.")
        settings.descendants(matching: .any)["settings.category.providers"].click()
        let provider = settings.buttons["settings.provider.0D8F40B7-1A68-4E0F-9A89-0E8FD8B2E220"]
        try require(provider.waitForExistence(timeout: 10), "The synthetic provider is missing.")
        provider.click()
        let source = settings.links.matching(NSPredicate(format: "label CONTAINS %@", "2026-09-14")).firstMatch
        try require(source.waitForExistence(timeout: 10), "The official pricing source is missing.")
        let price = settings.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "0.15")).firstMatch
        try require(price.waitForExistence(timeout: 10), "The input price range is missing.")
        settings.scrollViews["settings.providers.page"].scroll(byDeltaX: 0, deltaY: -440)
        let pro = settings.staticTexts["deepseek-v4-pro"]
        try require(pro.waitForExistence(timeout: 5), "The text-only model is missing.")
        let attachment = XCTAttachment(screenshot: settings.screenshot())
        attachment.name = "Model information - \(language)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCompletionKeepsRenderedAnswerEnglishLight() throws {
        try exerciseCompletion(language: "en", dark: false)
    }

    func testCompletionKeepsRenderedAnswerChineseDark() throws {
        try exerciseCompletion(language: "zh-CN", dark: true)
    }

    func testCappedCodeScrollingEnglishLight() throws {
        try exerciseCodeScrolling(language: "en", dark: false)
    }

    func testCappedCodeScrollingChineseDarkMinimumWindow() throws {
        try exerciseCodeScrolling(language: "zh-CN", dark: true)
    }

    private func exerciseCodeScrolling(language: String, dark: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mira-Code-Scrolling-\(UUID())", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo", "--verify-code-scrolling", "--data-directory", directory.path,
            "-app.language", language, "-app.displayMode", dark ? "dark" : "light",
            "-AppleLanguages", "(en)"
        ]
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        try launchWindow(app)
        try require(app.descendants(matching: .any)["conversation.composer"].waitForExistence(timeout: 15),
                    "Mira did not display its composer.")
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        let target = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 848, dy: 618))
        corner.press(forDuration: 0.1, thenDragTo: target)
        XCTAssertEqual(window.frame.width, 850, accuracy: 20,
                       "The code scrolling fixture must run at the narrow acceptance width.")

        try send("Render the capped code scrolling fixture", in: app)
        let activity = try latestActivity(in: app, timeout: 20)
        try waitForLabel(activity, containing: stateLabel(language: language, phase: .completed), timeout: 30)
        try require(app.buttons["conversation.send"].waitForExistence(timeout: 5),
                    "The completed fixture did not restore send.")

        let transcript = app.scrollViews["conversation.transcript"]
        try require(transcript.waitForExistence(timeout: 5), "The conversation transcript is missing.")
        transcript.scroll(byDeltaX: 0, deltaY: -2200)

        let codeBlocks = app.scrollViews.matching(identifier: "conversation.codeBlock")
        try require(codeBlocks.count >= 2, "The short and long code block scroll views are missing.")
        let codeBlock = codeBlocks.element(boundBy: codeBlocks.count - 1)
        try require(codeBlock.waitForExistence(timeout: 10), "The final code block scroll view is missing.")
        let marker = codeBlock.descendants(matching: .staticText).matching(
            NSPredicate(format: "value CONTAINS %@", "CODE BLOCK END")).firstMatch
        try require(marker.waitForExistence(timeout: 10), "The final code block marker is missing.")
        let longLine = codeBlock.descendants(matching: .any).matching(
            NSPredicate(format: "value CONTAINS %@", "fixtureLine45")).firstMatch
        try require(longLine.waitForExistence(timeout: 10), "The long code line is missing from the code document.")

        let scrollBars = codeBlock.scrollBars.allElementsBoundByIndex
        let verticalScroller = scrollBars.first { $0.frame.height > $0.frame.width }
        let horizontalScroller = scrollBars.first { $0.frame.width >= $0.frame.height }
        try require(verticalScroller != nil && horizontalScroller != nil,
                    "The final code document must expose native vertical and horizontal scrollers.")
        func normalizedValue(_ scroller: XCUIElement) -> Double {
            if let number = scroller.value as? NSNumber { return number.doubleValue }
            let raw = scroller.value as? String ?? ""
            let number = Double(raw.replacingOccurrences(of: "%", with: "")) ?? 0
            return raw.contains("%") ? number / 100 : number
        }
        codeBlock.scroll(byDeltaX: 0, deltaY: 2400)
        let verticalBefore = normalizedValue(verticalScroller!)
        codeBlock.scroll(byDeltaX: 0, deltaY: -2400)
        let verticalAfter = normalizedValue(verticalScroller!)
        XCTAssertGreaterThan(verticalAfter, verticalBefore,
                             "The final code document must move vertically through its long content.")
        XCTAssertEqual(verticalAfter, 1, accuracy: 0.01,
                       "The code viewport must reach the final line, not merely change offset.")

        let horizontalBefore = normalizedValue(horizontalScroller!)
        codeBlock.scroll(byDeltaX: -640, deltaY: 0)
        let horizontalAfter = normalizedValue(horizontalScroller!)
        XCTAssertGreaterThan(horizontalAfter, horizontalBefore,
                             "The long code line must respond to horizontal scrolling.")
        codeBlock.scroll(byDeltaX: 640, deltaY: 0)
        XCTAssertLessThanOrEqual(codeBlock.frame.height, 320)
        capture(app, name: "Capped code scrolling - \(language) - final marker")
    }

    private func exerciseCompletion(language: String, dark: Bool) throws {
        try withApplication(language: language, dark: dark) { app in
            try send("Keep the answer visible through completion", in: app)
            let activity = app.buttons["conversation.activity"]
            let answer = app.descendants(matching: .staticText).matching(
                NSPredicate(format: "value BEGINSWITH %@", "I reviewed your request")).firstMatch
            try require(answer.waitForExistence(timeout: 10), "The streamed answer did not appear.")
            let origin = answer.frame.origin
            capture(app, name: "Completion continuity - \(language) - streaming")
            let deadline = Date().addingTimeInterval(12)
            var settledSamples = 0
            var settledOrigin: CGPoint?
            repeat {
                XCTAssertTrue(answer.exists, "The answer disappeared during settlement.")
                XCTAssertEqual(answer.frame.minX, origin.x, accuracy: 1)
                if activity.exists && activity.label == stateLabel(language: language, phase: .completed) {
                    // Completion folds the process above the answer. Its body
                    // remains mounted and must stay stable once that fold settles.
                    if let settledOrigin {
                        XCTAssertEqual(answer.frame.minY, settledOrigin.y, accuracy: 1)
                    } else { settledOrigin = answer.frame.origin }
                    settledSamples += 1
                }
            } while settledSamples < 4 && Date() < deadline
            XCTAssertEqual(settledSamples, 4, "Completion never settled with the answer visible.")
            capture(app, name: "Completion continuity - \(language) - completed")
        }
    }
    func testConversationActivityEnglishLight() throws {
        try exerciseFlow(language: "en", dark: false)
    }

    func testConversationActivityChineseDarkMinimumWindow() throws {
        try exerciseFlow(language: "zh-CN", dark: true)
    }

    func testConversationActivityCancelThenContinue() throws {
        try withApplication(language: "en", dark: false) { app in
            try send("Stop this response after thinking", in: app)
            let answer = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "I reviewed your request")).firstMatch
            try require(answer.waitForExistence(timeout: 10), "The streamed answer did not appear.")
            app.buttons["conversation.stop"].click()
            try require(app.buttons["conversation.send"].waitForExistence(timeout: 10), "Cancellation did not restore send.")
            try send("Continue with a short answer", in: app)
            let latestActivity = try latestActivity(in: app, timeout: 20, minimumCount: 2)
            try waitForLabel(latestActivity, containing: stateLabel(language: "en", phase: .completed), timeout: 15)
            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "Conversation flow - cancelled and continued"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    func testMultiroundProcessEnglishLightReopensInOrder() throws {
        try exerciseMultiround(language: "en", dark: false)
    }

    func testMultiroundProcessChineseDarkMinimumWindowReopensInOrder() throws {
        try exerciseMultiround(language: "zh-CN", dark: true)
    }

    func testToolPresentationEnglishLight() throws {
        try exerciseToolPresentation(language: "en", dark: false)
    }

    func testToolPresentationChineseDark() throws {
        try exerciseToolPresentation(language: "zh-CN", dark: true)
    }

    private func exerciseToolPresentation(language: String, dark: Bool) throws {
        try withMultiroundApplication(language: language, dark: dark, presentation: true) { app in
            try send("Inspect the synthetic tool presentation", in: app)
            let activity = try latestActivity(in: app, timeout: 20)
            try waitForLabel(activity, containing: stateLabel(language: language, phase: .completed), timeout: 20)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: activity)
            try require(XCTWaiter.wait(for: [enabled], timeout: 5) == .completed,
                        "The completed process did not become expandable.")
            activity.click()
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation.process."))
            let reasoning = rows.firstMatch
            app.buttons["sidebar.newConversation"].hover()
            capture(app, name: "Tool presentation - \(language) - idle")
            reasoning.hover()
            capture(app, name: "Tool presentation - \(language) - overflow hover")
            reasoning.click()
            XCTAssertEqual(reasoning.value as? Int, 1)
            reasoning.hover()
            capture(app, name: "Tool presentation - \(language) - expanded hover")
            reasoning.click()
            let failed = rows.matching(NSPredicate(format: "label CONTAINS %@", language == "zh-CN" ? "失败" : "Failed")).firstMatch // i18n-fixture: Localized tool status.
            try require(failed.waitForExistence(timeout: 5), "The failed tool row is missing.")
            failed.hover()
            capture(app, name: "Tool presentation - \(language) - failed hover")
            failed.click()
            XCTAssertEqual(failed.value as? Int, 1)
            capture(app, name: "Tool presentation - \(language) - failed expanded")
            failed.click()
            let succeeded = rows.matching(NSPredicate(format: "label CONTAINS %@", language == "zh-CN" ? "完成" : "Completed")).firstMatch // i18n-fixture: Localized tool status.
            try require(succeeded.waitForExistence(timeout: 5), "The successful tool row is missing.")
            succeeded.click()
            let output = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Second source result: beta")).firstMatch
            try require(output.waitForExistence(timeout: 5), "The tool result is missing.")
            XCTAssertFalse((output.value as? String ?? "").contains("\n"))
            let json = app.staticTexts.matching(NSPredicate(format: "value == %@", #"{"source":"second"}"#)).firstMatch
            XCTAssertTrue(json.exists)
            succeeded.hover()
            capture(app, name: "Tool presentation - \(language) - compact JSON")
        }
    }

    private func exerciseMultiround(language: String, dark: Bool) throws {
        try withMultiroundApplication(language: language, dark: dark) { app in
            try send("Inspect both deterministic sources", in: app)
            let reasoning = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation.process.")).firstMatch
            try require(reasoning.waitForExistence(timeout: 4), "The initial reasoning row did not appear.")
            XCTAssertFalse(app.buttons["conversation.activity"].exists, "Running reasoning must not have a duplicate process header.")
            capture(app, name: "Process refinement - \(language) - initial thinking")
            reasoning.click()
            XCTAssertFalse(reasoning.title.contains("First round reasoning"), "Expanded reasoning must hide its summary.")
            capture(app, name: "Process refinement - \(language) - thinking expanded")
            let activity = try latestActivity(in: app, timeout: 10)
            try waitForLabel(activity, containing: stateLabel(language: language, phase: .completed), timeout: 20)
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation.process.")).count, 0,
                           "Completed reasoning, including the final round, must be inside the collapsed process.")
            capture(app, name: "Multiround process - \(language) - collapsed")
            activity.click()
            expandProcessRows(in: app)
            try assertMultiroundTranscript(in: app)
            capture(app, name: "Multiround process - \(language) - expanded")
            app.scrollViews["conversation.transcript"].scroll(byDeltaX: 0, deltaY: -600)
            capture(app, name: "Multiround process - \(language) - final round")

            app.terminate()
            try launchWindow(app)
            try require(app.descendants(matching: .any)["conversation.composer"].waitForExistence(timeout: 15),
                        "Mira did not restore the composer after reopening.")
            let conversation = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation.row.")).firstMatch
            try require(conversation.waitForExistence(timeout: 10), "The saved conversation did not reopen.")
            conversation.click()
            let reopenedActivity = try latestActivity(in: app, timeout: 10)
            reopenedActivity.click()
            expandProcessRows(in: app)
            try assertMultiroundTranscript(in: app)
            capture(app, name: "Multiround process - \(language) - reopened")
        }
    }

    private func withMultiroundApplication(language: String, dark: Bool, presentation: Bool = false,
                                           body: (XCUIApplication) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mira-Multiround-Flow-\(UUID())", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo", "--verify-multiround-flow", "--data-directory", directory.path,
            "-app.language", language, "-app.displayMode", dark ? "dark" : "light",
            "-AppleLanguages", "(en)"
        ]
        if presentation { app.launchArguments.append("--verify-tool-presentation") }
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        try launchWindow(app)
        try require(app.descendants(matching: .any)["conversation.composer"].waitForExistence(timeout: 15),
                    "Mira did not display its composer.")
        let title = app.descendants(matching: .any)["conversation.title"]
        try require(title.waitForExistence(timeout: 10), "The conversation title accessibility element is missing.")
        let sidebarAnchor = app.buttons["sidebar.newConversation"]
        if !sidebarAnchor.exists || title.frame.minX < sidebarAnchor.frame.maxX {
            app.toolbars.buttons.element(boundBy: 0).click()
        }
        try require(sidebarAnchor.waitForExistence(timeout: 10), "The sidebar anchor is missing.")

        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        let target = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 848, dy: 618))
        corner.press(forDuration: 0.1, thenDragTo: target)
        XCTAssertEqual(window.frame.width, 850, accuracy: 20,
                       "The multiround fixture must run at the narrow acceptance width.")
        try body(app)
    }

    private func expandProcessRows(in app: XCUIApplication) {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation.process."))
        // Expand lower rows first so growth does not push the next target below the composer.
        let ordered = rows.allElementsBoundByIndex.sorted { $0.frame.minY > $1.frame.minY }.map(\.identifier)
        for id in ordered {
            let row = app.buttons[id]
            if row.exists, (row.value as? Int) != 1 {
                row.click()
                XCTAssertEqual(row.value as? Int, 1, "The selected process block did not expand: \(id)")
            }
        }
    }

    private func assertMultiroundTranscript(in app: XCUIApplication) throws {
        let markers = [
            "First round reasoning",
            "I will inspect the first source.",
            #""source":"first""#,
            "First source result: alpha",
            "Second round reasoning",
            "I will inspect the second source.",
            #""source":"second""#,
            "Second source result: beta",
            "Final round reasoning",
            "Both sources agree: alpha and beta."
        ]
        var positions: [CGFloat] = []
        for marker in markers {
            let element = app.descendants(matching: .staticText).matching(
                NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
            try require(element.waitForExistence(timeout: 5), "The expanded process did not expose \(marker).")
            // A scrollable text field's AX frame follows its document offset.
            // Compare the section viewport when checking the outer timeline.
            let section = app.scrollViews.matching(identifier: "conversation.toolIO")
                .containing(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
            positions.append(section.exists ? section.frame.minY : element.frame.minY)
        }
        for index in 1..<positions.count {
            XCTAssertLessThanOrEqual(positions[index - 1], positions[index] + 2,
                "The multiround process is out of order: \(markers[index - 1]) before \(markers[index]).")
        }
    }

    private func exerciseFlow(language: String, dark: Bool) throws {
        try withApplication(language: language, dark: dark) { app in
            try send("Explain the latest activity state", in: app)
            let reasoning = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation.process.")).firstMatch
            try require(reasoning.waitForExistence(timeout: 4), "The reasoning disclosure did not appear.")
            capture(app, name: "Conversation flow - \(language) - thinking")
            reasoning.click()
            let answer = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "I reviewed your request")).firstMatch
            try require(answer.waitForExistence(timeout: 10), "The streamed answer did not appear.")
            capture(app, name: "Conversation flow - \(language) - expanded thinking")

            let activity = try latestActivity(in: app, timeout: 20)
            try waitForLabel(activity, containing: stateLabel(language: language, phase: .completed), timeout: 15)
            try require(app.buttons["conversation.send"].waitForExistence(timeout: 5), "The completed state did not restore send.")
            capture(app, name: "Conversation flow - \(language) - completed")
            let title = app.descendants(matching: .any)["conversation.title"]
            let sidebar = app.buttons["sidebar.newConversation"]
            XCTAssertEqual(title.value as? String, "Explain the latest activity state")
            XCTAssertLessThan(title.frame.minX - sidebar.frame.maxX, 40,
                              "The title must stay at the leading edge of the detail pane.")
            if !dark {
                app.toolbars.buttons.element(boundBy: 0).click()
                XCTAssertGreaterThan(title.frame.minX, app.windows.firstMatch.frame.minX + 100,
                                     "A collapsed sidebar must leave room for native window controls.")
                capture(app, name: "Conversation flow - sidebar collapsed")
                app.toolbars.buttons.element(boundBy: 0).click()
                app.buttons["conversation.inspector"].click()
                XCTAssertLessThan(title.frame.minX - sidebar.frame.maxX, 40)
                capture(app, name: "Conversation flow - inspector open")
            }
        }
    }

    private func withApplication(language: String, dark: Bool,
                                 body: (XCUIApplication) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mira-Conversation-Flow-\(UUID())", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo", "--verify-conversation-flow", "--data-directory", directory.path,
            "-app.language", language, "-app.displayMode", dark ? "dark" : "light",
            "-AppleLanguages", "(en)"
        ]
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        try launchWindow(app)
        try require(app.descendants(matching: .any)["conversation.composer"].waitForExistence(timeout: 15), "Mira did not display its composer.")
        let title = app.descendants(matching: .any)["conversation.title"]
        try require(title.waitForExistence(timeout: 10), "The conversation title accessibility element is missing.")
        let sidebarAnchor = app.buttons["sidebar.newConversation"]
        if !sidebarAnchor.exists || title.frame.minX < sidebarAnchor.frame.maxX {
            app.toolbars.buttons.element(boundBy: 0).click()
        }
        try require(sidebarAnchor.waitForExistence(timeout: 10), "The sidebar anchor is missing.")
        XCTAssertGreaterThan(title.frame.minX, sidebarAnchor.frame.maxX - 4,
                             "The detail title must sit to the right of the native sidebar.")
        if dark {
            let window = app.windows.firstMatch
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -2, dy: -2))
            let target = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 848, dy: 618))
            corner.press(forDuration: 0.1, thenDragTo: target)
        }
        try body(app)
    }

    private func launchWindow(_ app: XCUIApplication) throws {
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.menuBars.menuBarItems["File"].click()
            app.menuItems["New Window"].click()
        }
        try require(app.windows.firstMatch.waitForExistence(timeout: 10), "Mira did not open a window.")
    }

    private func send(_ text: String, in app: XCUIApplication) throws {
        let composer = app.descendants(matching: .any)["conversation.composer"]
        composer.click()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        composer.typeKey("a", modifierFlags: .command)
        composer.typeKey("v", modifierFlags: .command)
        try require((composer.value as? String) == text, "The composer did not receive the fixture text.")
        app.buttons["conversation.send"].click()
    }

    private enum ActivityPhase { case thinking, answering, completed }

    private func stateLabel(language: String, phase: ActivityPhase) -> String {
        switch (language, phase) {
        case ("zh-CN", .thinking): "正在思考…" // i18n-fixture: Assert the supported Chinese activity label.
        case ("zh-CN", .answering): "正在回答…" // i18n-fixture: Assert the supported Chinese activity label.
        case ("zh-CN", .completed): "已完成" // i18n-fixture: Assert the supported Chinese activity label.
        case (_, .thinking): "Thinking…"
        case (_, .answering): "Answering…"
        case (_, .completed): "Completed"
        }
    }

    private func latestActivity(in app: XCUIApplication, timeout: TimeInterval,
                                minimumCount: Int = 1) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        let activities = app.buttons.matching(identifier: "conversation.activity")
        while Date() < deadline {
            let count = activities.count
            if count >= minimumCount {
                return activities.element(boundBy: count - 1)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        throw NSError(domain: "MiraUITests", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "The activity disclosure did not appear."])
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                (object as? XCUIElement)?.label.localizedCaseInsensitiveContains(text) == true
            }, object: element)
        try require(XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed,
                    "Expected activity label containing \(text), got \(element.label).")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "MiraUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
