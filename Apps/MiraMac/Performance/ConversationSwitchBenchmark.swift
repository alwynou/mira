#if DEBUG
    import AppKit
    import Foundation
    import ListViewKit
    import MiraCore

    /// Measures switching between sessions seeded through the application runtime.
    @MainActor
    enum ConversationSwitchBenchmark {
        static func run(model: ConversationModel, conversationIDs: [ConversationID]) async {
            guard ProcessInfo.processInfo.arguments.contains("--verify-conversation-switching"),
                let reportPath = argument("--benchmark-report"),
                !FileManager.default.fileExists(atPath: reportPath)
            else { return }
            let minimum = ProcessInfo.processInfo.arguments.contains("--benchmark-minimum-window")
            NSApp.windows.first(where: \.isVisible)?.setContentSize(
                minimum ? CGSize(width: 850, height: 620) : CGSize(width: 1_100, height: 760))
            let report = await exercise(model: model, conversationIDs: conversationIDs)
            guard JSONSerialization.isValidJSONObject(report),
                let data = try? JSONSerialization.data(
                    withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? data.write(to: URL(fileURLWithPath: reportPath), options: .withoutOverwriting)
        }

        private static func argument(_ flag: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.filter({ $0 == flag }).count == 1,
                let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
                arguments[index + 1].hasPrefix("/")
            else { return nil }
            return arguments[index + 1]
        }

        private static func exercise(model: ConversationModel, conversationIDs: [ConversationID]) async -> [String: Any]
        {
            guard conversationIDs.count >= 2 else {
                return ["schema": 2, "passed": false, "error": "Two benchmark sessions were not seeded."]
            }
            let first = conversationIDs[0]
            let second = conversationIDs[1]
            let firstSelection = await select(model, first)
            let firstCount = model.activePage.messages.count
            guard let firstList = await waitForList(conversationID: first) else {
                return ["schema": 2, "passed": false, "error": "First native transcript did not mount."]
            }
            let firstAnchor = captureAnchor(firstList)
            firstList.setContentOffset(CGPoint(x: 0, y: firstList.maximumContentOffset.y / 2), animated: false)
            try? await Task.sleep(for: .milliseconds(120))
            let middleAnchor = captureAnchor(firstList)
            model.activePage.composer = "Synthetic composer draft"
            let revision = model.activePage.inspectionRevision
            let same = await select(model, first)
            let samePreserved =
                model.activePage.messages.count == firstCount
                && !model.activePage.composer.isEmpty && model.activePage.inspectionRevision == revision

            let secondSelection = await select(model, second)
            let secondCount = model.activePage.messages.count
            guard let secondList = await waitForList(conversationID: second) else {
                return ["schema": 2, "passed": false, "error": "Second native transcript did not mount."]
            }
            let secondAnchor = captureAnchor(secondList)
            secondList.setContentOffset(CGPoint(x: 0, y: secondList.maximumContentOffset.y / 2), animated: false)
            try? await Task.sleep(for: .milliseconds(120))

            let returned = await select(model, first)
            guard let returnedList = await waitForList(conversationID: first) else {
                return ["schema": 2, "passed": false, "error": "First transcript did not remount."]
            }
            try? await Task.sleep(for: .milliseconds(120))
            let returnedAnchor = captureAnchor(returnedList)
            let anchorPreserved =
                middleAnchor.id == returnedAnchor.id
                && abs(middleAnchor.relativeY - returnedAnchor.relativeY) < 2
            let report: [String: Any] = [
                "schema": 2,
                "conversationIDs": conversationIDs.map { $0.rawValue.uuidString },
                "passed": firstSelection.passed && same.passed && secondSelection.passed && returned.passed
                    && samePreserved && anchorPreserved && firstCount > 0 && secondCount > firstCount / 2,
                "firstSelectionMs": firstSelection.milliseconds,
                "secondSelectionMs": secondSelection.milliseconds,
                "returnSelectionMs": returned.milliseconds,
                "firstMessageCount": firstCount,
                "secondMessageCount": secondCount,
                "firstListMounted": firstList.content.count > 0,
                "secondListMounted": secondList.content.count > 0,
                "firstAnchor": ["id": firstAnchor.id, "relativeY": firstAnchor.relativeY],
                "middleAnchor": ["id": middleAnchor.id, "relativeY": middleAnchor.relativeY],
                "returnedAnchor": ["id": returnedAnchor.id, "relativeY": returnedAnchor.relativeY],
                "secondAnchor": ["id": secondAnchor.id, "relativeY": secondAnchor.relativeY],
                "sameSelectionPreserved": samePreserved,
                "anchorPreserved": anchorPreserved,
                "limitations": [
                    "Sessions and replies are created through the local application driver and journal.",
                    "Selection timings and anchors are native presentation proxies, not frame-rate measurements.",
                    "Provider, credentials, notification delivery, and cancellation are outside this benchmark.",
                ],
            ]
            return report
        }

        private struct SelectionResult {
            let milliseconds: Double
            let passed: Bool
        }

        private static func select(_ model: ConversationModel, _ id: ConversationID) async -> SelectionResult {
            let start = ContinuousClock.now
            await model.selectConversation(id)
            await model.activePage.loadTask?.value
            return .init(
                milliseconds: NativePerformanceBenchmark.milliseconds(start.duration(to: .now)),
                passed: model.selectedConversationID == id && !model.activePage.messages.isEmpty)
        }

        private static func waitForList(conversationID: ConversationID) async -> ListView<NativeTranscriptToken>? {
            for _ in 0..<75 {
                if let list = NativePerformanceBenchmark.findList(for: conversationID), !list.content.isEmpty {
                    return list
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            return nil
        }

        private struct Anchor {
            let id: String
            let relativeY: CGFloat
        }

        private static func captureAnchor(_ list: ListView<NativeTranscriptToken>) -> Anchor {
            guard !list.content.isEmpty else { return .init(id: "", relativeY: 0) }
            let offset = list.contentOffset.y
            let index = list.content.indices.first(where: { list.rectForRow(at: $0).maxY - offset > 0 }) ?? 0
            let token = list.content[index]
            return .init(id: token.id, relativeY: list.rectForRow(at: index).minY - offset)
        }
    }
#endif
