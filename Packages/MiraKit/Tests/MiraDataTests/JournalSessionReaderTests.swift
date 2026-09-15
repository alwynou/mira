import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Journal session reader", .timeLimit(.minutes(1)))
struct JournalSessionReaderTests {
    @Test("A fixed journal head excludes later committed batches")
    func fixedHeadIsImmutable() async throws {
        try await withReaderFixture { fixture in
            let reader = JournalSessionReader(journal: fixture.library, payloads: fixture.library)
            let head = try await fixture.library.head(sessionID: fixture.sessionID)
            let before = try await reader.snapshot(through: head)

            let renamed = await fixture.runtime.commit(id: UUID()) { context in
                let title = try await context.stageBytes(Data("Renamed".utf8), kind: .title, retentionGroup: UUID())
                return [.renamed(title: title, revision: 2)]
            }
            try requireCommitted(renamed)
            let replayedOld = try await reader.snapshot(through: head)
            let after = try await reader.snapshot(sessionID: fixture.sessionID)
            #expect(replayedOld == before)
            #expect(replayedOld.head == head)
            #expect(replayedOld.state.sequence == head.cursor.sequence)
            #expect(after.state.sequence > before.state.sequence)
            #expect(before.state.title != after.state.title)
        }
    }

    @Test("Reader rejects wrong heads, cursors inside a batch, and a missing page")
    func invalidHeadAndGapAreRejected() async throws {
        try await withReaderFixture { fixture in
            let reader = JournalSessionReader(journal: fixture.library, payloads: fixture.library)
            let head = try await fixture.library.head(sessionID: fixture.sessionID)
            let wrongHead = SessionJournalHead(cursor: head.cursor, batchID: UUID())
            await #expect(throws: MiraError.self) { _ = try await reader.snapshot(through: wrongHead) }
            let internalCursor = SessionCursor(sessionID: fixture.sessionID, sequence: head.cursor.sequence - 1)
            await #expect(throws: MiraError.self) { _ = try await reader.snapshot(through: internalCursor) }

            let gap = ForwardingJournal(base: fixture.library, mode: .empty)
            let gapReader = JournalSessionReader(journal: gap, payloads: fixture.library)
            await #expect(throws: MiraError.self) { _ = try await gapReader.snapshot(through: head) }
        }
    }

    @Test("Retry evidence resolves the original admission event, sequence, body and time zone")
    func retryUsesOriginalEvidence() async throws {
        try await withReaderFixture { fixture in
            let retryID = try await fixture.appendRetry()
            let reader = JournalSessionReader(journal: fixture.library, payloads: fixture.library)
            let evidence = try await reader.userEvidence(sessionID: fixture.sessionID, executionID: retryID)
            #expect(evidence.text == "Question")
            #expect(evidence.admittedAt == fixture.admittedAt)
            #expect(evidence.timeZoneIdentifier == "Asia/Shanghai")
            #expect(evidence.reference.originalExecutionID == fixture.executionID)
            #expect(evidence.reference.userMessageID == fixture.messageID)
            #expect(evidence.reference.admissionEventID == fixture.admissionEventID)
            #expect(evidence.reference.admissionSequence == fixture.admissionSequence)
            #expect(evidence.reference.body == fixture.userBody)
        }
    }

    @Test("Equal message and execution UUIDs remain isolated by session")
    func sessionIdentityIsPartOfEvidence() async throws {
        let sessionA = ConversationID()
        let sessionB = ConversationID()
        let execution = ExecutionID()
        let message = MessageID()
        try await withReaderLibrary { library in
            let first = try await ReaderFixture.appendInitial(to: library, sessionID: sessionA,
                                                              executionID: execution, messageID: message, text: "A")
            let second = try await ReaderFixture.appendInitial(to: library, sessionID: sessionB,
                                                               executionID: execution, messageID: message, text: "B")
            let reader = JournalSessionReader(journal: library, payloads: library)
            #expect(try await reader.userEvidence(sessionID: sessionA, executionID: execution).text == "A")
            #expect(try await reader.userEvidence(sessionID: sessionB, executionID: execution).text == "B")
            #expect(first.userBody.sessionID != second.userBody.sessionID)
        }
    }

    @Test("A mutated persisted evidence reference cannot be re-resolved")
    func mutatedEvidenceReferenceIsRejected() async throws {
        try await withReaderFixture { fixture in
            let reader = JournalSessionReader(journal: fixture.library, payloads: fixture.library)
            let valid = try await reader.userEvidence(sessionID: fixture.sessionID, executionID: fixture.executionID)
            let otherSession = ConversationID()
            let otherExecution = ExecutionID()
            let otherMessage = MessageID()
            let body = valid.reference.body
            let mutatedBodies = [
                SessionPayloadReference(id: UUID(), sessionID: body.sessionID, batchID: body.batchID,
                                        retentionGroup: body.retentionGroup, kind: body.kind,
                                        byteCount: body.byteCount, digest: body.digest),
                SessionPayloadReference(id: body.id, sessionID: otherSession, batchID: body.batchID,
                                        retentionGroup: body.retentionGroup, kind: body.kind,
                                        byteCount: body.byteCount, digest: body.digest),
                SessionPayloadReference(id: body.id, sessionID: body.sessionID, batchID: UUID(),
                                        retentionGroup: body.retentionGroup, kind: body.kind,
                                        byteCount: body.byteCount, digest: body.digest),
                SessionPayloadReference(id: body.id, sessionID: body.sessionID, batchID: body.batchID,
                                        retentionGroup: UUID(), kind: body.kind,
                                        byteCount: body.byteCount, digest: body.digest),
                SessionPayloadReference(id: body.id, sessionID: body.sessionID, batchID: body.batchID,
                                        retentionGroup: body.retentionGroup, kind: .title,
                                        byteCount: body.byteCount, digest: body.digest),
                SessionPayloadReference(id: body.id, sessionID: body.sessionID, batchID: body.batchID,
                                        retentionGroup: body.retentionGroup, kind: body.kind,
                                        byteCount: body.byteCount + 1, digest: body.digest),
                SessionPayloadReference(id: body.id, sessionID: body.sessionID, batchID: body.batchID,
                                        retentionGroup: body.retentionGroup, kind: body.kind,
                                        byteCount: body.byteCount, digest: String(repeating: "f", count: 64))
            ]
            let candidates = mutatedBodies.map { body in
                SessionEvidenceReference(sessionID: valid.reference.sessionID, originalExecutionID: valid.reference.originalExecutionID,
                    userMessageID: valid.reference.userMessageID, admissionEventID: valid.reference.admissionEventID,
                    admissionSequence: valid.reference.admissionSequence, body: body)
            } + [
                SessionEvidenceReference(sessionID: otherSession, originalExecutionID: valid.reference.originalExecutionID,
                    userMessageID: valid.reference.userMessageID, admissionEventID: valid.reference.admissionEventID,
                    admissionSequence: valid.reference.admissionSequence, body: body),
                SessionEvidenceReference(sessionID: valid.reference.sessionID, originalExecutionID: otherExecution,
                    userMessageID: valid.reference.userMessageID, admissionEventID: valid.reference.admissionEventID,
                    admissionSequence: valid.reference.admissionSequence, body: body),
                SessionEvidenceReference(sessionID: valid.reference.sessionID, originalExecutionID: valid.reference.originalExecutionID,
                    userMessageID: otherMessage, admissionEventID: valid.reference.admissionEventID,
                    admissionSequence: valid.reference.admissionSequence, body: body),
                SessionEvidenceReference(sessionID: valid.reference.sessionID, originalExecutionID: valid.reference.originalExecutionID,
                    userMessageID: valid.reference.userMessageID, admissionEventID: UUID(),
                    admissionSequence: valid.reference.admissionSequence, body: body),
                SessionEvidenceReference(sessionID: valid.reference.sessionID, originalExecutionID: valid.reference.originalExecutionID,
                    userMessageID: valid.reference.userMessageID, admissionEventID: valid.reference.admissionEventID,
                    admissionSequence: valid.reference.admissionSequence + 1, body: body)
            ]
            for candidate in candidates {
                await #expect(throws: MiraError.self) { _ = try await reader.userEvidence(candidate) }
            }
        }
    }

    @Test("Invalidating the origin makes user evidence unavailable")
    func excludedOriginCannotBeRead() async throws {
        try await withReaderFixture { fixture in
            let reader = JournalSessionReader(journal: fixture.library, payloads: fixture.library)
            let valid = try await reader.userEvidence(sessionID: fixture.sessionID, executionID: fixture.executionID)
            let invalidation = await fixture.runtime.commit(id: UUID()) { _ in
                [.invalidated(.init(operationID: UUID(), executionIDs: [fixture.executionID],
                                     retentionGroups: [fixture.userBody.retentionGroup, fixture.planBody.retentionGroup],
                                     authorizationEpoch: 1, reason: .forgotten))]
            }
            try requireCommitted(invalidation)
            await #expect(throws: MiraError.self) { _ = try await reader.userEvidence(valid.reference) }
        }
    }

    @Test("Invalid UTF8 in the authoritative user payload is a storage error")
    func invalidUserPayloadDoesNotBecomeEmptyText() async throws {
        try await withReaderFixture(userBytes: Data([0xff, 0xfe])) { fixture in
            let reader = JournalSessionReader(journal: fixture.library, payloads: fixture.library)
            do {
                _ = try await reader.userEvidence(sessionID: fixture.sessionID, executionID: fixture.executionID)
                Issue.record("invalid UTF8 was silently accepted")
            } catch let error as MiraError {
                #expect(error.code == .storage)
            }
        }
    }

    @Test("A missing physical user payload is a storage error")
    func missingUserPayloadIsStorageError() async throws {
        try await withReaderFixture { fixture in
            let payloadURL = fixture.directory.appendingPathComponent("payloads", isDirectory: true)
                .appendingPathComponent(fixture.userBody.sessionID.rawValue.uuidString, isDirectory: true)
                .appendingPathComponent(fixture.userBody.batchID.uuidString, isDirectory: true)
                .appendingPathComponent(fixture.userBody.id.uuidString + ".bin")
            try FileManager.default.removeItem(at: payloadURL)
            let reader = JournalSessionReader(journal: fixture.library, payloads: fixture.library)
            do {
                _ = try await reader.userEvidence(sessionID: fixture.sessionID, executionID: fixture.executionID)
                Issue.record("missing user payload was silently treated as empty text")
            } catch let error as MiraError {
                #expect(error.code == .storage)
            }
        }
    }

    @Test("Required unknown extensions and repeated pages fail closed")
    func boundedReaderRejectsUnsupportedOrRepeatingPages() async throws {
        try await withReaderFixture { fixture in
            let extensionBatchID = UUID()
            let body = try await fixture.library.stage(Data("extension".utf8), sessionID: fixture.sessionID,
                                                        batchID: extensionBatchID, retentionGroup: UUID(), kind: .module)
            let extensionHead = try await fixture.library.head(sessionID: fixture.sessionID)
            let extensionBatch = SessionBatch(id: extensionBatchID, sessionID: fixture.sessionID,
                expectedSequence: extensionHead.cursor.sequence,
                events: [.init(sequence: extensionHead.cursor.sequence + 1,
                                occurredAt: Date(), fact: .extensionRecorded(namespace: "reader.test", schemaVersion: 1,
                                                                            required: true, body: body))])
            #expect(await fixture.library.append(extensionBatch) == .committed(extensionBatch.cursor))
            let unsupportedReader = JournalSessionReader(journal: fixture.library, payloads: fixture.library)
            await #expect(throws: MiraError.self) { _ = try await unsupportedReader.snapshot(sessionID: fixture.sessionID) }

            let repeated = ForwardingJournal(base: fixture.library, mode: .repeatFirst)
            let repeatedReader = JournalSessionReader(journal: repeated, payloads: fixture.library)
            let head = try await fixture.library.head(sessionID: fixture.sessionID)
            await #expect(throws: MiraError.self) { _ = try await repeatedReader.snapshot(through: head) }
        }
    }
}

private final class ReaderFixture: @unchecked Sendable {
    let directory: URL
    let library: FileSessionLibrary
    let runtime: SessionRuntime
    let sessionID: ConversationID
    let executionID: ExecutionID
    let messageID: MessageID
    let userBody: SessionPayloadReference
    let planBody: SessionPayloadReference
    let admissionEventID: UUID
    let admissionSequence: Int64
    let admittedAt: Date

    static func make(sessionID: ConversationID = ConversationID(), executionID: ExecutionID = ExecutionID(),
                     messageID: MessageID = MessageID(), userBytes: Data = Data("Question".utf8)) async throws -> ReaderFixture {
        let directory = try temporaryDirectory()
        do {
            let library = try FileSessionLibrary(directory: directory)
            let runtime: SessionRuntime
            do {
                runtime = try await SessionRuntime.open(id: sessionID, journal: library, payloads: library)
            } catch {
                try? await library.close()
                throw error
            }
            do {
                let commandID = UUID()
                let result = await runtime.commit(id: commandID) { context in
                    let title = try await context.stageBytes(Data("Original".utf8), kind: .title, retentionGroup: UUID())
                    let user = try await context.stageBytes(userBytes, kind: .userText, retentionGroup: UUID())
                    let plan = try await context.stageBytes(Data("plan".utf8), kind: .executionPlan, retentionGroup: UUID())
                    return [.opened(.init(workspaceID: nil, title: title)),
                            .admitted(.init(executionID: executionID, userMessageID: messageID, userBody: user, plan: plan,
                                            hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: "Asia/Shanghai"))]
                }
                try requireCommitted(result)
                guard let batch = try await library.batch(id: commandID, sessionID: sessionID),
                      let last = batch.events.last,
                      case .admitted(let admission) = last.fact,
                      let userBody = admission.userBody else {
                    throw MiraError(.storage, "The synthetic admission was not persisted.")
                }
                return ReaderFixture(directory: directory, library: library, runtime: runtime, sessionID: sessionID,
                    executionID: executionID, messageID: messageID, userBody: userBody, planBody: admission.plan,
                    admissionEventID: last.id, admissionSequence: last.sequence, admittedAt: last.occurredAt)
            } catch {
                await runtime.close()
                try? await library.close()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func appendInitial(to library: FileSessionLibrary, sessionID: ConversationID, executionID: ExecutionID,
                              messageID: MessageID, text: String) async throws -> (userBody: SessionPayloadReference, admissionEventID: UUID) {
        let batchID = UUID()
        let title = try await library.stage(Data("Title".utf8), sessionID: sessionID, batchID: batchID, retentionGroup: UUID(), kind: .title)
        let body = try await library.stage(Data(text.utf8), sessionID: sessionID, batchID: batchID, retentionGroup: UUID(), kind: .userText)
        let plan = try await library.stage(Data("plan".utf8), sessionID: sessionID, batchID: batchID, retentionGroup: UUID(), kind: .executionPlan)
        let batch = SessionBatch(id: batchID, sessionID: sessionID, expectedSequence: 0, events: [
            .init(sequence: 1, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title))),
            .init(sequence: 2, occurredAt: Date(), fact: .admitted(.init(executionID: executionID, userMessageID: messageID,
                userBody: body, plan: plan, hasModelRoute: false, authorizationEpoch: 0, timeZoneIdentifier: "UTC")))])
        guard case .committed = await library.append(batch) else { throw MiraError(.storage, "The synthetic session was not committed.") }
        return (body, batch.events[1].id)
    }

    func appendRetry() async throws -> ExecutionID {
        let cancelled = await runtime.commit(id: UUID()) { _ in
            [.phaseChanged(executionID: executionID, phase: .cancelling),
             .finished(.init(executionID: executionID, status: .interrupted))]
        }
        try requireCommitted(cancelled)
        let retryID = ExecutionID()
        let result = await runtime.commit(id: UUID()) { context in
            let plan = try await context.stageBytes(Data("retry-plan".utf8), kind: .executionPlan, retentionGroup: UUID())
            return [.admitted(.init(executionID: retryID, userMessageID: messageID, retryOfExecutionID: executionID,
                                    userBody: nil, plan: plan, hasModelRoute: false, authorizationEpoch: 0,
                                    timeZoneIdentifier: "UTC"))]
        }
        try requireCommitted(result)
        return retryID
    }

    private init(directory: URL, library: FileSessionLibrary, runtime: SessionRuntime, sessionID: ConversationID,
                 executionID: ExecutionID, messageID: MessageID, userBody: SessionPayloadReference,
                 planBody: SessionPayloadReference,
                 admissionEventID: UUID, admissionSequence: Int64, admittedAt: Date) {
        self.directory = directory; self.library = library; self.runtime = runtime; self.sessionID = sessionID
        self.executionID = executionID; self.messageID = messageID; self.userBody = userBody; self.planBody = planBody
        self.admissionEventID = admissionEventID; self.admissionSequence = admissionSequence; self.admittedAt = admittedAt
    }

    func close() async {
        await runtime.close()
        try? await library.close()
    }

    func removeDirectory() { try? FileManager.default.removeItem(at: directory) }
}

private func withReaderFixture<T>(userBytes: Data = Data("Question".utf8),
                                 _ body: (ReaderFixture) async throws -> T) async throws -> T {
    let fixture = try await ReaderFixture.make(userBytes: userBytes)
    do {
        let result = try await body(fixture)
        await fixture.close()
        fixture.removeDirectory()
        return result
    } catch {
        await fixture.close()
        fixture.removeDirectory()
        throw error
    }
}

private func withReaderLibrary<T>(_ body: (FileSessionLibrary) async throws -> T) async throws -> T {
    let directory = try temporaryDirectory()
    do {
        let library = try FileSessionLibrary(directory: directory)
        do {
            let result = try await body(library)
            try await library.close()
            try? FileManager.default.removeItem(at: directory)
            return result
        } catch {
            try? await library.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

private final class ForwardingJournal: SessionJournal, @unchecked Sendable {
    enum Mode { case empty, repeatFirst }
    let base: any SessionJournal
    let mode: Mode
    init(base: any SessionJournal, mode: Mode) { self.base = base; self.mode = mode }
    func append(_ batch: SessionBatch) async -> SessionAppendOutcome { await base.append(batch) }
    func reconcile(_ batch: SessionBatch) async -> SessionAppendOutcome { await base.reconcile(batch) }
    func batch(id: UUID, sessionID: ConversationID) async throws -> SessionBatch? { try await base.batch(id: id, sessionID: sessionID) }
    func head(sessionID: ConversationID) async throws -> SessionJournalHead { try await base.head(sessionID: sessionID) }
    func read(sessionID: ConversationID, after sequence: Int64, limit: Int) async throws -> [SessionBatch] {
        switch mode {
        case .empty: return []
        case .repeatFirst: return Array((try await base.read(sessionID: sessionID, after: 0, limit: 1)).prefix(1))
        }
    }
    func sessions(after: ConversationID?, limit: Int) async throws -> [ConversationID] { try await base.sessions(after: after, limit: limit) }
    func flush() async throws { try await base.flush() }
    func close() async throws { try await base.close() }
}

private func requireCommitted(_ result: SessionCommitResult) throws {
    guard case .committed = result else { throw MiraError(.storage, "Synthetic session command did not commit: \(result).") }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-journal-reader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}
