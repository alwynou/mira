#if DEBUG
import AppKit
import ListViewKit
import Litext
import Foundation
import MiraCore

/// Opt-in presentation benchmark. Uses the real transcript and composer with synthetic
/// in-memory state; it does not measure provider, database, cancellation, or keyboard latency.
@MainActor
enum NativePerformanceBenchmark {
    private static func argument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.filter({ $0 == flag }).count == 1,
              let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
              arguments[index + 1].hasPrefix("/") else { return nil }
        return arguments[index + 1]
    }

    static var isRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--demo"), arguments.contains("--native-rendering-benchmark"),
              let report = argument("--benchmark-report"), argument("--data-directory") != nil else { return false }
        let parent = URL(fileURLWithPath: report).deletingLastPathComponent().path
        return !FileManager.default.fileExists(atPath: report) && FileManager.default.isWritableFile(atPath: parent)
    }

    static func run(model: ConversationModel) async {
        guard isRequested, let path = argument("--benchmark-report"),
              !FileManager.default.fileExists(atPath: path) else { return }
        if ProcessInfo.processInfo.arguments.contains("--verify-conversation-switching") {
            await ConversationSwitchBenchmark.run(model: model)
            return
        }
        await Run(model: model).perform(reportURL: URL(fileURLWithPath: path))
    }

    @MainActor private final class Run {
        let model: ConversationModel
        let started = ContinuousClock.now
        var phase = "warmup" {
            didSet { FileHandle.standardOutput.write(Data("Benchmark phase: \(phase)\n".utf8)) }
        }
        var samples: [Sample] = []
        var scrollPositions: [Double] = []
        var nativeScrollViewFound = false
        let conversationID = ConversationID()
        let executionID = ExecutionID()

        init(model: ConversationModel) { self.model = model }

        func perform(reportURL: URL) async {
            installHistory()
            if ProcessInfo.processInfo.arguments.contains("--verify-floating-composer") {
                await verifyFloatingComposer(reportURL: reportURL)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--verify-markdown-layout") {
                await verifyMarkdownLayout(reportURL: reportURL)
                return
            }
            // Start the timestamp off-main; an inherited MainActor task would hide
            // precisely the queue delay this probe is intended to measure.
            let probe = Task.detached { [self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    let enqueued = ContinuousClock.now
                    await self.recordProbe(enqueued: enqueued)
                }
            }
            defer { probe.cancel() }
            do {
                try await Task.sleep(for: .seconds(8))
                phase = "streaming"
                let text = (1...30).map(Self.section).joined(separator: "\n\n")
                let trace = [CanonicalMessage(role: .assistant, text: "", reasoning: .init(
                    format: .openAIContent, text: String(repeating: "Reviewing synthetic table, code, and paragraph layout. ", count: 32), isComplete: true
                ))]
                model.activePage.streamBuffer.receiveThinking(trace, for: executionID)
                let characters = Array(text)
                for end in stride(from: 50, to: characters.count + 50, by: 50) {
                    try Task.checkCancellation()
                    model.activePage.streamBuffer.receiveDraft(String(characters.prefix(min(end, characters.count))), for: executionID)
                    try await Task.sleep(for: .milliseconds(100))
                }
                model.activePage.streamBuffer.flush()
                model.activePage.messages.append(.init(id: .init(), conversationID: conversationID, executionID: executionID,
                                            sequence: 102, role: .assistant, status: .committed, text: text, createdAt: Date(), trace: trace))
                model.activePage.executions[0].status = .completed
                model.activePage.streamBuffer.replace(drafts: [:], thinkingTraces: [:])
                phase = "scrolling"
                for index in 0..<30 {
                    try await Task.sleep(for: .milliseconds(500))
                    scroll(index: index)
                }
                phase = "settled"
                try await Task.sleep(for: .seconds(5))
                probe.cancel()
                await probe.value
                let report = Report(
                    schema: 1, os: Self.osVersion,
                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                    processorCount: ProcessInfo.processInfo.processorCount,
                    elapsedSeconds: seconds(started.duration(to: .now)),
                    historyMessageCount: 100, historyUTF8Bytes: (1...50).map(Self.section).joined().utf8.count,
                    streamedUTF8Bytes: text.utf8.count, thinkingUTF8Bytes: trace[0].reasoning!.text.utf8.count,
                    thinkingExpanded: ProcessInfo.processInfo.arguments.contains("--benchmark-expand-thinking"),
                    nativeScrollViewFound: nativeScrollViewFound, scrollPositions: scrollPositions,
                    summaries: ["warmup", "streaming", "scrolling", "settled"].map { name in
                        let values = samples.filter { $0.phase == name }.map(\.serviceMilliseconds).sorted()
                        return .init(phase: name, count: values.count,
                                     p50: percentile(values, 0.5), p95: percentile(values, 0.95), maximum: values.last ?? 0)
                    }, samples: samples,
                    limitations: [
                        "Main-actor queue service latency is not hardware keystroke latency or displayed frame rate.",
                        "Composer updates and scroll commands are programmatic; real input and Instruments require separate verification.",
                        "Presentation fixtures bypass provider and persistence; cancellation and recovery are not measured.",
                        "Thinking expansion follows the explicit benchmark flag; actual input is verified separately.",
                        "Debug build on the current host; RSS includes retained allocator memory and is not a leak diagnosis."
                    ])
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: reportURL, options: .withoutOverwriting)
            } catch {
                probe.cancel()
                await probe.value
                // A cancelled view or unavailable report destination must not touch another library.
                return
            }
        }

        /// An offline native layout fixture; it does not synthesize user input or measure performance.
        func verifyFloatingComposer(reportURL: URL) async {
            model.activePage.messages.append(.init(id: .init(), conversationID: conversationID, executionID: executionID,
                                        sequence: 102, role: .assistant, status: .committed,
                                        text: Self.section(99) + "\n\nFINAL VISIBLE LINE", createdAt: Date()))
            model.activePage.executions[0].status = .completed
            model.activePage.streamBuffer.replace(drafts: [:], thinkingTraces: [:])
            try? await Task.sleep(for: .seconds(2))
            func findList(_ view: NSView) -> ListView<NativeTranscriptToken>? {
                if let list = view as? ListView<NativeTranscriptToken> { return list }
                for child in view.subviews {
                    if let list = findList(child) { return list }
                }
                return nil
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let root = window.contentView, let list = findList(root) else { return }
            var wheelEventCount = 0
            let inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
                MainActor.assumeIsolated {
                    if event.window === window { wheelEventCount += 1 }
                }
                return event
            }
            defer { if let inputMonitor { NSEvent.removeMonitor(inputMonitor) } }
            var results: [[String: Any]] = []
            let scenarios: [(String, Int, CGSize, String, NSAppearance.Name)] = [
                ("short-light-en", 1, CGSize(width: 1100, height: 760), "en", .aqua),
                ("multiline-light-en", 8, CGSize(width: 1100, height: 760), "en", .aqua),
                ("shrink-light-en", 1, CGSize(width: 1100, height: 760), "en", .aqua),
                ("minimum-dark-zh", 8, CGSize(width: 850, height: 620), "zh-CN", .darkAqua),
                ("minimum-short-dark-zh", 1, CGSize(width: 850, height: 620), "zh-CN", .darkAqua),
            ]
            for (name, lines, size, language, appearance) in scenarios {
                UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
                UserDefaults.standard.set(appearance == .aqua ? "light" : "dark", forKey: AppDisplayMode.preferenceKey)
                window.setContentSize(size)
                model.activePage.composer = (1...lines).map { "Synthetic input line \($0)" }.joined(separator: "\n")
                try? await Task.sleep(for: .milliseconds(1200))
                let rowBottom = list.rectForRow(at: list.content.count - 1).maxY - list.contentOffset.y
                let clearBottom = list.bounds.height - list.contentInsets.bottom
                let gap = clearBottom - rowBottom
                results.append([
                    "scenario": name, "viewportHeight": list.bounds.height,
                    "overlayHeight": list.contentInsets.bottom, "rowBottom": rowBottom,
                    "clearBottom": clearBottom, "clearance": gap,
                    "atLatest": abs(list.maximumContentOffset.y - list.contentOffset.y) < 1,
                    "userOwnsOffset": list.isScrollOffsetOwnedByUser,
                    "wheelEventCount": wheelEventCount,
                    "passed": gap >= -1 && list.contentInsets.bottom > 100 && list.bounds.height > 400,
                ])
            }
            model.activePage.messages.removeAll { $0.executionID == executionID && $0.role == .assistant }
            model.activePage.executions[0].status = .waitingForModel
            let initialText = Self.section(99)
            model.activePage.streamBuffer.replace(drafts: [executionID: initialText], thinkingTraces: [:])
            try? await Task.sleep(for: .seconds(1))
            list.setContentOffset(list.maximumContentOffset, animated: false)
            try? await Task.sleep(for: .seconds(1))
            // Receive the next stream snapshot while a composer resize is still settling.
            model.activePage.composer = (1...8).map { "Synthetic input line \($0)" }.joined(separator: "\n")
            try? await Task.sleep(for: .milliseconds(100))
            let initialOffset = list.contentOffset.y
            let finalText = initialText + "\n\n" + Self.section(100) + "\n\nFINAL VISIBLE LINE"
            model.activePage.streamBuffer.receiveDraft(finalText, for: executionID)
            model.activePage.streamBuffer.flush()
            try? await Task.sleep(for: .seconds(1))
            let streamingOffset = list.contentOffset.y
            let streamingMaximum = list.maximumContentOffset.y
            model.activePage.messages.append(.init(id: .init(), conversationID: conversationID, executionID: executionID,
                                        sequence: 102, role: .assistant, status: .committed,
                                        text: finalText, createdAt: Date()))
            model.activePage.executions[0].status = .completed
            model.activePage.streamBuffer.replace(drafts: [:], thinkingTraces: [:])
            try? await Task.sleep(for: .seconds(1))
            let terminalOffset = list.contentOffset.y
            let streamPassed = abs(initialOffset - streamingOffset) < 1
                && abs(initialOffset - terminalOffset) < 1 && streamingMaximum > initialOffset + 100
            func backdrops(_ view: NSView) -> [MiraComposerBackdropView] {
                (view as? MiraComposerBackdropView).map { [$0] } ?? view.subviews.flatMap(backdrops)
            }
            let surfaces = backdrops(root)
            let surfacePassed = !surfaces.isEmpty && surfaces.allSatisfy {
                $0.blendingMode == .withinWindow && $0.material == .headerView
                    && ($0.layer?.shadowOpacity ?? 0) == 0
            }
            let bottomGaps = surfaces.map { $0.convert($0.bounds, to: nil).minY }
            let bottomGapPassed = bottomGaps.allSatisfy { abs($0 - MiraTheme.Layout.composerBottomInset) < 1 }
            let report: [String: Any] = [
                "scenarios": results,
                "composerBottomGaps": bottomGaps,
                "wheelEventCount": wheelEventCount,
                "materialOpacities": surfaces.map(\.alphaValue),
                "streamingScroll": ["initialOffset": initialOffset, "streamingOffset": streamingOffset,
                                   "terminalOffset": terminalOffset, "streamingMaximum": streamingMaximum,
                                   "passed": streamPassed],
                "nativeSurfaceConfigured": surfacePassed,
                "surfaceTypes": surfaces.map { String(describing: type(of: $0)) },
                "passed": wheelEventCount == 0 && streamPassed && surfacePassed && bottomGapPassed && results.allSatisfy {
                    $0["passed"] as? Bool == true && $0["atLatest"] as? Bool == true
                },
            ]
            list.setContentOffset(list.maximumContentOffset, animated: false)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: reportURL, options: .withoutOverwriting)
            }
        }

        /// Exercises mounted streaming geometry with synthetic content and no provider calls.
        func verifyMarkdownLayout(reportURL: URL) async {
            try? await Task.sleep(for: .seconds(2))
            func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
                (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let root = window.contentView,
                  let list = descendants(root, of: ListView<NativeTranscriptToken>.self).first else { return }
            // Unicode fixture: escaped synthetic CJK verifies wrapping; this is not UI copy.
            let section = """
            ### Synthetic layout check / \u{6392}\u{7248}\u{9a8c}\u{8bc1}

            ```bash
            # Synthetic code with multiple lines
            echo "first line"
            echo "second line"
            echo "third line"
            echo "fourth line"
            echo "fifth line"
            echo "sixth line"
            echo "seventh line"
            ```

            ### Text after code / \u{4ee3}\u{7801}\u{540e}\u{6807}\u{9898}

            A completed paragraph must remain below the code. \u{5df2}\u{5b8c}\u{6210}\u{6bb5}\u{843d}\u{5e94}\u{4fdd}\u{6301}\u{4f4d}\u{7f6e}\u{7a33}\u{5b9a}。

            | First column | Second column |
            | --- | --- |
            | Synthetic wrapping cell / \u{5408}\u{6210}\u{8868}\u{683c}\u{5185}\u{5bb9} | Value |
            | Short | Another value |

            Text after the table / \u{8868}\u{683c}\u{540e}\u{6b63}\u{6587}。

            """
            let prefix = "Stable native prefix.\n\n" + section + "\n\n"
            let suffix = Array(section + "\n\n" + section)
            var results: [[String: Any]] = []
            for (name, size, language, mode) in [
                ("light-en", CGSize(width: 1100, height: 760), "en", "light"),
                ("minimum-dark-zh", CGSize(width: 850, height: 620), "zh-CN", "dark")
            ] {
                UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
                UserDefaults.standard.set(mode, forKey: AppDisplayMode.preferenceKey)
                window.setContentSize(size)
                model.activePage.messages.removeAll { $0.executionID == executionID && $0.role == .assistant }
                model.activePage.executions[0].status = .waitingForModel
                model.activePage.streamBuffer.replace(drafts: [executionID: prefix], thinkingTraces: [:])
                try? await Task.sleep(for: .seconds(1))
                let row = list.rectForRow(at: list.content.count - 1)
                list.setContentOffset(CGPoint(x: 0, y: row.minY), animated: false)
                try? await Task.sleep(for: .seconds(1))
                let offset = list.contentOffset.y
                var originalLines: [CGFloat] = []
                var maximumPrefixDrift: CGFloat = 0
                var maximumScrollDrift: CGFloat = 0
                var overlapCount = 0
                var sampleCount = 0
                func inspect() {
                    root.layoutSubtreeIfNeeded()
                    guard let markdown = descendants(root, of: MiraMarkdownView.self).first(where: {
                        $0.textLabelView.attributedText.string.hasPrefix("Stable native prefix.")
                    }) else { return }
                    let label = markdown.textLabelView
                    let key = NSAttributedString.Key("contextView")
                    let blocks = label.layoutRuns(matching: key)
                    let blockLines = Set(blocks.map(\.lineIndex))
                    let lines = label.layoutRuns(matching: .font).filter {
                        !blockLines.contains($0.lineIndex) && !label.attributedText.attributedSubstring(from: $0.stringRange)
                            .string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    let frames = lines.map {
                        CGRect(x: $0.lineRect.minX, y: label.bounds.height - $0.lineRect.maxY,
                               width: $0.lineRect.width, height: $0.lineRect.height)
                            .offsetBy(dx: label.frame.minX, dy: label.frame.minY)
                    }
                    for block in blocks {
                        guard let view = block.attributes[key] as? NSView else { continue }
                        overlapCount += frames.filter { view.frame.intersection($0).height > 1 }.count
                    }
                    let positions = frames.prefix(8).map { markdown.convert($0, to: root).minY }
                    if originalLines.isEmpty { originalLines = positions }
                    for (original, current) in zip(originalLines, positions) {
                        maximumPrefixDrift = max(maximumPrefixDrift, abs(original - current))
                    }
                    maximumScrollDrift = max(maximumScrollDrift, abs(list.contentOffset.y - offset))
                    sampleCount += 1
                }
                inspect()
                for end in stride(from: 48, to: suffix.count + 48, by: 48) {
                    model.activePage.streamBuffer.receiveDraft(prefix + String(suffix.prefix(end)), for: executionID)
                    model.activePage.streamBuffer.flush()
                    try? await Task.sleep(for: .milliseconds(80))
                    inspect()
                }
                try? await Task.sleep(for: .milliseconds(800))
                inspect()
                model.activePage.messages.append(.init(id: .init(), conversationID: conversationID, executionID: executionID,
                                            sequence: 102, role: .assistant, status: .committed,
                                            text: prefix + String(suffix), createdAt: Date()))
                model.activePage.executions[0].status = .completed
                model.activePage.streamBuffer.replace(drafts: [:], thinkingTraces: [:])
                try? await Task.sleep(for: .milliseconds(800))
                inspect()
                results.append(["scenario": name, "samples": sampleCount, "overlaps": overlapCount,
                                "maximumPrefixDrift": maximumPrefixDrift, "maximumScrollDrift": maximumScrollDrift,
                                "passed": sampleCount > 20 && overlapCount == 0
                                    && maximumPrefixDrift < 1 && maximumScrollDrift < 1])

            }
            let report: [String: Any] = ["os": Self.osVersion, "scenarios": results,
                                       "passed": results.allSatisfy { $0["passed"] as? Bool == true }]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: reportURL, options: .withoutOverwriting)
            }
        }

        static var osVersion: String {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }

        func installHistory() {
            let now = Date()
            model.activePage.conversationID = conversationID
            model.conversations = [.init(id: conversationID, workspaceID: nil, title: "Synthetic rendering benchmark", createdAt: now, updatedAt: now)]
            model.activePage.messages = (1...50).flatMap { index in
                [Message(id: .init(), conversationID: conversationID, executionID: nil, sequence: index * 2 - 1,
                         role: .user, status: .committed, text: "Synthetic history turn \(index).", createdAt: now),
                 Message(id: .init(), conversationID: conversationID, executionID: nil, sequence: index * 2,
                         role: .assistant, status: .committed, text: Self.section(index), createdAt: now)]
            }
            let trigger = Message(id: .init(), conversationID: conversationID, executionID: nil, sequence: 101,
                                  role: .user, status: .committed, text: "Render the synthetic long response.", createdAt: now)
            model.activePage.messages.append(trigger)
            let route = ResolvedModelRouteSnapshot(name: "Synthetic benchmark", providerKind: .openAICompatible,
                                                  baseURL: "https://benchmark.invalid/v1", modelID: "synthetic",
                                                  credentialReference: "benchmark", contextWindow: 131_072)
            model.activePage.executions = [.init(id: executionID, conversationID: conversationID, triggerMessageID: trigger.id,
                                      status: .waitingForModel, route: route, createdAt: now, updatedAt: now)]
            model.activePage.streamBuffer.replace(drafts: [executionID: ""], thinkingTraces: [:])
        }

        func recordProbe(enqueued: ContinuousClock.Instant) {
            let serviced = ContinuousClock.now
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            samples.append(.init(phase: phase, elapsedSeconds: seconds(started.duration(to: serviced)),
                                 serviceMilliseconds: seconds(enqueued.duration(to: serviced)) * 1_000,
                                 residentBytes: status == KERN_SUCCESS ? info.resident_size : nil,
                                 appActive: NSApp.isActive, windowVisible: NSApp.windows.contains { $0.occlusionState.contains(.visible) }))
            if phase == "streaming" { model.activePage.composer = "Synthetic unsent input \(samples.count)" }
        }

        func scroll(index: Int) {
            func descendants(_ view: NSView) -> [ListScrollView] {
                (view as? ListScrollView).map { [$0] } ?? view.subviews.flatMap(descendants)
            }
            guard let root = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
                  let scroll = descendants(root).first(where: { $0.accessibilityIdentifier() == "conversation.transcript" })
            else { return }
            nativeScrollViewFound = true
            let target = index.isMultiple(of: 2) ? scroll.minimumContentOffset : scroll.maximumContentOffset
            scroll.setContentOffset(target, animated: false)
            scrollPositions.append(scroll.contentOffset.y)
        }

        static func section(_ index: Int) -> String {
            """
            ## Section \(index)

            This synthetic paragraph exercises stable Markdown measurement, **emphasis**, `inline code`, and [links](https://www.swift.org). Longer text wraps naturally as the window resizes while completed history remains selectable.

            - A list item with sufficient text to wrap across a narrow window and exercise paragraph layout.
            - Another item with **strong text** and a short explanation.

            > A quote that remains visible during fast scrolling and subsequent layout updates.

            ```swift
            let section = \(index)
            print((0..<8).map { $0 * section })
            ```

            | Column A | Column B | Column C |
            | --- | --- | --- |
            | A wrapping value for section \(index) | Another longer value | Complete |
            | One | Two | Three |
            """
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private static func percentile(_ values: [Double], _ quantile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        return values[max(0, Int(ceil(Double(values.count) * quantile)) - 1)]
    }
    private struct Sample: Encodable {
        let phase: String
        let elapsedSeconds: Double
        let serviceMilliseconds: Double
        let residentBytes: UInt64?
        let appActive: Bool
        let windowVisible: Bool
    }
    private struct PhaseSummary: Encodable {
        let phase: String
        let count: Int
        let p50: Double
        let p95: Double
        let maximum: Double
    }
    private struct Report: Encodable {
        let schema: Int
        let os: String
        let physicalMemoryBytes: UInt64
        let processorCount: Int
        let elapsedSeconds: Double
        let historyMessageCount: Int
        let historyUTF8Bytes: Int
        let streamedUTF8Bytes: Int
        let thinkingUTF8Bytes: Int
        let thinkingExpanded: Bool
        let nativeScrollViewFound: Bool
        let scrollPositions: [Double]
        let summaries: [PhaseSummary]
        let samples: [Sample]
        let limitations: [String]
    }
}

#endif
