import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Semantic session journal", .timeLimit(.minutes(1)))
struct SemanticSessionJournalTests {
    @Test func settledStepsReuseExactRequestBodiesAndKeepPresentationOrder() async throws {
        let calls = try taskReplies(taskArguments(quote: "Question"))
        let first: [AgentModelStreamEvent] = [
            .blockStarted(.init(id: "opening-text", content: .text("Before thinking"))),
            .blockFinished(id: "opening-text"),
            .blockStarted(.init(id: "middle-thinking", content: .thinking("Consider the task"))),
            .blockFinished(id: "middle-thinking")
        ] + calls[0]
        let final: [AgentModelStreamEvent] = [
            .blockStarted(.init(id: "last-text", content: .text("Saved"))),
            .blockFinished(id: "last-text"),
            .blockStarted(.init(id: "last-thinking", content: .thinking("Checked"))),
            .blockFinished(id: "last-thinking"), .finished(.stop)
        ]
        try await withTaskWorkflow(outputs: [first, final], thinkingEnabled: true) { fixture in
            let address = try await fixture.run("Question")
            let state = try await fixture.runtime.sessionSnapshot(id: address.sessionID)
            let execution = try #require(state.executions[address.executionID])
            let attempts = execution.attemptIDs.compactMap { state.attempts[$0] }
            #expect(attempts.count == 2)
            let inputs = await fixture.model.inputs
            #expect(inputs.count == 2)
            var manifests: [AgentRequestManifest] = []
            for (index, attempt) in attempts.enumerated() {
                let record = try await AgentRequestRecord.read(attempt.attempt.request, payloads: fixture.library)
                #expect(record.input == inputs[index])
                let manifest = try SessionCodec.decode(AgentRequestManifest.self, from: await fixture.library.read(attempt.attempt.request))
                manifests.append(manifest)
                #expect(Set(attempt.attempt.contents) == Set([manifest.header] + manifest.entries.map(\.reference)))
            }
            #expect(manifests[0].header == manifests[1].header)
            let originalUser = try #require(execution.admission.userBody)
            #expect(manifests.allSatisfy { $0.entries.contains { $0.reference == originalUser } })
            let firstOutput = try #require(attempts[0].resolution?.output)
            #expect(manifests[1].entries.contains { $0.reference == firstOutput && $0.representation == .modelOutput })
            let toolResult = try #require(attempts[0].invocationIDs.first.flatMap { state.invocations[$0]?.resolution?.result })
            #expect(manifests[1].entries.contains { $0.reference == toolResult && $0.representation == .toolResult })
            let replayRef = try #require(execution.completion?.replay)
            let replayManifest = try await AgentReplayManifest.metadata(replayRef, payloads: fixture.library)
            #expect(replayManifest.items.allSatisfy { if case .content = $0 { true } else { false } })
            let replay = try await AgentReplayManifest.read(replayRef, state: state, payloads: fixture.library)
            #expect(replay.messages.first?.blocks.map(\.id).prefix(2) == ["opening-text", "middle-thinking"])
            #expect(replay.messages.last?.blocks.map(\.id) == ["last-text", "last-thinking"])
            #expect(try await fixture.library.activeDraft(sessionID: address.sessionID) == nil)

            let snapshot = try await JournalSessionReader(journal: fixture.library, payloads: fixture.library).snapshot(sessionID: address.sessionID)
            let activity = try await SessionActivityReader.read(snapshot: snapshot, sessionID: address.sessionID,
                executionIDs: [address.executionID], maximumPageBytes: 8 * 1_024 * 1_024,
                journal: fixture.library, payloads: fixture.library)
            #expect(activity[address.executionID]?.first?.blocks.map(\.id) == replay.messages.first?.blocks.map(\.id))
            #expect(activity[address.executionID]?.last?.blocks.map(\.id) == replay.messages.last?.blocks.map(\.id))
            let url = fixture.directory.appendingPathComponent("sessions/sessions/\(address.sessionID.rawValue.uuidString).jsonl")
            let bytes = try Data(contentsOf: url)
            let lines = try bytes.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
            let types = lines.compactMap { $0["type"] as? String }
            #expect(!types.contains("response_delta"))
            #expect(types.filter { $0 == "assistant/message" }.count == 2)
            #expect(types.filter { $0 == "request/start" }.count == 2)
            #expect(types.filter { $0 == "turn/end" }.count == 1)
            let journalOutput = lines.filter { $0["type"] as? String == "assistant/message" }.compactMap { line -> [String]? in
                guard let payload = line["payload"] as? [String: Any], let output = payload["output"] as? [String: Any],
                      let json = output["json"] as? [String: Any], let blocks = json["blocks"] as? [[String: Any]] else { return nil }
                return blocks.compactMap { $0["id"] as? String }
            }
            #expect(journalOutput.first == replay.messages.first?.blocks.map(\.id))
            #expect(journalOutput.last == replay.messages.last?.blocks.map(\.id))
            if let evidence = ProcessInfo.processInfo.environment["MIRA_JOURNAL_EVIDENCE_PATH"] {
                let destination = URL(fileURLWithPath: evidence)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: destination)
            }
        }
    }
}
