#if DEBUG
    import AppKit
    import Foundation
    import ListViewKit
    import MiraCore

    /// Opt-in presentation benchmark backed by the real application runtime.
    /// The benchmark fixture is a local driver; it never uses credentials or a provider.
    @MainActor
    enum NativePerformanceBenchmark {
        private static func argument(_ flag: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.filter({ $0 == flag }).count == 1,
                let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
                arguments[index + 1].hasPrefix("/")
            else { return nil }
            return arguments[index + 1]
        }

        static var isRequested: Bool {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("--demo"), arguments.contains("--native-rendering-benchmark"),
                let report = argument("--benchmark-report"), argument("--data-directory") != nil
            else { return false }
            let parent = URL(fileURLWithPath: report).deletingLastPathComponent().path
            return !FileManager.default.fileExists(atPath: report) && FileManager.default.isWritableFile(atPath: parent)
        }

        static func run(model: ConversationModel) async {
            guard isRequested,
                let reportPath = argument("--benchmark-report"), !FileManager.default.fileExists(atPath: reportPath)
            else { return }
            guard let group = await waitForWorkgroup(model) else {
                if !Task.isCancelled {
                    write(
                        [
                            "schema": 2, "passed": false,
                            "error": "The application runtime did not become ready before the benchmark deadline.",
                        ],
                        to: URL(fileURLWithPath: reportPath))
                }
                return
            }
            do {
                let ids = try await MacBenchmarkModule.seed(in: group)
                await model.reload()
                if ProcessInfo.processInfo.arguments.contains("--verify-conversation-switching") {
                    await ConversationSwitchBenchmark.run(model: model, conversationIDs: ids)
                } else {
                    await Run(model: model, conversationIDs: ids).perform(reportURL: URL(fileURLWithPath: reportPath))
                }
            } catch {
                write(
                    ["schema": 2, "passed": false, "error": MiraError.safe(error).message],
                    to: URL(fileURLWithPath: reportPath))
            }
        }

        @MainActor
        private final class Run {
            let model: ConversationModel
            let conversationIDs: [ConversationID]
            let started = ContinuousClock.now

            init(model: ConversationModel, conversationIDs: [ConversationID]) {
                self.model = model
                self.conversationIDs = conversationIDs
            }

            func perform(reportURL: URL) async {
                guard let first = conversationIDs.first else {
                    write(
                        ["schema": 2, "passed": false, "error": "The benchmark fixture has no session."], to: reportURL)
                    return
                }
                await model.selectConversation(first)
                await model.activePage.loadTask?.value
                if ProcessInfo.processInfo.arguments.contains("--verify-floating-composer") {
                    await verifyFloatingComposer(reportURL: reportURL)
                    return
                }
                if ProcessInfo.processInfo.arguments.contains("--verify-markdown-layout") {
                    await verifyMarkdownLayout(reportURL: reportURL)
                    return
                }

                let initialCount = model.activePage.messages.count
                let initialRevision = model.activePage.inspectionRevision
                let selectionStart = ContinuousClock.now
                model.activePage.composer = "Synthetic unsent input"
                try? await Task.sleep(for: .milliseconds(120))
                let composerLatency = milliseconds(selectionStart.duration(to: .now))
                let list = NativePerformanceBenchmark.findList(for: first)
                let scrollStart = ContinuousClock.now
                var scrollPositions: [Double] = []
                if let list {
                    for index in 0..<12 {
                        list.setContentOffset(
                            index.isMultiple(of: 2) ? list.minimumContentOffset : list.maximumContentOffset,
                            animated: false)
                        scrollPositions.append(Double(list.contentOffset.y))
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                }
                let elapsed = milliseconds(started.duration(to: .now))
                let report: [String: Any] = [
                    "schema": 2,
                    "passed": initialCount > 0 && model.activePage.messages.count == initialCount
                        && list?.content.isEmpty == false,
                    "conversationIDs": conversationIDs.map { $0.rawValue.uuidString },
                    "historyMessageCount": initialCount,
                    "inspectionRevision": initialRevision,
                    "composerLatencyMs": composerLatency,
                    "scrollObservationIntervalMs": milliseconds(scrollStart.duration(to: .now)),
                    "nativeListMounted": list != nil,
                    "scrollPositions": scrollPositions,
                    "elapsedSeconds": elapsed / 1_000,
                    "limitations": [
                        "The local driver produces committed deterministic replies; this run does not measure provider latency.",
                        "This benchmark measures committed local-driver output; streaming and cancellation remain separate runtime tests.",
                        "Composer and scrolling are programmatic probes, not hardware input or frame-rate measurements.",
                    ],
                ]
                NativePerformanceBenchmark.write(report, to: reportURL)
            }

            private func verifyFloatingComposer(reportURL: URL) async {
                var mountedList: ListView<NativeTranscriptToken>?
                for _ in 0..<100 {
                    if let first = conversationIDs.first,
                       let list = NativePerformanceBenchmark.findList(for: first),
                       !list.content.isEmpty, list.viewportSize.height > 0 {
                        mountedList = list
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard let list = mountedList else {
                    NativePerformanceBenchmark.write(
                        ["schema": 2, "passed": false, "error": "The native transcript did not mount."], to: reportURL)
                    return
                }
                model.activePage.readingState.scrollState.jumpToLatest()
                try? await Task.sleep(for: .milliseconds(600))
                let window = NSApp.windows.first(where: { $0.isVisible })
                var scenarios: [[String: Any]] = []
                for (name, size, lines) in [
                    ("short-input", CGSize(width: 1_100, height: 760), 1),
                    ("multiline-input", CGSize(width: 1_100, height: 760), 8),
                    ("shrink-input", CGSize(width: 1_100, height: 760), 1),
                    ("minimum-narrow", CGSize(width: 850, height: 620), 8),
                ] {
                    window?.setContentSize(size)
                    model.activePage.composer = (1...lines).map { "Synthetic input line \($0)" }.joined(separator: "\n")
                    try? await Task.sleep(for: .milliseconds(600))
                    let row = list.content.isEmpty ? .zero : list.rectForRow(at: list.content.count - 1)
                    let scrollFrame = list.convert(list.bounds, to: nil)
                    let clipFrame = list.contentView.convert(list.contentView.bounds, to: nil)
                    func backdrops(in view: NSView) -> [MiraComposerBackdropView] {
                        if let surface = view as? MiraComposerBackdropView { return [surface] }
                        return view.subviews.flatMap { backdrops(in: $0) }
                    }
                    // The cached empty draft may retain a shorter backdrop. Use
                    // the uppermost surface so it cannot understate occlusion.
                    let surface = window?.contentView.flatMap { root in
                        backdrops(in: root).max { lhs, rhs in
                            lhs.convert(lhs.bounds, to: nil).maxY < rhs.convert(rhs.bounds, to: nil).maxY
                        }
                    }
                    let surfaceFrame = surface.map { $0.convert($0.bounds, to: nil) } ?? .zero
                    let lastRowFrame = list.rowContainer.convert(row, to: nil)
                    let fullViewport = scrollFrame.contains(surfaceFrame) && abs(clipFrame.height - scrollFrame.height) < 1
                    let lastRowClearance = lastRowFrame.minY - surfaceFrame.maxY
                    let clearBottom = list.bounds.height - list.bottomContentPadding
                    let gap = clearBottom - (row.maxY - list.contentOffset.y)
                    scenarios.append([
                        "scenario": name, "clearance": gap, "overlayHeight": list.bottomContentPadding,
                        "fullViewportBehindComposer": fullViewport,
                        "lastRowClearanceAboveSurface": lastRowClearance,
                        "nativeBottomInset": list.contentInsets.bottom,
                        "passed": surface != nil && fullViewport && list.contentInsets.bottom == 0
                            && list.bounds.height > 400 && list.bottomContentPadding > 100
                            && gap >= -1 && lastRowClearance >= 0,
                    ])
                }
                NativePerformanceBenchmark.write(
                    [
                        "schema": 2, "scenarios": scenarios,
                        "passed": scenarios.allSatisfy { $0["passed"] as? Bool == true },
                        "limitations": [
                            "The fixture uses the mounted transcript and composer with programmatic text. Locale and appearance are not changed by this headless probe."
                        ],
                    ], to: reportURL)
            }

            private func verifyMarkdownLayout(reportURL: URL) async {
                guard let first = conversationIDs.first, let list = NativePerformanceBenchmark.findList(for: first)
                else {
                    NativePerformanceBenchmark.write(
                        ["schema": 2, "passed": false, "error": "The native transcript did not mount."], to: reportURL)
                    return
                }
                let window = NSApp.windows.first(where: { $0.isVisible })
                var samples = 0
                var maximumScrollDrift: CGFloat = 0
                for size in [CGSize(width: 1_100, height: 760), CGSize(width: 850, height: 620)] {
                    window?.setContentSize(size)
                    list.setContentOffset(list.maximumContentOffset, animated: false)
                    try? await Task.sleep(for: .milliseconds(200))
                    let baseline = list.contentOffset.y
                    for _ in 0..<8 {
                        list.layoutSubtreeIfNeeded()
                        maximumScrollDrift = max(maximumScrollDrift, abs(list.contentOffset.y - baseline))
                        samples += 1
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                }
                NativePerformanceBenchmark.write(
                    [
                        "schema": 2, "samples": samples,
                        "maximumScrollDrift": maximumScrollDrift, "nativeListMounted": true,
                        "passed": samples > 0 && maximumScrollDrift < 1,
                        "limitations": [
                            "Markdown is measured from committed local-driver content; no live token stream is synthesized."
                        ],
                    ], to: reportURL)
            }
        }

        static func findList(for conversationID: ConversationID) -> ListView<NativeTranscriptToken>? {
            func descend(_ view: NSView) -> ListView<NativeTranscriptToken>? {
                if let viewport = view as? NativeTranscriptViewport, viewport.isActive,
                    viewport.conversationID == conversationID
                {
                    return viewport.subviews.compactMap { $0 as? ListView<NativeTranscriptToken> }.first
                }
                for child in view.subviews { if let list = descend(child) { return list } }
                return nil
            }
            return NSApp.windows.first(where: { $0.isVisible })?.contentView.flatMap(descend)
        }

        static func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        }

        static func write(_ value: [String: Any], to url: URL) {
            guard JSONSerialization.isValidJSONObject(value),
                let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? data.write(to: url, options: .withoutOverwriting)
        }

        private static func waitForWorkgroup(_ model: ConversationModel) async -> MacLibraryWorkloads? {
            for _ in 0..<100 {
                if Task.isCancelled { return nil }
                if model.isReady, let group = model.workgroup { return group }
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return nil
                }
            }
            return nil
        }
    }
#endif
