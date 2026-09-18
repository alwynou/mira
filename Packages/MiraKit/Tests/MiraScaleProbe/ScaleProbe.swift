import Darwin
import Foundation
import MiraCore
import MiraData

/// An explicit, synthetic storage measurement tool. It is absent from the app's dependency graph.
@main
struct ScaleProbe {
    static let format = "mira-session-scale-v1"
    static let turns = 50
    static let textBytes = 1_024

    struct Manifest: Codable {
        let format: String
        let sessions: Int
        let messagesPerSession: Int
        let textBytes: Int
    }

    struct Measurement: Encodable {
        let operation: String
        let sessions: Int
        let messages: Int
        let milliseconds: [String: Double]
        let peakRSSBytes: Int
        let userCPUSeconds: Double
        let systemCPUSeconds: Double
        let details: [String: Int]?
    }

    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            throw failure("Use seed DIRECTORY SESSIONS, read DIRECTORY, rebuild DIRECTORY, runtime DIRECTORY, or archive CORPUS NEW_OUTPUT_DIRECTORY.")
        }
        let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
        switch arguments[1] {
        case "seed":
            guard arguments.count == 4, let count = Int(arguments[3]), (1...1_000).contains(count) else {
                throw failure("The synthetic session count must be between 1 and 1000.")
            }
            try await seed(root, count: count)
        case "read", "rebuild":
            guard arguments.count == 3 else { throw failure("Unexpected measurement arguments.") }
            try await measure(root, rebuild: arguments[1] == "rebuild")
        case "runtime":
            guard arguments.count == 3 else { throw failure("Unexpected measurement arguments.") }
            try await measureRuntime(root)
        case "archive":
            guard arguments.count == 4 else { throw failure("Use archive CORPUS NEW_OUTPUT_DIRECTORY.") }
            try await measureArchive(root, output: URL(fileURLWithPath: arguments[3], isDirectory: true))
        default: throw failure("Unknown measurement operation.")
        }
    }

    static func seed(_ root: URL, count: Int) async throws {
        // Never overwrite an existing directory, including a previous synthetic corpus.
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw failure("The seed destination must not exist.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let start = ContinuousClock.now
        let library = try FileSessionLibrary(directory: root.appendingPathComponent("Sessions"))
        let plan = AgentExecutionPlan(
            runtimeID: identifier(1, 0), catalogGeneration: 1,
            driverID: "scale.local", driverRevision: 1, instructions: "Return the synthetic local answer.",
            limits: .init(), priority: .foreground, route: nil)
        try plan.validate()
        for ordinal in 0..<count {
            let sessionID = ConversationID(identifier(2, ordinal))
            var state = SessionState(id: sessionID)
            var batchID = identifier(3, ordinal * 1_000)
            let title = try await library.stage(
                Data("Synthetic session \(ordinal)".utf8), sessionID: sessionID,
                batchID: batchID, kind: .title)
            try await append(
                [.opened(.init(workspaceID: nil, title: title))],
                batchID: batchID, state: &state, library: library)
            for turn in 0..<turns {
                let key = ordinal * 1_000 + turn + 1
                let executionID = ExecutionID(identifier(5, key))
                batchID = identifier(6, key)
                let user = try await library.stage(
                    Data(body(session: ordinal, turn: turn, role: "user").utf8),
                    sessionID: sessionID, batchID: batchID, kind: .userText)
                let planReference = try await library.stage(
                    SessionCodec.encode(plan), sessionID: sessionID,
                    batchID: batchID, kind: .executionPlan)
                try await append(
                    [
                        .admitted(
                            .init(
                                executionID: executionID, userMessageID: MessageID(identifier(9, key)),
                                userBody: user, plan: planReference, hasModelRoute: false,
                                authorizationEpoch: state.authorizationEpoch, timeZoneIdentifier: "UTC"))
                    ],
                    batchID: batchID, state: &state, library: library)
                batchID = identifier(10, key)
                let text = body(session: ordinal, turn: turn, role: "assistant")
                let answer = try await library.stage(
                    Data(text.utf8), sessionID: sessionID, batchID: batchID,
                    kind: .visibleAnswer)
                try await append(
                    [
                        .phaseChanged(executionID: executionID, phase: .settling),
                        .finished(
                            .init(
                                executionID: executionID, status: .completed,
                                assistantMessageID: MessageID(identifier(13, key)), answer: answer)),
                    ],
                    batchID: batchID, state: &state, library: library)
            }
            guard state.executionOrder.count == turns, state.activeExecutionID == nil else {
                throw failure("The synthetic session did not settle.")
            }
            // Seed through the real reducer and durable stores. Seeding time is not runtime throughput.
            let restored = try await JournalSessionReader(journal: library, payloads: library).snapshot(
                sessionID: sessionID)
            guard restored.state == state else {
                throw failure("The persisted synthetic session did not replay exactly.")
            }
            if (ordinal + 1).isMultiple(of: 10) {
                FileHandle.standardError.write(Data("Seeded \((ordinal + 1) * turns * 2) synthetic messages.\n".utf8))
            }
        }
        try await library.close()
        let manifest = Manifest(format: format, sessions: count, messagesPerSession: turns * 2, textBytes: textBytes)
        try SessionCodec.encode(manifest).write(to: root.appendingPathComponent("scale.json"), options: .atomic)
        try emit(operation: "seed", count: count, times: ["seed": ms(start)])
    }

    static func measure(_ root: URL, rebuild: Bool) async throws {
        let manifest = try SessionCodec.decode(
            Manifest.self, from: Data(contentsOf: root.appendingPathComponent("scale.json")))
        guard manifest.format == format, (1...1_000).contains(manifest.sessions),
            manifest.messagesPerSession == turns * 2, manifest.textBytes == textBytes
        else {
            throw failure("The synthetic corpus manifest is invalid.")
        }
        let start = ContinuousClock.now
        let library = try FileSessionLibrary(directory: root.appendingPathComponent("Sessions"))
        var times = ["journalOpen": ms(start)]
        let projectionStart = ContinuousClock.now
        let projection = try SQLiteSessionProjection(path: root.appendingPathComponent("projection.sqlite").path)
        times["projectionOpen"] = ms(projectionStart)
        let coordinator = try SessionProjectionCoordinator(journal: library, projection: projection)
        let syncStart = ContinuousClock.now
        for ordinal in 0..<manifest.sessions {
            let sessionID = ConversationID(identifier(2, ordinal))
            if rebuild {
                _ = try await coordinator.rebuild(sessionID: sessionID)
            } else {
                _ = try await coordinator.catchUp(sessionID: sessionID)
            }
        }
        times[rebuild ? "fullProjectionRebuild" : "libraryCatchUp"] = ms(syncStart)
        let id = ConversationID(identifier(2, manifest.sessions - 1))
        let pageStart = ContinuousClock.now
        let page = try await projection.messagePage(sessionID: id, beforeSequence: nil, limit: 12)
        guard page.messages.count == 12, page.hasMore else { throw failure("The latest page is incomplete.") }
        for (offset, row) in page.messages.enumerated() {
            guard let reference = row.body,
                try await library.read(reference)
                    == Data(
                        body(
                            session: manifest.sessions - 1,
                            turn: turns - 1 - offset / 2, role: offset.isMultiple(of: 2) ? "assistant" : "user"
                        ).utf8)
            else {
                throw failure("The visible message content or ordering is incorrect.")
            }
        }
        times["visiblePage"] = ms(pageStart)
        times["localStoreReady"] = ms(start)
        let checkpointStart = ContinuousClock.now
        let snapshot = try await JournalSessionReader(journal: library, payloads: library).snapshot(sessionID: id)
        guard snapshot.state.executionOrder.count == turns, snapshot.state.activeExecutionID == nil,
            snapshot.state.executions.values.allSatisfy({ $0.completion?.status == .completed })
        else {
            throw failure("The restored checkpoint is inconsistent.")
        }
        times["selectedCheckpoint"] = ms(checkpointStart)
        if rebuild {
            var total = 0
            for ordinal in 0..<manifest.sessions {
                let rows = try await projection.messages(
                    sessionID: ConversationID(identifier(2, ordinal)),
                    beforeSequence: nil, limit: 128)
                guard rows.count == turns * 2 else {
                    throw failure("The rebuilt session has an incorrect message count.")
                }
                total += rows.count
            }
            guard total == manifest.sessions * turns * 2 else {
                throw failure("The rebuilt corpus count is incorrect.")
            }
        }
        await coordinator.close()
        try await projection.close()
        try await library.close()
        try emit(operation: rebuild ? "rebuild" : "read", count: manifest.sessions, times: times)
    }

    static func append(
        _ facts: [SessionFact], batchID: UUID, state: inout SessionState,
        library: FileSessionLibrary
    ) async throws {
        let batch = SessionBatch(
            id: batchID, sessionID: state.id, expectedSequence: state.sequence,
            events: facts.enumerated().map { offset, fact in
                .init(
                    id: eventIdentifier(batchID, offset: offset),
                    sequence: state.sequence + Int64(offset) + 1,
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(state.sequence + Int64(offset))),
                    fact: fact)
            })
        try state.apply(batch)
        guard await library.append(batch) == .committed(batch.cursor) else {
            throw failure("A synthetic batch did not commit.")
        }
    }

    static func identifier(_ namespace: Int, _ ordinal: Int) -> UUID {
        UUID(uuidString: String(format: "%08X-0000-4000-8000-%012llX", namespace, Int64(ordinal)))!
    }

    static func eventIdentifier(_ batchID: UUID, offset: Int) -> UUID {
        var bytes = batchID.uuid
        bytes.0 = UInt8(128 + offset)
        return UUID(uuid: bytes)
    }

    static func body(session: Int, turn: Int, role: String) -> String {
        let prefix =
            "Synthetic \(role) session=\(session) turn=\(turn). Sources/MiraCore/Runtime.swift literal \"quote\" % _ [bracket]. "
        return prefix + String(repeating: "x", count: textBytes - prefix.utf8.count)
    }

    static func ms(_ start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }

    static func emit(operation: String, count: Int, times: [String: Double], details: [String: Int]? = nil) throws {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw failure("Cannot read process resource usage.") }
        let result = Measurement(
            operation: operation, sessions: count, messages: count * turns * 2,
            milliseconds: times, peakRSSBytes: Int(usage.ru_maxrss),
            userCPUSeconds: Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6,
            systemCPUSeconds: Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6, details: details)
        print(String(decoding: try SessionCodec.encode(result), as: UTF8.self))
    }

    static func failure(_ message: String) -> MiraError { .init(.invalidInput, message) }
}
