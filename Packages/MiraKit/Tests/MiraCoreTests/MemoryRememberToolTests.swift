import Foundation
import Testing
@testable import MiraCore

@Suite("Memory remember evolution targets")
struct MemoryRememberToolTests {
    @Test func deletionBindsExactTargetAndNeverReportsPrematureCompletion() async throws {
        let memory = makeMemory(content: "I prefer green tea")
        let context = makeContext()
        let tool = MemoryDeleteTool(store: RememberFixtureStore(memories: [memory]))
        try tool.descriptor.validate()
        let args: JSONValue = .object([
            "memory_id": .string(memory.id.rawValue.uuidString.lowercased()),
            "revision": .number(Double(memory.revision)), "quote": .string("remember this")
        ])
        let plan = try await tool.prepare(args, context: context)
        #expect(plan.sources == [.domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision)])
        #expect(plan.targets == plan.sources)
        let request = MemoryDeletionRequest(id: context.invocationID, target: usage(memory),
            source: context.evidence.reference, executionID: context.executionID, workspaceID: nil, requestedAt: Date())
        let result = MemoryTools.deletionResult(request)
        #expect(result["state"] == .string("pending"))
        #expect(result["acknowledgment"]?.stringValue?.contains("Deletion is not complete") == true)
        #expect(result["content"] == nil)
        let replacement = MemoryTools.result(.init(memory: memory, disposition: .created), replacedPrevious: true)
        #expect(replacement["acknowledgment"]?.stringValue?.contains("superseded history") == true)
    }

    @Test func deletionRejectsStaleTargetAndUnrelatedQuote() async throws {
        let memory = makeMemory(content: "I prefer green tea")
        let tool = MemoryDeleteTool(store: RememberFixtureStore(memories: [memory]))
        for (revision, quote) in [(memory.revision + 1, "remember this"), (memory.revision, "unrelated evidence")] {
            await #expect(throws: MiraError.self) {
                _ = try await tool.prepare(.object([
                    "memory_id": .string(memory.id.rawValue.uuidString.lowercased()),
                    "revision": .number(Double(revision)), "quote": .string(quote)
                ]), context: makeContext())
            }
        }
    }

    @Test func retractionDescriptorBindsOneExactTarget() async throws {
        let memory = makeMemory(content: "I prefer green tea")
        let context = makeContext()
        let tool = MemoryRetractTool(store: RememberFixtureStore(memories: [memory]))
        try tool.descriptor.validate()
        #expect(tool.descriptor.revision == 1)
        let args: JSONValue = .object([
            "memory_id": .string(memory.id.rawValue.uuidString.lowercased()),
            "revision": .number(Double(memory.revision)),
            "quote": .string("remember this")
        ])
        let plan = try await tool.prepare(args, context: context)
        let reference = AgentSourceReference.domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision)
        #expect(plan.sources == [reference])
        #expect(plan.targets == [reference])
    }

    @Test func retractionRejectsQuoteOutsideCurrentEvidence() async throws {
        let memory = makeMemory(content: "I prefer green tea")
        let context = makeContext()
        let args: JSONValue = .object([
            "memory_id": .string(memory.id.rawValue.uuidString.lowercased()),
            "revision": .number(Double(memory.revision)),
            "quote": .string("unrelated claim")
        ])
        do {
            _ = try await MemoryRetractTool(store: RememberFixtureStore(memories: [memory]))
                .prepare(args, context: context)
            Issue.record("A quote outside the current user evidence was accepted")
        } catch let error as MiraError {
            #expect(error.code == .invalidInput)
        }
    }

    @Test func schemaRequiresBoundedTargetsAndDescriptorRevisionFour() throws {
        let tool = MemoryRememberTool(store: RememberFixtureStore())
        try tool.descriptor.validate()
        #expect(tool.descriptor.revision == 4)
        guard case .object(let schema) = MemoryTools.rememberDefinition.inputSchema,
              case .array(let required)? = schema["required"] else {
            Issue.record("Remember schema is malformed")
            return
        }
        #expect(required.contains(.string("enriches")))
        #expect(!required.contains(.string("replaces")))
        #expect(MemoryTools.rememberDefinition.description.contains("memory.get"))
        #expect(MemoryTools.rememberDefinition.description.contains("memory.search"))
        #expect(MemoryTools.rememberDefinition.description.contains("Do not guess or merge by similarity"))
    }

    @Test func prepareBindsExactReplacementTargetAndRejectsMixedEvolutionModes() async throws {
        let memory = makeMemory(content: "I prefer green tea")
        let context = makeContext()
        let target = usage(memory)
        let plan = try await MemoryRememberTool(store: RememberFixtureStore(memories: [memory]))
            .prepare(arguments(for: [], replaces: target), context: context)
        let reference = AgentSourceReference.domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision)
        #expect(plan.sources == [reference])
        #expect(plan.targets == [reference])
        let parsed = try MemoryTools.parsedProposal(arguments: plan.input, evidence: context.evidence)
        #expect(parsed.replacementTarget == target)
        #expect(parsed.enrichmentTargets.isEmpty)

        do {
            _ = try MemoryTools.parsedProposal(arguments: arguments(for: [target], replaces: target), evidence: context.evidence)
            Issue.record("Replacement and enrichment were accepted together")
        } catch let error as MiraError {
            #expect(error.code == .invalidInput)
        }
    }

    @Test func prepareBindsEveryEnrichmentTargetAsBothSourceAndTarget() async throws {
        let memory = makeMemory(content: "I prefer green tea")
        let store = RememberFixtureStore(memories: [memory])
        let tool = MemoryRememberTool(store: store)
        let context = makeContext()
        let plan = try await tool.prepare(arguments(for: [usage(memory)]), context: context)
        let reference = AgentSourceReference.domain(namespace: "memories", id: memory.id.rawValue, revision: memory.revision)
        #expect(plan.sources == [reference])
        #expect(plan.targets == [reference])
        let parsed = try MemoryTools.parsedProposal(arguments: plan.input, evidence: context.evidence)
        #expect(parsed.enrichmentTargets == [usage(memory)])
    }

    @Test func independentSaveProducesNoMemoryDependencies() async throws {
        let plan = try await MemoryRememberTool(store: RememberFixtureStore())
            .prepare(arguments(for: []), context: makeContext())
        #expect(plan.sources.isEmpty)
        #expect(plan.targets.isEmpty)
    }

    @Test func prepareRejectsStaleOrIncompatibleTargets() async throws {
        let memory = makeMemory(content: "I prefer green tea")
        do {
            _ = try await MemoryRememberTool(store: RememberFixtureStore(memories: [memory]))
                .prepare(arguments(for: [MemoryUsage(memoryID: memory.id, revision: 2)]), context: makeContext())
            Issue.record("Stale memory revision was accepted")
        } catch let error as MiraError {
            #expect(error.message == "The memory evolution target is invalid.")
        }

        let other = makeMemory(content: "I prefer tea in the morning", kind: .fact)
        do {
            _ = try await MemoryRememberTool(store: RememberFixtureStore(memories: [memory, other]))
                .prepare(arguments(for: [usage(memory), usage(other)]), context: makeContext())
            Issue.record("Incompatible targets were accepted")
        } catch let error as MiraError {
            #expect(error.code == .invalidInput)
        }

        do {
            _ = try await MemoryRememberTool(store: RememberFixtureStore(memories: [memory]))
                .prepare(arguments(for: [], replaces: MemoryUsage(memoryID: memory.id, revision: memory.revision + 1)),
                         context: makeContext())
            Issue.record("A stale correction target was accepted")
        } catch let error as MiraError {
            #expect(error.code == .invalidInput)
        }
    }

    @Test func recallContributorIdentifiersFeedEnrichmentPreparation() async throws {
        let memory = makeMemory(content: "I prefer green tea")
        let store = RememberFixtureStore(memories: [memory])
        let context = makeContext()
        let registry = RuntimeRegistry<AgentCapability>()
        let authorities = RuntimeRegistry<any AgentDomainSourceAuthority>()
        let scope = RuntimeScope(kind: .application)
        let module = MemoryModule(registry: registry, store: store, sourceAuthorities: authorities,
                                  now: { Date(timeIntervalSince1970: 500) })
        try await module.activate(in: scope)
        let snapshot = try await registry.freeze()
        do {
            let entry = try #require(snapshot.entries.first { $0.id == "memory.recall" })
            guard case .context(let contributor) = entry.value,
                  let toolEntry = snapshot.entries.first(where: { $0.id == "memory.remember" }),
                  case .tool(let tool) = toolEntry.value,
                  case .localWrite(let remember) = tool else {
                Issue.record("Memory recall or remember capability was missing")
                await snapshot.release()
                await scope.dispose()
                return
            }
            let contextItems = try await contributor.contribute(to: MemoryTools.request(context))
            let contextItem = try #require(contextItems.first)
            let payload = try #require(try? JSONDecoder().decode(JSONValue.self, from: Data(contextItem.text.utf8)))
            guard case .object(let payloadFields)? = payload["memories"].flatMap({ value in
                if case .array(let values) = value, let first = values.first { return first }
                return nil
            }),
            case .string(let memoryID)? = payloadFields["memory_id"],
            case .number(let revision)? = payloadFields["revision"] else {
                Issue.record("Recall output omitted the memory identifier or revision")
                await snapshot.release()
                await scope.dispose()
                return
            }
            let enriches: [JSONValue] = [.object(["memory_id": .string(memoryID), "revision": .number(revision)])]
            let arguments = argumentsObject(enriches: enriches)
            let plan = try await remember.prepare(arguments, context: context)
            #expect(plan.sources == contextItem.sources)
            #expect(plan.targets == contextItem.sources)
            await snapshot.release()
            await scope.dispose()
        } catch {
            await snapshot.release()
            await scope.dispose()
            throw error
        }
    }

    @Test func parserRejectsMissingDuplicateMalformedAndNonpositiveTargets() throws {
        let evidence = makeContext().evidence
        let memory = makeMemory(content: "I prefer green tea")
        let target = targetJSON(usage(memory))
        let invalid: [JSONValue] = [
            argumentsObject(enriches: nil),
            argumentsObject(enriches: [target, target]),
            argumentsObject(enriches: [.object(["memory_id": .string("not-a-uuid"), "revision": .number(1)])]),
            argumentsObject(enriches: [.object(["memory_id": .string(memory.id.rawValue.uuidString), "revision": .number(0)])]),
            argumentsObject(enriches: [.object(["memory_id": .string(memory.id.rawValue.uuidString), "revision": .number(1), "extra": .bool(true)])]),
            argumentsObject(enriches: [], replaces: .null),
            argumentsObject(enriches: [], replaces: .object(["memory_id": .string("not-a-uuid"), "revision": .number(1)]))
        ]
        for value in invalid {
            do {
                _ = try MemoryTools.parsedProposal(arguments: value, evidence: evidence)
                Issue.record("Invalid enrichment target input was accepted")
            } catch let error as MiraError {
                #expect(error.code == .invalidInput)
            }
        }
    }

    @Test func prepareRejectsTargetDeniedByCurrentRecallPolicy() async throws {
        let memory = makeMemory(content: "I prefer green tea")
        do {
            _ = try await MemoryRememberTool(store: RememberFixtureStore(deniedIDs: [memory.id]))
                .prepare(arguments(for: [usage(memory)]), context: makeContext())
            Issue.record("A target denied by recall policy was accepted")
        } catch let error as MiraError {
            #expect(error.code == .unauthorized)
        }
        do {
            _ = try await MemoryRememberTool(store: RememberFixtureStore(memories: [memory], deniedIDs: [memory.id]))
                .prepare(arguments(for: [], replaces: usage(memory)), context: makeContext())
            Issue.record("A correction target denied by current recall policy was accepted")
        } catch let error as MiraError {
            #expect(error.code == .unauthorized)
        }
    }

    @Test func policyRevalidatesTargetRevisionAndSuppressedSource() async throws {
        let memory = makeMemory(content: "I prefer green tea")
        let context = makeContext()
        let store = RememberFixtureStore(memories: [memory])
        let tool = MemoryRememberTool(store: store, now: { Date(timeIntervalSince1970: 500) })
        let plan = try await tool.prepare(arguments(for: [usage(memory)]), context: context)
        let effect = proposal(tool: tool, plan: plan)
        guard case .constrained(let policy) = tool.policy else {
            Issue.record("Remember must keep its constrained policy")
            return
        }

        await store.set(memory.revisioned(to: 2))
        do {
            _ = try await policy.evaluate(effect, context: context)
            Issue.record("Policy accepted a stale target revision")
        } catch let error as MiraError {
            #expect(error.message == "The memory evolution target is invalid.")
        }

        await store.set(memory)
        await store.setSuppressed([.userMessage(context.evidence.reference)])
        let decision = try await policy.evaluate(effect, context: context)
        if case .deny = decision { } else { Issue.record("Policy accepted a suppressed source") }
    }

    private func arguments(for usages: [MemoryUsage], replaces: MemoryUsage? = nil) -> JSONValue {
        argumentsObject(enriches: usages.map(targetJSON), replaces: replaces.map(targetJSON))
    }

    private func argumentsObject(enriches: [JSONValue]?, replaces: JSONValue? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "content": .string("I prefer green tea and loose leaf"),
            "quote": .string("remember this"), "kind": .string("preference"),
            "scope": .string("global"), "sensitive": .bool(false)
        ]
        if let enriches { object["enriches"] = .array(enriches) }
        if let replaces { object["replaces"] = replaces }
        return .object(object)
    }

    private func targetJSON(_ usage: MemoryUsage) -> JSONValue {
        .object(["memory_id": .string(usage.memoryID.rawValue.uuidString), "revision": .number(Double(usage.revision))])
    }

    private func usage(_ memory: Memory) -> MemoryUsage { .init(memoryID: memory.id, revision: memory.revision) }

    private func makeMemory(content: String, kind: MemoryKind = .preference) -> Memory {
        let draft = MemoryDraft(content: content, scope: .global, kind: kind)
        return Memory(draft: draft, scope: .global, subject: .user,
                      createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100))
    }

    private func proposal(tool: MemoryRememberTool, plan: AgentToolPlan) -> AgentToolProposal {
        AgentToolProposal(descriptor: tool.descriptor, effect: .localWrite, businessNamespace: "memory.remember",
            callDigest: String(repeating: "a", count: 64), inheritedSources: [], plan: plan)
    }

    private func makeContext() -> AgentToolContext {
        let sessionID = ConversationID(), executionID = ExecutionID()
        let reference = SessionEvidenceReference(sessionID: sessionID, originalExecutionID: executionID,
            userMessageID: MessageID(), admissionEventID: UUID(), admissionSequence: 2)
        let evidence = SessionUserEvidence(reference: reference, workspaceID: nil,
            admittedAt: Date(timeIntervalSince1970: 100), timeZoneIdentifier: "UTC", text: "remember this",
            observedHead: .init(cursor: .init(sessionID: sessionID, sequence: 2), batchID: UUID()),
            sessionAuthorizationEpoch: 0)
        let route = AgentModelRoute(id: RouteID(), revision: 1, connectionID: ConnectionID(), connectionRevision: 1,
            modelDescriptorID: ModelDescriptorID(), modelRevision: 1, modelAuthorizationRevision: 1,
            adapter: .init(id: "remember.adapter", revision: 1), invocationID: "remember-test", invocationRevision: 1,
            endpointID: "remember-endpoint", modelID: "remember-model", credential: nil,
            contextWindow: 4_096, maximumOutputTokens: 512,
            capabilities: .init(streamsText: true, callsTools: true, producesThinking: false), configuration: .object([:]))
        return AgentToolContext(executionID: executionID, invocationID: UUID(), evidence: evidence, route: route)
    }
}

private actor RememberFixtureStore: MemoryReadStore {
    private var memories: [MemoryID: Memory]
    private var deniedIDs: Set<MemoryID>
    private var suppressed: [MemoryEvidenceSource] = []

    init(memories values: [Memory] = [], deniedIDs: Set<MemoryID> = []) {
        memories = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        self.deniedIDs = deniedIDs
    }

    func set(_ memory: Memory) { memories[memory.id] = memory }
    func setSuppressed(_ sources: [MemoryEvidenceSource]) { suppressed = sources }

    func memoryList(workspaceID: WorkspaceID?, states: Set<MemoryState>, query: String, limit: Int) async throws -> MemorySearchResult { .init(memories: []) }
    func memoryDetail(_ id: MemoryID, workspaceID: WorkspaceID?) async throws -> MemoryDetail { throw MiraError(.notFound, "No fixture detail.") }
    func memoryManagementPage(_ query: MemoryManagementQuery, at: Date) async throws -> MemoryManagementPage { .init(memories: [], nextCursor: nil) }
    func memoryCitationRevision(_ reference: MemoryCitationReference, workspaceID: WorkspaceID?) async throws -> MemoryCitationDetail { throw MiraError(.notFound, "No fixture citation.") }
    func memoryContextNotices(references: [MemoryCitationReference], workspaceID: WorkspaceID?, connectionID: ConnectionID?, at: Date) async throws -> [MemoryContextNotice] { [] }
    func recallMemories(query: String, request: AgentContextRequest, limit: Int, at: Date) async throws -> MemorySearchResult {
        let connectionID = request.destination.modelRoute?.connectionID
        let values = memories.values.filter { memory in
            memory.state == .active && memory.canRecall(in: request.workspaceID,
                connectionID: connectionID ?? ConnectionID(), at: at)
        }.prefix(limit)
        return .init(memories: Array(values))
    }
    func recallMemory(_ id: MemoryID, request: AgentContextRequest, at: Date) async throws -> Memory {
        guard !deniedIDs.contains(id), let memory = memories[id], memory.isCurrent,
              memory.canRecall(in: request.workspaceID, connectionID: request.destination.modelRoute!.connectionID, at: at)
        else { throw MiraError(.unauthorized, "Fixture memory is unavailable.") }
        return memory
    }
    func validateMemorySources(_ sources: [AgentSourceReference], for request: AgentContextRequest, at: Date) async throws {}
    func validateMemoryContextSources(_ sources: [AgentSourceReference], for request: AgentContextRequest, at: Date) async throws {}
    func suppressedMemorySources() async throws -> [MemoryEvidenceSource] { suppressed }
}

private extension Memory {
    func revisioned(to revision: Int) -> Self {
        .init(id: id, draft: draft, scope: scope, subject: subject, state: state,
              origin: origin, authority: authority, supersededBy: supersededBy,
              revision: revision, createdAt: createdAt, updatedAt: updatedAt,
              deletedAt: deletedAt, forgottenAt: forgottenAt)
    }
}
