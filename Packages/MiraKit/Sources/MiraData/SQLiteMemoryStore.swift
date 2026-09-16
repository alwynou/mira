import Foundation
import CryptoKit
import GRDB
import MiraCore

/// Canonical memory business data. Original user evidence is resolved outside SQLite under a library lease.
public final class SQLiteMemoryStore: MemoryStore, @unchecked Sendable {
    let owner: SQLiteDomainDatabase
    let embeddings: (any MemoryEmbeddingService)?
    public init(database: DatabaseQueue, libraryID: UUID, embeddings: (any MemoryEmbeddingService)? = nil) throws {
        self.embeddings = embeddings
        owner = try SQLiteDomainDatabase(database: database, libraryID: libraryID, label: "mira.memories")
        try database.write { db in
            guard try db.tableExists("business_workspaces") else { throw Self.corrupt }
            try Self.initialize(in: db)
            try SQLiteMemoryExtractionSchema.initialize(in: db)
            try Self.initializeVectors(identity: embeddings?.identity ?? .qwen3FourBit, in: db)
        }
    }
    public func close() async { await owner.close() }

    public func memoryList(workspaceID: WorkspaceID?, states: Set<MemoryState>, query: String, limit: Int) async throws -> MemorySearchResult {
        try await owner.read { try Self.search(query: query, workspaceID: workspaceID, states: states, request: nil, limit: limit, at: nil, in: $0) }
    }
    public func memoryDetail(_ id: MemoryID, workspaceID: WorkspaceID?) async throws -> MemoryDetail {
        try await owner.read { db in
            let memory = try Self.read(id, workspaceID: workspaceID, in: db)
            let revisions = try Row.fetchAll(db, sql: "SELECT * FROM memory_revisions WHERE memory_id = ? ORDER BY revision DESC LIMIT 100", arguments: [Self.key(id)]).map { try Self.revision($0, memoryID: id) }
            let relations = try Row.fetchAll(db, sql: "SELECT * FROM memory_replacements WHERE replacement_id = ? OR previous_id = ? ORDER BY id LIMIT 1001", arguments: [Self.key(id), Self.key(id)]).map(Self.relation)
            guard relations.count <= 1000 else { throw Self.corrupt }
            return .init(memory: memory, evidence: try Self.evidence(id, in: db), revisions: revisions, replacements: relations)
        }
    }
    public func memoryCitationRevision(_ reference: MemoryCitationReference, workspaceID: WorkspaceID?) async throws -> MemoryCitationDetail {
        try await owner.read { db in
            let memory = try Self.read(reference.memoryID, workspaceID: workspaceID, in: db)
            guard memory.forgottenAt == nil, memory.deletedAt == nil,
                  ![MemoryState.rejected, .removed].contains(memory.state), reference.revision > 0,
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_revisions WHERE memory_id = ? AND revision = ?", arguments: [Self.key(reference.memoryID), reference.revision]) else { throw Self.unavailable }
            let revision = try Self.revision(row, memoryID: reference.memoryID)
            guard revision.draft != nil, revision.bodyPurgedAt == nil else { throw Self.unavailable }
            return .init(memory: memory, revision: revision, evidence: try Self.evidence(memory.id, in: db))
        }
    }
    public func recallMemories(query: String, request: AgentContextRequest, limit: Int, at: Date) async throws -> MemorySearchResult {
        guard (1...128).contains(limit), query.unicodeScalars.count <= 500 else { throw Self.invalid }
        try await owner.read { try Self.validateDestination(request, in: $0) }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .init(memories: []) }
        var queryVector: [Float]?
        if let embeddings, await embeddings.status() == .ready {
            do {
                let vectors = try await embeddings.embed(.query(query))
                guard vectors.count == 1 else { throw Self.invalid }
                queryVector = vectors[0]
            } catch is CancellationError { throw CancellationError() } catch {
                // Local inference is optional. Destination validation and canonical reads still fail closed below.
                queryVector = nil
            }
        }
        let vector = queryVector
        let identity = embeddings?.identity
        return try await owner.read { db in
            try Self.validateDestination(request, in: db)
            let lexical = try Self.search(query: query, workspaceID: request.workspaceID, states: [.active], request: request, limit: limit, at: at, in: db)
            guard let vector, let identity else { return lexical }
            let semantic = try Self.semanticSearch(vector: vector, identity: identity, request: request, limit: limit, at: at, in: db)
            guard !semantic.memories.isEmpty else { return lexical }
            // Keep semantic ranking primary; reserve one slot for a literal lexical match or an unindexed fact.
            // Similarity is relevance, never proof of the user's subject or an answer's truth.
            let semanticIDs = Set(semantic.memories.map(\.id))
            let extra = limit > 1 ? lexical.memories.first { !semanticIDs.contains($0.id) } : nil
            var values = Array(semantic.memories.prefix(extra == nil ? limit : max(0, limit - 1)))
            if let extra { values.append(extra) }
            let selectedIDs = Set(values.map(\.id))
            let omitted = semantic.memories.contains { !selectedIDs.contains($0.id) }
                || lexical.memories.contains { !selectedIDs.contains($0.id) }
            return .init(memories: values, isTruncated: lexical.isTruncated || semantic.isTruncated || omitted,
                         retrieval: .hybrid)
        }
    }
    public func recallMemory(_ id: MemoryID, request: AgentContextRequest, at: Date) async throws -> Memory {
        try await owner.read { try Self.recall(id, request: request, at: at, in: $0) }
    }
    public func validateMemorySources(_ sources: [AgentSourceReference], for request: AgentContextRequest, at: Date) async throws {
        try await owner.read { try Self.validateMemorySources(sources, for: request, at: at, in: $0) }
    }
    static func validateMemorySources(_ sources: [AgentSourceReference], for request: AgentContextRequest,
                                     at: Date, in db: Database) throws {
        guard sources.count <= 8_192, Set(sources).count == sources.count else { throw Self.invalid }
        try Self.validateDestination(request, in: db)
        for source in sources {
            guard case .domain(let namespace, let id, let revision) = source,
                  namespace == "memories", revision > 0 else { throw Self.unauthorized }
            let memory = try Self.recall(.init(id), request: request, at: at, in: db)
            guard memory.revision == revision else { throw Self.unauthorized }
        }
    }
    public func suppressedMemorySources() async throws -> [MemoryEvidenceSource] {
        try await owner.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM memory_sources WHERE suppression > 0 ORDER BY source_key LIMIT 8193")
            guard rows.count <= 8_192 else { throw Self.limit }
            return try rows.map(Self.sourceIdentity)
        }
    }
    public func createMemory(draft: MemoryDraft, source: MemoryWriteSource, operationID: UUID, replacing: MemoryID?, expectedRevision: Int?, authorization: AgentLibraryAuthorization, at: Date) async throws -> MemoryWriteReceipt {
        try await owner.write(authorization: authorization) {
            try Self.createMemoryInTransaction(draft: draft, source: source, operationID: operationID, replacing: replacing, expectedRevision: expectedRevision, at: at, in: $0)
        }
    }
    public func reviseMemory(_ id: MemoryID, workspaceID: WorkspaceID?, draft: MemoryDraft, expectedRevision: Int, operationID: UUID, authorization: AgentLibraryAuthorization, at: Date) async throws -> Memory {
        try draft.validate(); try Self.date(at)
        let request = try Self.fingerprint(kind: "revise", id: id, workspaceID: workspaceID, draft: draft, expectedRevision: expectedRevision)
        return try await owner.write(authorization: authorization) { db in
            if let prior = try Self.operation(operationID, request: request, in: db) { return prior.memory }
            var memory = try Self.mutable(id, workspaceID: workspaceID, expected: expectedRevision, in: db)
            guard memory.scope == draft.scope, memory.subject == draft.subject else { throw Self.conflict }
            memory.draft = draft; memory.revision += 1; memory.updatedAt = at
            try Self.write(memory, insert: false, in: db)
            try Self.saveOperation(operationID, request: request, receipt: .init(memory: memory, disposition: .existing), dependencies: [id], in: db)
            return memory
        }
    }
    public func changeMemoryState(_ id: MemoryID, workspaceID: WorkspaceID?, state: MemoryState, expectedRevision: Int, operationID: UUID, authorization: AgentLibraryAuthorization, at: Date) async throws -> Memory {
        try Self.date(at)
        let request = try Self.fingerprint(kind: "state", id: id, workspaceID: workspaceID, expectedRevision: expectedRevision, state: state)
        return try await owner.write(authorization: authorization) { db in
            if let prior = try Self.operation(operationID, request: request, in: db) { return prior.memory }
            var memory = try Self.mutable(id, workspaceID: workspaceID, expected: expectedRevision, in: db)
            if state == .active {
                guard memory.supersededBy == nil,
                      try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_replacements WHERE replacement_id = ? AND state = 'proposed'", arguments: [Self.key(id)]) == 0 else { throw Self.conflict }
            }
            memory.state = state; memory.revision += 1; memory.updatedAt = at
            memory.deletedAt = state == .removed ? at : nil
            if state == .rejected || state == .removed {
                for evidence in try Self.evidence(id, in: db) { try Self.suppress(evidence.source, strength: state == .rejected ? 2 : 1, in: db) }
                for row in try Row.fetchAll(db, sql: "SELECT * FROM memory_replacements WHERE replacement_id = ? AND state = 'proposed'", arguments: [Self.key(id)]) {
                    var relation = try Self.relation(row); relation.state = .rejected; try Self.writeRelation(relation, in: db)
                }
            }
            try Self.write(memory, insert: false, in: db)
            try Self.saveOperation(operationID, request: request, receipt: .init(memory: memory, disposition: .existing), dependencies: [id], in: db)
            return memory
        }
    }
    public func confirmMemoryReplacement(_ candidateID: MemoryID, workspaceID: WorkspaceID?, replacingCurrent currentID: MemoryID, expectedCandidateRevision: Int, expectedCurrentRevision: Int, operationID: UUID, authorization: AgentLibraryAuthorization, at: Date) async throws -> Memory {
        try Self.date(at)
        let request = try Self.fingerprint(kind: "confirm", id: candidateID, workspaceID: workspaceID, replacing: currentID, expectedRevision: expectedCandidateRevision, otherRevision: expectedCurrentRevision)
        return try await owner.write(authorization: authorization) { db in
            if let prior = try Self.operation(operationID, request: request, in: db) { return prior.memory }
            var candidate = try Self.mutable(candidateID, workspaceID: workspaceID, expected: expectedCandidateRevision, in: db)
            var current = try Self.mutable(currentID, workspaceID: workspaceID, expected: expectedCurrentRevision, in: db)
            guard candidateID != currentID, candidate.state == .candidate,
                  candidate.supersededBy == nil, current.isCurrent else { throw Self.conflict }
            let proposals = try Row.fetchAll(
                db, sql: "SELECT * FROM memory_replacements WHERE replacement_id = ? AND state = 'proposed' ORDER BY previous_id LIMIT 101",
                arguments: [Self.key(candidateID)]).map(Self.relation)
            guard !proposals.isEmpty, proposals.count <= 100 else { throw Self.conflict }
            var matched = false
            for proposal in proposals {
                var ancestor = try Self.read(proposal.previousID, workspaceID: workspaceID, in: db)
                var seen = Set<MemoryID>()
                while true {
                    guard ancestor.forgottenAt == nil, ancestor.deletedAt == nil,
                          ![.rejected, .removed].contains(ancestor.state) else { break }
                    if ancestor.id == currentID { matched = true; break }
                    guard seen.insert(ancestor.id).inserted, seen.count <= 100 else { throw Self.corrupt }
                    guard let successor = ancestor.supersededBy else { break }
                    ancestor = try Self.read(successor, workspaceID: workspaceID, in: db)
                }
            }
            guard matched else { throw Self.conflict }
            try Self.compatible(candidate.draft, previous: current)
            var confirmedDirectly = false
            for var proposal in proposals {
                if proposal.previousID == currentID {
                    proposal.state = .confirmed
                    confirmedDirectly = true
                } else {
                    proposal.state = .rejected
                }
                try Self.writeRelation(proposal, in: db)
            }
            if !confirmedDirectly {
                try Self.writeRelation(.init(replacementID: candidateID, previousID: currentID,
                                             state: .confirmed, createdAt: at), in: db)
            }
            current.supersededBy = candidateID; current.revision += 1; current.updatedAt = at
            candidate.state = .active; candidate.revision += 1; candidate.updatedAt = at
            try Self.write(current, insert: false, in: db); try Self.write(candidate, insert: false, in: db)
            try Self.saveOperation(operationID, request: request, receipt: .init(memory: candidate, disposition: .existing), dependencies: [candidateID, currentID], in: db)
            return candidate
        }
    }
    public func purgeMemory(_ id: MemoryID, workspaceID: WorkspaceID?, expectedRevision: Int, maintenance: AgentLibraryMaintenanceOperation, at: Date) async throws -> MemoryForgetReceipt {
        try Self.date(at)
        guard maintenance.request.namespace == "memory.forget", maintenance.request.revision == 1,
              maintenance.request.scope == .sources([.domain(namespace: "memories", id: id.rawValue, revision: expectedRevision)]) else { throw Self.unauthorized }
        return try await owner.maintain(maintenance) { db in
            let operationID = Self.key(maintenance.request.id)
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_purges WHERE operation_id = ?", arguments: [operationID]) {
                let receipt: MemoryForgetReceipt = try Self.decode(row["json"])
                guard receipt.memoryID == id, row["workspace_id"] as String? == workspaceID.map(Self.key), row["expected_revision"] as Int == expectedRevision else { throw Self.conflict }
                return receipt
            }
            var memory = try Self.mutable(id, workspaceID: workspaceID, expected: expectedRevision, in: db)
            let sources = try Self.evidence(id, in: db)
            try SQLiteMemoryExtractionStore.purgeMemoryDependencies(id, at: at, in: db)
            memory.draft = nil; memory.forgottenAt = at; memory.revision += 1; memory.updatedAt = at
            try Self.write(memory, insert: false, in: db)
            for row in try Row.fetchAll(db, sql: "SELECT * FROM memory_revisions WHERE memory_id = ?", arguments: [Self.key(id)]) {
                var revision = try Self.revision(row, memoryID: id); revision.draft = nil; revision.bodyPurgedAt = at
                try db.execute(sql: "UPDATE memory_revisions SET json = ? WHERE memory_id = ? AND revision = ?", arguments: [try Self.encode(revision), Self.key(id), revision.revision])
            }
            for var evidence in sources {
                evidence.excerpt = nil; evidence.sourceHash = nil; evidence.bodyPurgedAt = at
                try db.execute(sql: "UPDATE memory_evidence SET json = ? WHERE id = ?", arguments: [try Self.encode(evidence), Self.key(evidence.id)])
                try Self.suppress(evidence.source, strength: 3, in: db)
                try SQLiteMemoryExtractionStore.purge(source: evidence.source, at: at, in: db)
                try db.execute(sql: "UPDATE memory_sources SET body_hash = NULL WHERE source_key = ?", arguments: [try Self.sourceKey(evidence.source)])
            }
            try db.execute(sql: "DELETE FROM memory_assertions WHERE memory_id = ?", arguments: [Self.key(id)])
            try db.execute(sql: "DELETE FROM memory_extraction_aspects WHERE memory_id = ?", arguments: [Self.key(id)])
            try db.execute(sql: "UPDATE memory_operations SET request_hash = NULL, receipt_json = NULL WHERE operation_id IN (SELECT operation_id FROM memory_operation_dependencies WHERE memory_id = ?)", arguments: [Self.key(id)])
            let receipt = MemoryForgetReceipt(memoryID: id, suppressedSources: sources.map(\.source))
            try db.execute(sql: "INSERT INTO memory_purges(operation_id, memory_id, workspace_id, expected_revision, json) VALUES (?, ?, ?, ?, ?)", arguments: [operationID, Self.key(id), workspaceID.map(Self.key), expectedRevision, try Self.encode(receipt)])
            return receipt
        }
    }

    static func createMemoryInTransaction(draft: MemoryDraft, source: MemoryWriteSource, operationID: UUID, replacing: MemoryID?, expectedRevision: Int?, at: Date, in db: Database) throws -> MemoryWriteReceipt {
        try draft.validate(); try date(at)
        let resolved = try resolve(source, draft: draft, in: db)
        let request = try fingerprint(kind: "create", draft: draft, source: resolved.input, replacing: replacing, expectedRevision: expectedRevision)
        if let prior = try operation(operationID, request: request, in: db) { return prior }
        guard (replacing == nil) == (expectedRevision == nil) else { throw invalid }
        try bindSource(resolved, in: db)
        let assertionKey = try assertionKey(draft: draft, source: resolved.identity)
        if let row = try Row.fetchOne(db, sql: "SELECT memory_id FROM memory_assertions WHERE assertion_key = ?", arguments: [assertionKey]) {
            let memory = try read(.init(try uuid(row["memory_id"])), workspaceID: draft.scope.workspaceID, in: db)
            guard memory.forgottenAt == nil, memory.deletedAt == nil, ![MemoryState.removed, .rejected].contains(memory.state), replacing == nil else { throw conflict }
            let receipt = MemoryWriteReceipt(memory: memory, disposition: .existing)
            try saveOperation(operationID, request: request, receipt: receipt, dependencies: [memory.id], in: db)
            return receipt
        }
        var previous = try replacing.map { try mutable($0, workspaceID: draft.scope.workspaceID, expected: expectedRevision!, in: db) }
        if let previous { try compatible(draft, previous: previous) }
        let proposed = previous?.supersededBy != nil
        let memory = Memory(draft: draft, scope: draft.scope, subject: draft.subject, state: proposed ? .candidate : .active, createdAt: at, updatedAt: at)
        try write(memory, insert: true, in: db)
        let evidence = MemoryEvidence(memoryID: memory.id, source: resolved.identity, sourceWorkspaceID: resolved.workspaceID,
                                      excerpt: resolved.excerpt, sourceHash: resolved.bodyHash, createdAt: at)
        try db.execute(sql: "INSERT INTO memory_evidence(id, memory_id, source_key, source_workspace_id, json) VALUES (?, ?, ?, ?, ?)", arguments: [key(evidence.id), key(memory.id), try sourceKey(resolved.identity), resolved.workspaceID.map(key), try encode(evidence)])
        try db.execute(sql: "INSERT INTO memory_assertions(assertion_key, memory_id, source_key) VALUES (?, ?, ?)", arguments: [assertionKey, key(memory.id), try sourceKey(resolved.identity)])
        if var old = previous {
            try writeRelation(.init(replacementID: memory.id, previousID: old.id, state: proposed ? .proposed : .confirmed, createdAt: at), in: db)
            if !proposed { old.supersededBy = memory.id; old.revision += 1; old.updatedAt = at; try write(old, insert: false, in: db); previous = old }
        }
        let receipt = MemoryWriteReceipt(memory: memory, disposition: proposed ? .replacementProposed : .created)
        try saveOperation(operationID, request: request, receipt: receipt, dependencies: [memory.id] + (previous.map { [$0.id] } ?? []), in: db)
        return receipt
    }
    static func suppressedMemorySource(_ source: MemoryEvidenceSource, in db: Database) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memory_sources WHERE source_key = ?", arguments: [try sourceKey(source)]) else { return false }
        guard try sourceIdentity(row) == source else { throw corrupt }
        return row["suppression"] as Int > 0
    }
}
