#if DEBUG
import AppKit
import Foundation
import ListViewKit
import MiraCore
import MiraData

/// Verifies conversation selection and native transcript geometry with isolated synthetic data.
@MainActor
enum ConversationSwitchBenchmark {
    static func run(model: ConversationModel) async {
        guard ProcessInfo.processInfo.arguments.contains("--verify-conversation-switching") else { return }
        guard let reportPath = argument("--benchmark-report"),
              let directoryPath = argument("--data-directory"),
              !FileManager.default.fileExists(atPath: reportPath) else { return }
        do {
            let store = try SQLiteMiraStore(directory: URL(fileURLWithPath: directoryPath, isDirectory: true))
            let ids = try await Task.detached(priority: .utility) {
                try seed(store: store)
            }.value
            await model.reload()
            let minimum = ProcessInfo.processInfo.arguments.contains("--benchmark-minimum-window")
            NSApp.windows.first(where: \.isVisible)?.setContentSize(minimum ? CGSize(width: 850, height: 620) : CGSize(width: 1100, height: 760))
            let report = await exercise(model: model, conversationIDs: ids)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: reportPath), options: .withoutOverwriting)
        } catch {
            let report: [String: Any] = ["schema": 1, "passed": false, "error": MiraError.safe(error).message]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: reportPath), options: .withoutOverwriting)
            }
        }
    }

    private static func argument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.filter({ $0 == flag }).count == 1,
              let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
              arguments[index + 1].hasPrefix("/") else { return nil }
        return arguments[index + 1]
    }

    nonisolated private static func seed(store: SQLiteMiraStore) throws -> [ConversationID] {
        let existing = try store.conversations(includeArchived: true)
        guard existing.isEmpty else { return existing.prefix(2).map(\.id) }
        let now = Date()
        let route = ResolvedModelRouteSnapshot(name: "Synthetic benchmark", providerKind: .openAICompatible,
                                               baseURL: "https://benchmark.invalid/v1", modelID: "synthetic",
                                               credentialReference: "benchmark", contextWindow: 131_072)
        let ids = [ConversationID(), ConversationID()]
        for (index, conversationID) in ids.enumerated() {
            try store.createConversation(.init(id: conversationID, workspaceID: nil,
                                                title: "Synthetic Switch \(index + 1)", createdAt: now, updatedAt: now))
            let pairCount = index == 0 ? 50 : 60
            for pair in 0..<pairCount {
                let userID = MessageID(), executionID = ExecutionID()
                _ = try store.enqueue(conversationID: conversationID, text: fixtureText(sequence: pair * 2, role: "user"),
                                      route: route, executionID: executionID, messageID: userID,
                                      at: now.addingTimeInterval(Double(pair * 2)))
                _ = try store.finish(executionID: executionID, status: .completed,
                                     text: fixtureText(sequence: pair * 2 + 1, role: "assistant"),
                                     trace: [], usage: .init(), error: nil, assistantMessageID: MessageID(),
                                     at: now.addingTimeInterval(Double(pair * 2 + 1)))
            }
        }
        return ids
    }

    nonisolated private static func fixtureText(sequence: Int, role: String) -> String {
        let heading = sequence % 5 == 1 ? "\n\n## Synthetic section \(sequence / 5)\n" : ""
        let code = sequence.isMultiple(of: 7) ? "\n\n```swift\nlet syntheticValue_\(sequence) = \(sequence)\nprint(syntheticValue_\(sequence))\n```\n" : ""
        let paragraph = String(repeating: "Synthetic variable-height transcript content for conversation switching. ", count: sequence.isMultiple(of: 3) ? 6 : 2)
        return "\(role.capitalized) message \(sequence).\(heading)\n\n\(paragraph)\(code)"
    }

    private static func exercise(model: ConversationModel, conversationIDs: [ConversationID]) async -> [String: Any] {
        guard conversationIDs.count >= 2 else { return ["schema": 1, "passed": false, "error": "Two conversations were not seeded."] }
        let probe = ServiceProbe()
        let probeTask = Task.detached {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                let requested = ContinuousClock.now
                await probe.record(requested)
            }
        }
        defer { probeTask.cancel() }
        let first = conversationIDs[0], second = conversationIDs[1]
        let firstSelection = await select(model, first)
        guard let firstList = await waitForList(expectedCount: 100) else {
            return ["schema": 1, "passed": false, "error": model.error?.message ?? "First native transcript did not mount."]
        }
        let firstReadyMilliseconds = firstSelection.elapsedMilliseconds
        let firstBottomSamples = await bottomSamples(expectedCount: 100)
        let firstMessageCount = model.messages.count
        model.composer = "Synthetic composer draft"
        probe.phase = "same-selection"
        let revisionBeforeSameSelection = model.inspectionRevision
        let sameSelection = await select(model, first)
        let sameSelectionPreserved = model.messages.count == firstMessageCount
            && !model.composer.isEmpty && model.inspectionRevision == revisionBeforeSameSelection
        let firstAnchor = captureAnchor(firstList)
        firstList.setContentOffset(CGPoint(x: 0, y: firstList.maximumContentOffset.y / 2), animated: false)
        try? await Task.sleep(for: .milliseconds(250))
        let firstMiddleAnchor = captureAnchor(firstList)
        probe.phase = "second-entry"
        let secondSelection = await select(model, second)
        guard let mountedSecond = await waitForList(expectedCount: 120) else {
            return ["schema": 1, "passed": false, "error": "Second native transcript did not mount."]
        }
        let secondReadyMilliseconds = secondSelection.elapsedMilliseconds
        let secondMessageCount = model.messages.count
        let secondBottomSamples = await bottomSamples(expectedCount: 120)
        mountedSecond.setContentOffset(CGPoint(x: 0, y: mountedSecond.maximumContentOffset.y / 2), animated: false)
        try? await Task.sleep(for: .milliseconds(250))
        let secondMiddleAnchor = captureAnchor(mountedSecond)
        let reuseCountBeforeReturn = (mountedSecond.superview as? NativeTranscriptViewport)?.readingMeasurementReuseCount ?? 0
        probe.phase = "history-return"
        let returnSelection = await select(model, first)
        guard let returnedFirstList = await waitForList(expectedCount: 100) else {
            return ["schema": 1, "passed": false, "error": "First transcript did not remount."]
        }
        let returnReadyMilliseconds = returnSelection.elapsedMilliseconds
        try? await Task.sleep(for: .milliseconds(250))
        let returnedFirstAnchor = captureAnchor(returnedFirstList)
        let returnMeasurementReuseCount = ((returnedFirstList.superview as? NativeTranscriptViewport)?.readingMeasurementReuseCount ?? 0) - reuseCountBeforeReturn
        let firstAnchorPreserved = firstMiddleAnchor.id == returnedFirstAnchor.id && abs(firstMiddleAnchor.relativeY - returnedFirstAnchor.relativeY) < 2
        var repeatedAnchorChecks = [firstAnchorPreserved]
        var repeatedAnchors: [[String: Any]] = []
        for _ in 0..<3 {
            _ = await select(model, second)
            guard let currentSecond = await waitForList(expectedCount: 120) else { break }
            try? await Task.sleep(for: .milliseconds(180))
            let secondReturnAnchor = captureAnchor(currentSecond)
            _ = await select(model, first)
            guard let currentFirst = await waitForList(expectedCount: 100) else { break }
            try? await Task.sleep(for: .milliseconds(180))
            let firstReturnAnchor = captureAnchor(currentFirst)
            repeatedAnchors.append([
                "first": ["id": firstReturnAnchor.id, "relativeY": firstReturnAnchor.relativeY],
                "second": ["id": secondReturnAnchor.id, "relativeY": secondReturnAnchor.relativeY],
                "secondExpected": ["id": secondMiddleAnchor.id, "relativeY": secondMiddleAnchor.relativeY]
            ])
            repeatedAnchorChecks.append(
                firstMiddleAnchor.id == firstReturnAnchor.id
                    && abs(firstMiddleAnchor.relativeY - firstReturnAnchor.relativeY) < 2
                    && secondMiddleAnchor.id == secondReturnAnchor.id
                    && abs(secondMiddleAnchor.relativeY - secondReturnAnchor.relativeY) < 2)
        }
        let report: [String: Any] = [
            "schema": 1,
            "conversationIDs": conversationIDs.map { $0.rawValue.uuidString },
            "passed": firstSelection.passed && sameSelection.passed && secondSelection.passed && returnSelection.passed
                && sameSelectionPreserved && firstAnchorPreserved && repeatedAnchorChecks.count == 4
                && returnMeasurementReuseCount > 0
                && repeatedAnchorChecks.allSatisfy { $0 }
                && !firstBottomSamples.isEmpty && firstBottomSamples.allSatisfy { abs($0) < 2 }
                && !secondBottomSamples.isEmpty && secondBottomSamples.allSatisfy { abs($0) < 2 },
            "firstSelectionMs": firstSelection.milliseconds,
            "secondSelectionMs": secondSelection.milliseconds,
            "returnSelectionMs": returnSelection.milliseconds,
            "sameSelectionMs": sameSelection.milliseconds,
            "firstNativeReadyMs": firstReadyMilliseconds,
            "secondNativeReadyMs": secondReadyMilliseconds,
            "returnNativeReadyMs": returnReadyMilliseconds,
            "returnMeasurementReuseCount": returnMeasurementReuseCount,
            "firstMessageCount": firstMessageCount,
            "secondMessageCount": secondMessageCount,
            "inspectionRevision": model.inspectionRevision,
            "sameSelectionPreserved": sameSelectionPreserved,
            "firstEntryBottomDistances": firstBottomSamples,
            "secondEntryBottomDistances": secondBottomSamples,
            "initialAnchor": ["id": firstAnchor.id, "relativeY": firstAnchor.relativeY],
            "middleAnchor": ["id": firstMiddleAnchor.id, "relativeY": firstMiddleAnchor.relativeY],
            "returnedAnchor": ["id": returnedFirstAnchor.id, "relativeY": returnedFirstAnchor.relativeY],
            "anchorPreserved": firstAnchorPreserved,
            "repeatedAnchorChecks": repeatedAnchorChecks,
            "repeatedAnchors": repeatedAnchors,
            "nativeListType": String(describing: type(of: firstList)),
            "mainActorServiceMs": probe.samples,
            "mainActorServiceByPhaseMs": probe.samplesByPhase,
            "limitations": ["Selection timings end when the model snapshot is published, before native rendering completes.", "Main-actor queue service and sampled geometry are proxies, not displayed frame rate or hardware input latency.", "Synthetic SQLite fixtures do not contact providers or read credentials."]
        ]
        return report
    }

    private struct SelectionResult {
        let started: ContinuousClock.Instant
        let milliseconds: Double
        let passed: Bool
        var elapsedMilliseconds: Double {
            let duration = started.duration(to: .now)
            return Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1_000
        }
    }

    @MainActor private final class ServiceProbe {
        var samples: [Double] = []
        var phase = "first-entry"
        var samplesByPhase: [String: [Double]] = [:]
        func record(_ requested: ContinuousClock.Instant) {
            let duration = requested.duration(to: .now)
            let milliseconds = Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1_000
            samples.append(milliseconds)
            samplesByPhase[phase, default: []].append(milliseconds)
        }
    }

    private static func select(_ model: ConversationModel, _ id: ConversationID) async -> SelectionResult {
        let start = ContinuousClock.now
        await model.selectConversation(id)
        let duration = start.duration(to: .now)
        return .init(started: start, milliseconds: Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1_000,
                     passed: model.selectedConversationID == id && !model.messages.isEmpty)
    }

    private static func findList() -> ListView<NativeTranscriptToken>? {
        func descend(_ view: NSView) -> ListView<NativeTranscriptToken>? {
            if let list = view as? ListView<NativeTranscriptToken> { return list }
            for child in view.subviews {
                if let list = descend(child) { return list }
            }
            return nil
        }
        return NSApp.windows.first(where: { $0.isVisible })?.contentView.flatMap(descend)
    }

    private static func waitForList(expectedCount: Int) async -> ListView<NativeTranscriptToken>? {
        for _ in 0..<75 {
            if let list = findList(), list.content.count == expectedCount { return list }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return nil
    }

    private static func bottomSamples(expectedCount: Int) async -> [Double] {
        var values: [Double] = []
        for _ in 0..<47 {
            if let list = await waitForList(expectedCount: expectedCount), !list.content.isEmpty {
                let bottom = list.rectForRow(at: list.content.count - 1).maxY
                values.append(Double(list.bounds.height - list.contentInsets.bottom - (bottom - list.contentOffset.y)))
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return values
    }

    private struct Anchor { let id: String; let relativeY: CGFloat }

    private static func captureAnchor(_ list: ListView<NativeTranscriptToken>) -> Anchor {
        let offset = list.contentOffset.y
        let index = list.content.indices.first(where: { list.rectForRow(at: $0).maxY - offset > 0 }) ?? 0
        let token = list.content[index]
        return Anchor(id: token.id, relativeY: list.rectForRow(at: index).minY - offset)
    }
}
#endif
