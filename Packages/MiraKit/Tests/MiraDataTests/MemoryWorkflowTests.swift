import Foundation
import GRDB
import Testing

@testable import MiraCore
@testable import MiraData

@Suite("Memory through the journal and current agent modules", .timeLimit(.minutes(1)))
struct MemoryWorkflowTests {
    @Test func explicitRememberCommitsFullEvidenceAndRecallableReceipt() async throws {
        let content = "I prefer green tea"
        let text = "Remember: I prefer green tea"
        let call = try CanonicalToolCall(
            id: "remember", name: "memory.remember", arguments: arguments(content: content).jsonString())
        try await withTaskWorkflow(
            outputs: [modelToolStream([call]), [.blockStarted(.init(id: "text", content: .text("Saved."))), .blockFinished(id: "text"), .finished(.stop)]],
            memoryEnabled: true
        ) { f in
            let address = try await f.run(text)
            let store = try #require(f.memory)
            let memory = try #require(
                try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10).memories.first)
            #expect(memory.draft?.allowsRemoteUse == true)
            let detail = try await store.memoryDetail(memory.id, workspaceID: nil)
            #expect(detail.evidence.first?.source == .userMessage(try await f.evidence(address).reference))
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(state.invocations.values.first)
            #expect(invocation.resolution?.status == .succeeded)
            #expect(invocation.resolution?.businessReceipt != nil)
            #expect(
                try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM business_operations") } == 1
            )
            let request = try await context(f, address)
            #expect(
                try await store.recallMemories(
                    query: "green tea", request: request, limit: 6, at: TaskWorkflowFixture.now
                ).memories.map(\.id) == [memory.id])
        }
    }

    @Test func explicitCorrectionReplacesOneExactCurrentMemoryWithoutCopyingOldEvidence() async throws {
        let original = "I prefer green tea"
        let corrected = "I prefer black tea"
        let correctionText = "Correction: I prefer black tea now."
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            let old = try await store.createMemory(draft: .init(content: original, scope: .global),
                source: .manualEntry(id: UUID(), statement: original), operationID: UUID(), replacing: nil,
                expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now).memory
            let target = AgentSourceReference.domain(namespace: "memories", id: old.id.rawValue, revision: old.revision)
            let correctedCall = try CanonicalToolCall(id: "correct-memory", name: "memory.remember",
                arguments: rememberArguments(content: corrected, quote: correctionText, replaces: target).jsonString())
            await f.model.append([modelToolStream([correctedCall]), reply("Corrected and saved." )])
            let address = try await f.run(correctionText)
            let page = try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10)
            let current = try #require(page.memories.first(where: { $0.isCurrent }))
            #expect(page.memories.filter(\.isCurrent).count == 1)
            #expect(current.id != old.id)
            #expect(current.draft?.content == corrected)
            let detail = try await store.memoryDetail(current.id, workspaceID: nil)
            #expect(detail.evidence.count == 1)
            #expect(detail.evidence.first?.source == .userMessage(try await f.evidence(address).reference))
            #expect(detail.replacements.map(\.previousID) == [old.id])
            let oldDetail = try await store.memoryDetail(old.id, workspaceID: nil)
            #expect(oldDetail.memory.supersededBy == current.id)
            #expect(oldDetail.memory.isCurrent == false)
            #expect(oldDetail.memory.draft?.content == original)

            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(state.invocations.values.first(where: { $0.invocation.toolName == "memory.remember" }))
            #expect(invocation.resolution?.status == .succeeded)
            let proofData = try #require(try await f.database.read {
                try Data.fetchOne($0, sql: "SELECT proof_json FROM business_receipts WHERE invocation_id = ?",
                    arguments: [invocation.invocation.id.uuidString])
            })
            let proof = try SessionCodec.decode(AgentEffectProof.self, from: proofData)
            let receipt: AgentBusinessReceipt
            switch await f.business.receipt(for: proof) {
            case .committed(let value): receipt = value
            case .absent, .unavailable:
                Issue.record("Correction business receipt was unavailable for replay")
                return
            }
            let counts = try await f.database.read { db in
                try ["memory_records", "memory_evidence", "memory_replacements", "business_receipts"].map {
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)")
                }
            }
            #expect(await f.business.commit(proof) == .committed(receipt))
            #expect(await f.business.commit(proof) == .committed(receipt))
            #expect(try await f.database.read { db in
                try ["memory_records", "memory_evidence", "memory_replacements", "business_receipts"].map {
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)")
                }
            } == counts)
        }
    }

    @Test func correctionRelationFailureRollsBackNewMemoryAndLeavesExactTargetCurrent() async throws {
        let original = "I prefer green tea"
        let correctionText = "Correction: I prefer black tea now."
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            let old = try await store.createMemory(draft: .init(content: original, scope: .global),
                source: .manualEntry(id: UUID(), statement: original), operationID: UUID(), replacing: nil,
                expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now).memory
            try await f.database.write {
                try $0.execute(sql: "CREATE TRIGGER reject_correction_relation BEFORE INSERT ON memory_replacements BEGIN SELECT RAISE(ABORT, 'Synthetic relation failure'); END")
            }
            let target = AgentSourceReference.domain(namespace: "memories", id: old.id.rawValue, revision: old.revision)
            let call = try CanonicalToolCall(id: "failed-correction", name: "memory.remember",
                arguments: rememberArguments(content: "I prefer black tea", quote: correctionText, replaces: target).jsonString())
            await f.model.append([modelToolStream([call]), reply("I couldn't update the memory." )])
            let address = try await f.run(correctionText)
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(state.invocations.values.first(where: { $0.invocation.toolName == "memory.remember" }))
            #expect(invocation.resolution?.status != .succeeded)
            #expect(invocation.resolution?.businessReceipt == nil)
            #expect(try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10).memories.map(\.id) == [old.id])
            #expect(try await store.memoryDetail(old.id, workspaceID: nil).memory.isCurrent)
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_records") } == 1)
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_replacements") } == 0)
        }
    }

    @Test func correctionCommitRechecksExactRevisionAndCurrentSourceSuppression() async throws {
        try await withTaskWorkflow(outputs: [reply("Holding the correction for a policy check.")], memoryEnabled: true) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            let original = "I prefer green tea"
            let old = try await store.createMemory(draft: .init(content: original, scope: .global),
                source: .manualEntry(id: UUID(), statement: original), operationID: UUID(), replacing: nil,
                expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now).memory
            let address = try await f.run("Correction: I prefer black tea now.")
            let evidence = try await f.evidence(address)
            let context = AgentToolContext(executionID: address.executionID, invocationID: UUID(), evidence: evidence, route: f.route)
            let remember = MemoryRememberTool(store: store, now: { TaskWorkflowFixture.now })
            func effect(plan: AgentToolPlan) -> AgentResolvedEffect {
                let proposal = AgentToolProposal(descriptor: remember.descriptor, effect: .localWrite,
                    businessNamespace: remember.businessNamespace, callDigest: String(repeating: "c", count: 64),
                    inheritedSources: [], plan: plan)
                return AgentResolvedEffect(proposal: proposal, context: context)
            }
            let target = AgentSourceReference.domain(namespace: "memories", id: old.id.rawValue, revision: old.revision)
            let stalePlan = try await remember.prepare(
                rememberArguments(content: "I prefer black tea", quote: evidence.text, replaces: target), context: context)
            let staleEffect = effect(plan: stalePlan)
            _ = try await store.reviseMemory(old.id, workspaceID: nil,
                draft: .init(content: "I prefer matcha", scope: .global), expectedRevision: old.revision,
                operationID: UUID(), authorization: authorization, at: TaskWorkflowFixture.now)
            let handler = SQLiteMemoryRememberHandler(now: { TaskWorkflowFixture.now })
            await #expect(throws: MiraError.self) {
                try await f.database.read { db in try handler.validate(effect: staleEffect, isReplay: false, in: db) }
            }

            let current = try await store.memoryDetail(old.id, workspaceID: nil).memory
            let currentTarget = AgentSourceReference.domain(namespace: "memories", id: current.id.rawValue, revision: current.revision)
            let currentPlan = try await remember.prepare(
                rememberArguments(content: "I prefer black tea", quote: evidence.text, replaces: currentTarget), context: context)
            let currentEffect = effect(plan: currentPlan)
            try await f.database.write { db in
                let draft = MemoryDraft(content: "I prefer black tea", scope: .global)
                let resolved = try SQLiteMemoryStore.resolve(
                    .userMessage(evidence: evidence, excerpt: "Correction: I prefer black tea now."), draft: draft, in: db)
                try SQLiteMemoryStore.bindSource(resolved, in: db)
                try SQLiteMemoryStore.suppress(.userMessage(evidence.reference), strength: 3, in: db)
            }
            await #expect(throws: MiraError.self) {
                try await f.database.read { db in try handler.validate(effect: currentEffect, isReplay: false, in: db) }
            }
            #expect(try await store.memoryDetail(old.id, workspaceID: nil).memory.isCurrent)
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_replacements") } == 0)
        }
    }

    @Test func runtimeRememberEnrichesMultipleCurrentTargetsAndPreservesEvidenceHistoryAndRecall() async throws {
        let firstText = "I have a shorthair cat named Miso."
        let firstContent = "My cat is named Miso"
        let firstCall = try CanonicalToolCall(id: "remember-first", name: "memory.remember",
            arguments: rememberArguments(content: firstContent, quote: firstText).jsonString())
        try await withTaskWorkflow(outputs: [modelToolStream([firstCall]), reply("Saved.")], memoryEnabled: true) { f in
            let firstAddress = try await f.run(firstText)
            let store = try #require(f.memory)
            let firstEvidence = try await f.evidence(firstAddress)
            let firstMemory = try #require(try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10)
                .memories.first(where: { $0.draft?.content == firstContent }))
            let authorization = try await f.authority.authorization()
            await f.model.append([reply("Understood." )])
            let secondAddress = try await f.run("Miso is a shorthair cat.", sessionID: firstAddress.sessionID)
            let secondEvidence = try await f.evidence(secondAddress)
            let secondMemory = try await store.createMemory(
                draft: .init(content: "Miso is a shorthair cat", scope: .global),
                source: .userMessage(evidence: secondEvidence, excerpt: "Miso is a shorthair cat."), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now).memory

            let search = try CanonicalToolCall(id: "search-targets", name: "memory.search",
                arguments: JSONValue.object(["query": .string("Miso cat")]).jsonString())
            await f.model.append([modelToolStream([search]), reply("You have a cat named Miso, a shorthair.")])
            _ = try await f.run("What do you know about Miso?", sessionID: firstAddress.sessionID)

            let enrichmentText = "Miso is a black shorthair cat."
            let consolidated = "My cat Miso is a black shorthair."
            let targets = [firstMemory, secondMemory].map {
                AgentSourceReference.domain(namespace: "memories", id: $0.id.rawValue, revision: $0.revision)
            }
            let enrichCall = try CanonicalToolCall(id: "remember-enriched", name: "memory.remember",
                arguments: rememberArguments(content: consolidated, quote: enrichmentText, enriches: targets).jsonString())
            await f.model.append([modelToolStream([enrichCall]), reply("Updated memory.")])
            let enrichedAddress = try await f.run(enrichmentText, sessionID: firstAddress.sessionID)
            let state = try await f.runtime.sessionSnapshot(id: enrichedAddress.sessionID)
            let execution = try #require(state.executions[enrichedAddress.executionID])
            let invocation = try #require(execution.attemptIDs.compactMap { state.attempts[$0] }
                .flatMap(\.invocationIDs).compactMap { state.invocations[$0] }
                .last(where: { $0.invocation.toolName == "memory.remember" }))
            #expect(invocation.resolution?.status == .succeeded)
            #expect(invocation.resolution?.businessReceipt != nil)
            #expect(state.executions[enrichedAddress.executionID]?.completion?.status == .completed)
            let resultReference = try #require(invocation.resolution?.result)
            let result = try SessionCodec.decode(JSONValue.self, from: await f.library.read(resultReference))
            let enrichedID = try #require(result["memory_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let enrichedDetail = try await store.memoryDetail(.init(enrichedID), workspaceID: nil)
            #expect(enrichedDetail.memory.draft?.content == consolidated)
            #expect(enrichedDetail.evidence.contains(where: { $0.source == .userMessage(firstEvidence.reference) }))
            #expect(enrichedDetail.evidence.contains(where: { $0.source == .userMessage(secondEvidence.reference) }))
            let latestEvidence = try await f.evidence(enrichedAddress)
            #expect(enrichedDetail.evidence.contains(where: {
                if case .userMessage(let ref) = $0.source { return ref == latestEvidence.reference }
                return false
            }))
            #expect(Set(enrichedDetail.replacements.map(\.previousID)) == Set([firstMemory.id, secondMemory.id]))
            let currentPage = try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10)
            #expect(currentPage.memories.filter(\.isCurrent).map(\.id) == [.init(enrichedID)])
            for target in [firstMemory, secondMemory] {
                let old = try await store.memoryDetail(target.id, workspaceID: nil)
                #expect(old.memory.supersededBy?.rawValue == enrichedID)
                #expect(old.revisions.count >= 2)
            }
            let request = try await context(f, enrichedAddress)
            #expect(try await store.recallMemories(query: "black shorthair Miso", request: request, limit: 6,
                at: TaskWorkflowFixture.now).memories.map(\.id) == [.init(enrichedID)])
            let proposalReference = try #require(invocation.intent?.intent.proposal)
            let proposal = try SessionCodec.decode(AgentToolProposal.self, from: await f.library.read(proposalReference))
            #expect(proposal.plan.targets == targets)
            #expect(proposal.plan.sources == targets)
            #expect(targets.allSatisfy(proposal.sources.contains))

            let proofData = try #require(try await f.database.read {
                try Data.fetchOne($0, sql: "SELECT proof_json FROM business_receipts WHERE invocation_id = ?",
                    arguments: [invocation.invocation.id.uuidString])
            })
            let proof = try SessionCodec.decode(AgentEffectProof.self, from: proofData)
            let receipt: AgentBusinessReceipt
            switch await f.business.receipt(for: proof) {
            case .committed(let value): receipt = value
            case .absent, .unavailable(_):
                Issue.record("The remember receipt was unavailable for replay")
                return
            }
            #expect(receipt.reference == invocation.resolution?.businessReceipt)
            let countsBeforeReplay = try await f.database.read { db in
                try ["memory_records", "memory_evidence", "memory_replacements", "business_receipts"].map {
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)")
                }
            }
            #expect(await f.business.commit(proof) == .committed(receipt))
            #expect(await f.business.commit(proof) == .committed(receipt))
            let countsAfterReplay = try await f.database.read { db in
                try ["memory_records", "memory_evidence", "memory_replacements", "business_receipts"].map {
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)")
                }
            }
            #expect(countsAfterReplay == countsBeforeReplay)

            // Replay authorization cannot carry forward a source that privacy maintenance has suppressed.
            try await f.database.write { db in
                try SQLiteMemoryStore.suppress(.userMessage(firstEvidence.reference), strength: 3, in: db)
            }
            let effect = try await JournalAgentEffectResolver(journal: f.library, payloads: f.library)
                .resolve(proof, requireEligible: false)
            let handler = SQLiteMemoryRememberHandler(now: { TaskWorkflowFixture.now })
            await #expect(throws: MiraError.self) {
                try await f.database.read { db in
                    try handler.validate(effect: effect, isReplay: true, in: db)
                }
            }
            let countsAfterSuppression = try await f.database.read { db in
                try ["memory_records", "memory_evidence", "memory_replacements", "business_receipts"].map {
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)")
                }
            }
            #expect(countsAfterSuppression == countsBeforeReplay)
        }
    }

    @Test func receiptInsertionFailureRollsBackMemoryAndEvidence() async throws {
        let call = try CanonicalToolCall(
            id: "remember", name: "memory.remember", arguments: arguments(content: "I prefer tea").jsonString())
        try await withTaskWorkflow(
            outputs: [
                modelToolStream([call]), [.blockStarted(.init(id: "text", content: .text("No memory was saved."))), .blockFinished(id: "text"), .finished(.stop)],
            ], memoryEnabled: true
        ) { f in
            try await f.database.write {
                try $0.execute(
                    sql:
                        "CREATE TRIGGER reject_memory_receipt BEFORE INSERT ON business_receipts BEGIN SELECT RAISE(ABORT, 'Synthetic failure'); END"
                )
            }
            _ = try await f.run("Remember: I prefer tea")
            let store = try #require(f.memory)
            #expect(
                try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10).memories.isEmpty)
            #expect(
                try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_evidence") } == 0)
            #expect(
                try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_operations") } == 0)
        }
    }

    @Test func enrichmentRelationFailureRollsBackNewMemoryAndKeepsTargetsCurrent() async throws {
        let firstText = "I have a shorthair cat named Miso."
        let firstCall = try CanonicalToolCall(id: "remember-first", name: "memory.remember",
            arguments: rememberArguments(content: "My cat is named Miso", quote: firstText).jsonString())
        try await withTaskWorkflow(outputs: [modelToolStream([firstCall]), reply("Saved.")], memoryEnabled: true) { f in
            let address = try await f.run(firstText)
            let store = try #require(f.memory)
            let sourceEvidence = try await f.evidence(address)
            let first = try #require(try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10)
                .memories.first(where: { $0.draft?.content == "My cat is named Miso" }))
            let authorization = try await f.authority.authorization()
            let second = try await store.createMemory(
                draft: .init(content: "Miso is a shorthair cat", scope: .global),
                source: .userMessage(evidence: sourceEvidence, excerpt: firstText), operationID: UUID(),
                replacing: nil, expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now).memory
            let beforeEvidence = try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_evidence") }
            try await f.database.write {
                try $0.execute(sql: "CREATE TRIGGER reject_enrichment_relation BEFORE INSERT ON memory_replacements BEGIN SELECT RAISE(ABORT, 'Synthetic relation failure'); END")
            }
            let newText = "Miso is a black shorthair cat."
            let refs = [first, second].map {
                AgentSourceReference.domain(namespace: "memories", id: $0.id.rawValue, revision: $0.revision)
            }
            let call = try CanonicalToolCall(id: "remember-enriched", name: "memory.remember",
                arguments: rememberArguments(content: "My cat Miso is a black shorthair", quote: newText, enriches: refs).jsonString())
            await f.model.append([modelToolStream([call]), reply("I couldn't update that memory.")])
            let resultAddress = try await f.run(newText, sessionID: address.sessionID)
            let state = try await f.runtime.sessionSnapshot(id: resultAddress.sessionID)
            #expect(state.executions[resultAddress.executionID]?.completion?.status == .completed)
            let execution = try #require(state.executions[resultAddress.executionID])
            let invocation = try #require(execution.attemptIDs.compactMap { state.attempts[$0] }
                .flatMap(\.invocationIDs).compactMap { state.invocations[$0] }
                .last(where: { $0.invocation.toolName == "memory.remember" }))
            #expect(invocation.resolution?.status != .succeeded)
            #expect(invocation.resolution?.businessReceipt == nil)
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_records") } == 2)
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_evidence") } == beforeEvidence)
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_replacements") } == 0)
            for target in [first, second] {
                #expect(try await store.memoryDetail(target.id, workspaceID: nil).memory.isCurrent)
            }
        }
    }

    @Test func staleForeignAndPrivateTargetsCannotBeEnriched() async throws {
        try await withTaskWorkflow(memoryEnabled: true) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            let stale = try await store.createMemory(draft: .init(content: "Stale cat fact", scope: .global),
                source: .manualEntry(id: UUID(), statement: "Stale cat fact"), operationID: UUID(), replacing: nil,
                expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now).memory
            var foreignWorkspace = Workspace(id: .init(), name: "Foreign scope")
            try await f.workspaces.saveWorkspace(foreignWorkspace, expectedRevision: nil, authorization: authorization)
            let foreign = try await store.createMemory(draft: .init(content: "Foreign cat fact", scope: .workspace(foreignWorkspace.id)),
                source: .manualEntry(id: UUID(), statement: "Foreign cat fact"), operationID: UUID(), replacing: nil,
                expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now).memory
            let privateMemory = try await store.createMemory(draft: .init(content: "Private cat fact", scope: .global,
                sensitivity: .sensitive, allowsRemoteUse: false), source: .manualEntry(id: UUID(), statement: "Private cat fact"),
                operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: authorization,
                at: TaskWorkflowFixture.now).memory
            let beforeCount = try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_records") }
            let targets: [(String, Memory, Bool, Int)] = [
                ("stale", stale, false, stale.revision + 1),
                ("foreign", foreign, false, foreign.revision),
                ("private", privateMemory, true, privateMemory.revision),
            ]
            let sessionID = ConversationID()
            for (label, memory, sensitive, revision) in targets {
                let userText = "Remember this added cat detail for \(label)."
                let ref = AgentSourceReference.domain(namespace: "memories", id: memory.id.rawValue, revision: revision)
                let call = try CanonicalToolCall(id: "invalid-\(label)", name: "memory.remember",
                    arguments: rememberArguments(content: "Combined cat fact \(label)", quote: userText,
                        enriches: [ref], sensitive: sensitive).jsonString())
                await f.model.append([modelToolStream([call]), reply("I couldn't update that memory.")])
                let address = try await f.run(userText, sessionID: sessionID)
                let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
                #expect(state.executions[address.executionID]?.completion?.status == .completed)
                let execution = try #require(state.executions[address.executionID])
                let invocation = try #require(execution.attemptIDs.compactMap { state.attempts[$0] }
                    .flatMap(\.invocationIDs).compactMap { state.invocations[$0] }
                    .last(where: { $0.invocation.toolName == "memory.remember" }))
                #expect(invocation.resolution?.status != .succeeded)
                #expect(invocation.resolution?.businessReceipt == nil)
            }
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_records") } == beforeCount)
            #expect(try await f.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_replacements") } == 0)
        }
    }

    @Test func recalledMemoryUsesActualSourceAndHistoricalCitationRevision() async throws {
        let call = CanonicalToolCall(id: "search", name: "memory.search", arguments: "{\"query\":\"green tea\"}")
        try await withTaskWorkflow(
            outputs: [
                modelToolStream([call]), [.blockStarted(.init(id: "text", content: .text("Green tea answer"))), .blockFinished(id: "text"), .finished(.stop)],
            ], memoryEnabled: true
        ) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            let memory = try await store.createMemory(
                draft: .init(content: "I prefer green tea", scope: .global),
                source: .manualEntry(id: UUID(), statement: "I prefer green tea"), operationID: UUID(), replacing: nil,
                expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now
            ).memory
            let address = try await f.run("Which tea do I prefer?")
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            #expect(state.invocations.values.first?.resolution?.status == .succeeded)
            let extraction = try SQLiteMemoryExtractionStore(database: f.database, libraryID: f.authority.libraryID)
            let application = MemoryApplication(
                store: store, extractionStatusReader: extraction, reader: .init(journal: f.library, payloads: f.library),
                access: f.access, scope: f.scope)
            do {
                _ = try await application.reviseMemory(
                    memory.id, workspaceID: nil,
                    draft: .init(content: "Green tea, with clearer wording", scope: .global), expectedRevision: 1,
                    operationID: UUID())
                let detail = try await application.citation(
                    .init(memoryID: memory.id, revision: 1), sessionID: address.sessionID,
                    executionID: address.executionID, workspaceID: nil)
                #expect(detail.revision.draft?.content == "I prefer green tea")
                await #expect(throws: MiraError.self) {
                    _ = try await application.citation(
                        .init(memoryID: memory.id, revision: 2), sessionID: address.sessionID,
                        executionID: address.executionID, workspaceID: nil)
                }
                await application.close()
                await extraction.close()
            } catch {
                await application.close()
                await extraction.close()
                throw error
            }
        }
    }

    @Test func globalMemoryRetainsSourceWorkspacePolicyAndRejectsForgedQuotes() async throws {
        try await withTaskWorkflow(
            outputs: [
                [.blockStarted(.init(id: "text", content: .text("Source received"))), .blockFinished(id: "text"), .finished(.stop)], [.blockStarted(.init(id: "text", content: .text("Target received"))), .blockFinished(id: "text"), .finished(.stop)],
            ], memoryEnabled: true
        ) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            var workspace = Workspace(id: .init(), name: "Original source")
            try await f.workspaces.saveWorkspace(workspace, expectedRevision: nil, authorization: authorization)
            let sourceAddress = try await f.run("I prefer jasmine tea", workspaceID: workspace.id)
            let evidence = try await f.evidence(sourceAddress)
            let memory = try await store.createMemory(
                draft: .init(content: "I prefer jasmine tea", scope: .global),
                source: .userMessage(evidence: evidence, excerpt: evidence.text), operationID: UUID(), replacing: nil,
                expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now
            ).memory
            await #expect(throws: MiraError.self) {
                _ = try await store.createMemory(
                    draft: .init(content: "Forged", scope: .global),
                    source: .userMessage(evidence: evidence, excerpt: "Not said by the user"), operationID: UUID(),
                    replacing: nil, expectedRevision: nil, authorization: authorization, at: TaskWorkflowFixture.now)
            }
            let target = try await f.run("Target with independent context")
            let request = try await context(f, target)
            #expect(
                try await store.recallMemory(memory.id, request: request, at: TaskWorkflowFixture.now).id == memory.id)
            workspace.revision += 1
            workspace.allowsRemoteSend = false
            try await f.workspaces.saveWorkspace(workspace, expectedRevision: 1, authorization: authorization)
            #expect(
                try await store.recallMemories(
                    query: "jasmine tea", request: request, limit: 6, at: TaskWorkflowFixture.now
                ).memories.isEmpty)
            await #expect(throws: MiraError.self) {
                try await store.validateMemorySources(
                    [.domain(namespace: "memories", id: memory.id.rawValue, revision: 1)], for: request,
                    at: TaskWorkflowFixture.now)
            }
        }
    }

    @Test func validityAndDisclosureFiltersPrecedeCandidateLimit() async throws {
        try await withTaskWorkflow(outputs: [[.blockStarted(.init(id: "text", content: .text("Context"))), .blockFinished(id: "text"), .finished(.stop)]], memoryEnabled: true) { f in
            let store = try #require(f.memory)
            let authorization = try await f.authority.authorization()
            let now = TaskWorkflowFixture.now
            let address = try await f.run("Context request")
            let request = try await context(f, address)
            let valid = try await store.createMemory(
                draft: .init(
                    content: "Valid tea", scope: .global, validFrom: now.addingTimeInterval(-60),
                    validUntil: now.addingTimeInterval(60)), source: .manualEntry(id: UUID(), statement: "Valid tea"),
                operationID: UUID(), replacing: nil, expectedRevision: nil, authorization: authorization, at: now
            ).memory
            _ = try await store.createMemory(
                draft: .init(content: "Expired tea", scope: .global, validUntil: now.addingTimeInterval(-1)),
                source: .manualEntry(id: UUID(), statement: "Expired tea"), operationID: UUID(), replacing: nil,
                expectedRevision: nil, authorization: authorization, at: now)
            // One actual SQL transaction inserts an ineligible prefix larger than the search candidate cap.
            try await f.database.write { db in
                for index in 0..<2_005 {
                    _ = try SQLiteMemoryStore.createMemoryInTransaction(
                        draft: .init(content: "Private tea \(index)", scope: .global, allowsRemoteUse: false),
                        source: .manualEntry(id: UUID(), statement: "Private tea \(index)"), operationID: UUID(),
                        replacing: nil, expectedRevision: nil, at: now, in: db)
                }
            }
            let result = try await store.recallMemories(query: "tea", request: request, limit: 6, at: now)
            #expect(result.memories.map(\.id) == [valid.id])
            #expect(!result.isTruncated)
        }
    }

    @Test(arguments: [false, true])
    func saveToolNeedsNoExtraApprovalAndSensitiveMemoriesRemainLocal(explicit: Bool) async throws {
        let content = "I prefer herbal tea"
        let input: JSONValue = .object([
            "content": .string(content), "quote": .string(content), "kind": .string("preference"),
            "scope": .string("global"), "sensitive": .bool(true), "enriches": .array([]),
        ])
        let call = try CanonicalToolCall(id: "remember", name: "memory.remember", arguments: input.jsonString())
        try await withTaskWorkflow(
            outputs: [
                modelToolStream([call]), [.blockStarted(.init(id: "text", content: .text("Saved locally."))), .blockFinished(id: "text"), .finished(.stop)],
            ], memoryEnabled: true
        ) { f in
            let store = try #require(f.memory)
            let address = try await f.run(explicit ? "Remember: " + content : content)
            let state = try await f.runtime.sessionSnapshot(id: address.sessionID)
            let invocation = try #require(state.invocations.values.first)
            #expect(invocation.approval == nil)
            #expect(invocation.resolution?.status == .succeeded)
            let saved = try await store.memoryList(workspaceID: nil, states: [.active], query: "", limit: 10).memories
            #expect(saved.count == 1)
            #expect(saved.first?.draft?.allowsRemoteUse == false)
        }
    }

    private func arguments(content: String) -> JSONValue {
        .object([
            "content": .string(content), "quote": .string(content), "kind": .string("preference"),
            "scope": .string("current"), "sensitive": .bool(false), "enriches": .array([]),
        ])
    }
    private func rememberArguments(content: String, quote: String, enriches: [AgentSourceReference] = [],
                                   replaces: AgentSourceReference? = nil, sensitive: Bool = false) -> JSONValue {
        var fields: [String: JSONValue] = [
            "content": .string(content), "quote": .string(quote), "kind": .string("fact"),
            "scope": .string("global"), "sensitive": .bool(sensitive),
            "enriches": .array(enriches.compactMap { source in
                guard case .domain("memories", let id, let revision) = source else { return nil }
                return .object(["memory_id": .string(id.uuidString.lowercased()), "revision": .number(Double(revision))])
            })
        ]
        if let replaces, case .domain("memories", let id, let revision) = replaces {
            fields["replaces"] = .object(["memory_id": .string(id.uuidString.lowercased()), "revision": .number(Double(revision))])
        }
        return .object(fields)
    }
    private func context(_ f: TaskWorkflowFixture, _ address: AgentExecutionAddress) async throws -> AgentContextRequest
    {
        let evidence = try await f.evidence(address)
        return .init(
            sessionID: address.sessionID, executionID: address.executionID, workspaceID: evidence.workspaceID,
            userText: evidence.text, authorizationEpoch: evidence.sessionAuthorizationEpoch,
            destination: .model(f.route))
    }

    private func reply(_ text: String) -> [AgentModelStreamEvent] {
        [.blockStarted(.init(id: "text", content: .text(text))), .blockFinished(id: "text"), .finished(.stop)]
    }
}
