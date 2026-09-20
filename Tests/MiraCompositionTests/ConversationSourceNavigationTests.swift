#if DEBUG
import Foundation
import MiraCore
import MiraData
import Testing

@Suite("conversation memory source navigation", .timeLimit(.minutes(1)))
@MainActor
struct ConversationSourceNavigationTests {
    @Test
    func oldSourceLoadsContiguousHistoryAndForgedReferenceFails() async throws {
        try await withDirectory { directory in
            let fixture = try await Self.seedLongConversation(directory: directory, messageCount: 132)
            let library = try await MacLibrary.open(
                embeddings: OfflineMemoryEmbedding(), directory: directory,
                notifications: CompositionNotifications(), credentials: CompositionCredentials(),
                modules: { _ in [] })
            let model = ConversationModel(library: library)
            let observer = Task { @MainActor in await model.observe() }
            do {
                try await eventually { model.isReady }
                try await eventually { model.conversations.contains { $0.id == fixture.sessionID } }
                await model.selectConversation(fixture.sessionID)
                let sourcePage = model.activePage
                sourcePage.composer = "Keep this conversation draft."
                sourcePage.readingState.recordOffset(143)

                let draftPage = sourcePage
                await model.newConversation()
                let currentDraft = model.activePage
                currentDraft.composer = "Keep this separate draft too."
                currentDraft.readingState.recordOffset(37)

                #expect(await model.revealMemorySource(fixture.reference))
                #expect(model.activePage.conversationID == fixture.sessionID)
                #expect(model.activePage.revealedMessageID == fixture.reference.userMessageID)
                #expect(Set(model.activePage.messages.map(\.id)) == Set(fixture.messageIDs))
                #expect(model.activePage.messages.contains { $0.id == fixture.intermediateMessageID })
                #expect(model.activePage.composer == "Keep this conversation draft.")
                #expect(model.activePage.readingState.visibleOffset == 143)
                #expect(currentDraft.composer == "Keep this separate draft too.")
                #expect(currentDraft.readingState.visibleOffset == 37)

                let forged = SessionEvidenceReference(
                    sessionID: fixture.reference.sessionID,
                    originalExecutionID: fixture.reference.originalExecutionID,
                    userMessageID: MessageID(),
                    admissionEventID: fixture.reference.admissionEventID,
                    admissionSequence: fixture.reference.admissionSequence)
                #expect(!(await model.revealMemorySource(forged)))
                #expect(model.activePage.conversationID == fixture.sessionID)
                #expect(model.error?.code == .unauthorized)

                observer.cancel()
                await observer.value
                #expect(await library.close().isSettled)
            } catch {
                observer.cancel()
                await observer.value
                _ = await library.close()
                throw error
            }
        }
    }

    private struct LongConversationFixture {
        let sessionID: ConversationID
        let reference: SessionEvidenceReference
        let messageIDs: [MessageID]
        let intermediateMessageID: MessageID
    }

    private static func seedLongConversation(
        directory: URL, messageCount: Int
    ) async throws -> LongConversationFixture {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessions = try FileSessionLibrary(directory: directory.appendingPathComponent("Sessions"))
        let sessionID = ConversationID()
        let route = AgentModelRoute(
            id: .init(), revision: 1, connectionID: .init(), connectionRevision: 1,
            modelDescriptorID: .init(), modelRevision: 1, modelAuthorizationRevision: 1,
            adapter: .init(id: "tests.memory-source", revision: 1), invocationID: "default",
            invocationRevision: 1, endpointID: "primary", modelID: "synthetic", credential: nil,
            contextWindow: 8_192, maximumOutputTokens: 1_024,
            capabilities: .init(streamsText: true, callsTools: false, producesThinking: false),
            configuration: .object([:]))
        let plan = AgentExecutionPlan(
            runtimeID: UUID(), catalogGeneration: 1, driverID: "mira.default", driverRevision: 1,
            instructions: "Synthetic source navigation fixture.", limits: .init(), priority: .foreground,
            route: route)
        let planBytes = try SessionCodec.encode(plan)
        let firstBatchID = UUID()
        let secondBatchID = UUID()
        let title = try await sessions.stage(
            Data("Synthetic long conversation".utf8), sessionID: sessionID, batchID: firstBatchID, kind: .title)
        let planContent = try await sessions.stage(
            planBytes, sessionID: sessionID, batchID: firstBatchID, kind: .executionPlan)
        var reference: SessionEvidenceReference?
        var sequence: Int64 = 1
        var events: [SessionEvent] = [
            .init(sequence: sequence, occurredAt: Date(), fact: .opened(.init(workspaceID: nil, title: title)))
        ]
        var messageIDs: [MessageID] = []
        for index in 0..<messageCount {
            let executionID = ExecutionID()
            let messageID = MessageID()
            let content = try await sessions.stage(
                Data("Synthetic user message \(messageIDs.count)".utf8),
                sessionID: sessionID, batchID: index < 85 ? firstBatchID : secondBatchID,
                kind: .userText)
            messageIDs.append(messageID)
            let admissionEventID = UUID()
            sequence += 1
            events.append(.init(id: admissionEventID, sequence: sequence, occurredAt: Date(), fact: .admitted(.init(
                executionID: executionID, userMessageID: messageID,
                userBody: content, plan: planContent, hasModelRoute: true,
                authorizationEpoch: 0, timeZoneIdentifier: "UTC"))))
            if index == 0 {
                reference = .init(
                    sessionID: sessionID, originalExecutionID: executionID,
                    userMessageID: messageID, admissionEventID: admissionEventID,
                    admissionSequence: sequence)
            }
            sequence += 1
            events.append(.init(
                sequence: sequence, occurredAt: Date(),
                fact: .phaseChanged(executionID: executionID, phase: .cancelling)))
            sequence += 1
            events.append(.init(
                sequence: sequence, occurredAt: Date(),
                fact: .finished(.init(executionID: executionID, status: .cancelled))))
        }
        let firstEvents = Array(events.prefix(256))
        let secondEvents = Array(events.dropFirst(firstEvents.count))
        let firstBatch = SessionBatch(id: firstBatchID, sessionID: sessionID, expectedSequence: 0, events: firstEvents)
        do {
            try firstBatch.validate()
            _ = try SessionLogCodec.encode(firstBatch)
        } catch {
            throw MiraError(.storage, "Synthetic first batch failed codec validation: \(String(describing: error))")
        }
        let firstOutcome = await sessions.append(firstBatch)
        guard firstOutcome == .committed(firstBatch.cursor) else {
            _ = try? await sessions.close()
            if case .notCommitted(let error) = firstOutcome {
                throw MiraError(.storage, "Synthetic first batch was rejected: \(error.message)")
            }
            if case .indeterminate(let error) = firstOutcome {
                throw MiraError(.storage, "Synthetic first batch was indeterminate: \(error.message)")
            }
            throw MiraError(.storage, "Could not commit the synthetic session navigation fixture.")
        }
        if !secondEvents.isEmpty {
            let secondBatch = SessionBatch(
                id: secondBatchID, sessionID: sessionID,
                expectedSequence: Int64(firstEvents.count), events: secondEvents)
            let secondOutcome = await sessions.append(secondBatch)
            guard secondOutcome == .committed(secondBatch.cursor) else {
                _ = try? await sessions.close()
                if case .notCommitted(let error) = secondOutcome { throw error }
                if case .indeterminate(let error) = secondOutcome { throw error }
                throw MiraError(.storage, "Could not commit the synthetic session navigation fixture.")
            }
        }
        try await sessions.close()
        guard let reference else { throw MiraError(.storage, "The synthetic source reference was not created.") }
        return .init(
            sessionID: sessionID, reference: reference, messageIDs: messageIDs,
            intermediateMessageID: messageIDs[2])
    }
}
#endif
