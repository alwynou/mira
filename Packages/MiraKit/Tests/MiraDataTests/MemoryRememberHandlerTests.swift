import Foundation
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("SQLite memory remember handler")
struct MemoryRememberHandlerTests {
    @Test func businessKeyIsStableForTheSameSourceAndNormalizedAssertion() throws {
        let handler = SQLiteMemoryRememberHandler(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let sessionID = ConversationID(), executionID = ExecutionID(), messageID = MessageID(), batchID = UUID()
        let fixedEvidence = evidence(text: "Remember  This; remember this; Remember that", sessionID: sessionID,
                                     executionID: executionID, messageID: messageID, batchID: batchID)
        let base = try effect(content: "Remember  This", quote: "Remember  This", evidence: fixedEvidence)
        #expect(try handler.businessKey(for: base) == handler.businessKey(for: base))

        let equivalent = try effect(content: " remember this ", quote: "remember this", evidence: fixedEvidence)
        #expect(try handler.businessKey(for: base) == handler.businessKey(for: equivalent))

        let changed = try effect(content: "Remember that", quote: "Remember that", evidence: fixedEvidence)
        #expect(try handler.businessKey(for: base) != handler.businessKey(for: changed))

        let target = AgentSourceReference.domain(namespace: "memories", id: UUID(), revision: 1)
        let enriched = try effect(targets: [target], enriches: [target], quote: "Remember  This", evidence: fixedEvidence)
        let repeated = try effect(targets: [target], enriches: [target], quote: "Remember  This", evidence: fixedEvidence)
        #expect(try handler.businessKey(for: enriched) == handler.businessKey(for: repeated))
        let otherTarget = AgentSourceReference.domain(namespace: "memories", id: UUID(), revision: 1)
        let changedTarget = try effect(targets: [otherTarget], enriches: [otherTarget], quote: "Remember  This", evidence: fixedEvidence)
        #expect(try handler.businessKey(for: enriched) != handler.businessKey(for: changedTarget))
    }

    @Test func malformedDescriptorEffectNamespaceAndTargetsAreRejectedBeforeDatabaseWork() throws {
        let handler = SQLiteMemoryRememberHandler()
        let valid = try effect()
        let cases: [AgentResolvedEffect] = [
            try effect(effectKind: .read),
            try effect(namespace: "memory.other"),
            try effect(descriptorRevision: 1),
            try effect(targets: [.domain(namespace: "memories", id: UUID(), revision: 1)]),
        ]

        for candidate in cases {
            do {
                _ = try handler.businessKey(for: candidate)
                Issue.record("Malformed memory remember proposal was accepted")
            } catch let error as MiraError {
                #expect(error.code == .unauthorized)
            }
        }
        #expect(try handler.businessKey(for: valid).isEmpty == false)
    }

    @Test func invalidArgumentsRemainInputErrorsAndDoNotBecomeAuthorizationSuccess() throws {
        let handler = SQLiteMemoryRememberHandler()
        let candidate = try effect(input: .object([
            "content": .string("body"), "quote": .string("not in source"),
            "kind": .string("fact"), "scope": .string("global"), "sensitive": .bool(false),
            "enriches": .array([])
        ]))
        do {
            _ = try handler.businessKey(for: candidate)
            Issue.record("An invalid quote was accepted")
        } catch let error as MiraError {
            #expect(error.code == .invalidInput)
        }
    }

    private func effect(content: String = "Remember this", effectKind: SessionEffectKind = .localWrite,
                        namespace: String = "memory.remember", descriptorRevision: Int = 2,
                        targets: [AgentSourceReference] = [], input: JSONValue? = nil,
                        enriches: [AgentSourceReference] = [],
                        sessionID: ConversationID? = nil, executionID: ExecutionID? = nil,
                        messageID: MessageID? = nil, batchID: UUID? = nil,
                        quote: String? = nil, evidence: SessionUserEvidence? = nil) throws -> AgentResolvedEffect {
        let contextEvidence = evidence ?? self.evidence(text: content, sessionID: sessionID ?? ConversationID(),
                                                         executionID: executionID ?? ExecutionID(), messageID: messageID ?? MessageID(),
                                                         batchID: batchID ?? UUID())
        let executionID = contextEvidence.reference.originalExecutionID
        let invocationID = UUID()
        let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1, adapter: .init(id: "memory.fixture", revision: 1),
            invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", modelID: "memory", credential: nil, contextWindow: 4_096, maximumOutputTokens: 512,
            capabilities: .init(streamsText: true, callsTools: true, producesThinking: false), configuration: .object([:]))
        var argumentFields: [String: JSONValue] = [
            "content": .string(content), "quote": .string(quote ?? content), "kind": .string("fact"),
            "scope": .string("global"), "sensitive": .bool(false)
        ]
        argumentFields["enriches"] = .array(enriches.map { source in
            guard case .domain(_, let id, let revision) = source else { return .null }
            return .object(["memory_id": .string(id.uuidString.lowercased()), "revision": .number(Double(revision))])
        })
        let arguments = input ?? .object(argumentFields)
        let descriptor = AgentToolDescriptor(definition: MemoryTools.rememberDefinition, revision: descriptorRevision,
            outputSchema: MemoryTools.rememberResultSchema, executionMode: .exclusive,
            timeoutMilliseconds: 120_000, maximumResultBytes: 4_096)
        let proposal = AgentToolProposal(descriptor: descriptor, effect: effectKind, businessNamespace: namespace,
            callDigest: String(repeating: "b", count: 64), inheritedSources: [], plan: .init(input: arguments, sources: enriches, targets: targets))
        return .init(proposal: proposal, context: .init(executionID: executionID, invocationID: invocationID,
            evidence: contextEvidence, route: route))
    }

    private func evidence(text: String, sessionID: ConversationID, executionID: ExecutionID,
                          messageID: MessageID, batchID: UUID) -> SessionUserEvidence {
        return .init(reference: .init(sessionID: sessionID, originalExecutionID: executionID, userMessageID: messageID,
                                      admissionEventID: UUID(), admissionSequence: 1),
                     workspaceID: nil, admittedAt: Date(timeIntervalSince1970: 1_700_000_000), timeZoneIdentifier: "UTC",
                     text: text, observedHead: .init(cursor: .init(sessionID: sessionID, sequence: 1), batchID: batchID),
                     sessionAuthorizationEpoch: 0)
    }
}
