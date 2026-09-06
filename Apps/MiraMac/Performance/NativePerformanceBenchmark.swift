#if DEBUG
import AppKit
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
                model.streamBuffer.receiveThinking(trace, for: executionID)
                let characters = Array(text)
                for end in stride(from: 50, to: characters.count + 50, by: 50) {
                    try Task.checkCancellation()
                    model.streamBuffer.receiveDraft(String(characters.prefix(min(end, characters.count))), for: executionID)
                    try await Task.sleep(for: .milliseconds(100))
                }
                model.streamBuffer.flush()
                model.messages.append(.init(id: .init(), conversationID: conversationID, executionID: executionID,
                                            sequence: 102, role: .assistant, status: .committed, text: text, createdAt: Date(), trace: trace))
                model.executions[0].status = .completed
                model.streamBuffer.replace(drafts: [:], thinkingTraces: [:])
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

        static var osVersion: String {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }

        func installHistory() {
            let now = Date()
            model.selectedConversationID = conversationID
            model.conversations = [.init(id: conversationID, workspaceID: nil, title: "Synthetic rendering benchmark", createdAt: now, updatedAt: now)]
            model.messages = (1...50).flatMap { index in
                [Message(id: .init(), conversationID: conversationID, executionID: nil, sequence: index * 2 - 1,
                         role: .user, status: .committed, text: "Synthetic history turn \(index).", createdAt: now),
                 Message(id: .init(), conversationID: conversationID, executionID: nil, sequence: index * 2,
                         role: .assistant, status: .committed, text: Self.section(index), createdAt: now)]
            }
            let trigger = Message(id: .init(), conversationID: conversationID, executionID: nil, sequence: 101,
                                  role: .user, status: .committed, text: "Render the synthetic long response.", createdAt: now)
            model.messages.append(trigger)
            let route = ResolvedModelRouteSnapshot(name: "Synthetic benchmark", providerKind: .openAICompatible,
                                                  baseURL: "https://benchmark.invalid/v1", modelID: "synthetic",
                                                  credentialReference: "benchmark", contextWindow: 131_072)
            model.executions = [.init(id: executionID, conversationID: conversationID, triggerMessageID: trigger.id,
                                      status: .waitingForModel, route: route, createdAt: now, updatedAt: now)]
            model.streamBuffer.replace(drafts: [executionID: ""], thinkingTraces: [:])
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
            if phase == "streaming" { model.composer = "Synthetic unsent input \(samples.count)" }
        }

        func scroll(index: Int) {
            func descendants(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(descendants)
            }
            guard let root = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
                  let scroll = descendants(root).filter({ $0.bounds.width > 400 && ($0.documentView?.bounds.height ?? 0) > $0.bounds.height + 500 })
                    .max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }),
                  let document = scroll.documentView else { return }
            nativeScrollViewFound = true
            let maximum = max(0, document.bounds.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: index.isMultiple(of: 2) ? 0 : maximum))
            scroll.reflectScrolledClipView(scroll.contentView)
            scrollPositions.append(scroll.contentView.bounds.origin.y)
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
