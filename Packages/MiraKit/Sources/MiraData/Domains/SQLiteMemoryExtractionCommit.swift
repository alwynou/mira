import Foundation
import GRDB
import MiraCore

/// Commits validated automatic-memory proposals into the business database.
/// Journal evidence and library authorization are supplied by the caller; this
/// reducer never reads session or conversation tables.
extension SQLiteMemoryStore {
    static func commitExtractionBatchProposals(
        _ proposals: [MemoryExtractionProposal], claim: MemoryExtractionClaim,
        sources: [SessionUserEvidence], at: Date, in db: Database
    ) throws -> (memoryIDs: [MemoryID], candidateMemoryIDs: [MemoryID], decisions: [MemoryExtractionDecision]) {
        guard !sources.isEmpty, proposals.count <= 6 else { throw invalid }
        var memories: [MemoryID] = [], candidates: [MemoryID] = [], decisions: [MemoryExtractionDecision] = []
        for (index, proposal) in proposals.enumerated() {
            guard sources.indices.contains(proposal.inputIndex) else { throw invalid }
            let source = sources[proposal.inputIndex]
            let selected = [proposal]
            guard selected.allSatisfy({ $0.quote == source.text || source.text.range(of: $0.quote) != nil }) else { throw invalid }
            guard !selected.isEmpty else { continue }
            let result = try commitExtractionProposals(selected, claim: claim, source: source, at: at, in: db)
            for decision in result.decisions where decision.disposition == .created {
                let memory = try read(decision.memoryID, workspaceID: source.workspaceID, in: db)
                guard let draft = memory.draft else { throw invalid }
                for context in sources where context.reference != source.reference {
                    let resolved = try resolve(.userMessage(evidence: context, excerpt: String(context.text.prefix(2_048))), draft: draft, in: db)
                    try bindSource(resolved, in: db)
                    let evidence = MemoryEvidence(memoryID: memory.id, source: resolved.identity,
                        sourceWorkspaceID: context.workspaceID, excerpt: resolved.excerpt,
                        sourceHash: resolved.bodyHash, createdAt: at)
                    try db.execute(sql: "INSERT INTO memory_evidence(id, memory_id, source_key, source_workspace_id, json) VALUES (?, ?, ?, ?, ?)",
                        arguments: [key(evidence.id), key(memory.id), try sourceKey(resolved.identity), context.workspaceID.map(key), try encode(evidence)])
                }
            }
            memories.append(contentsOf: result.memoryIDs)
            candidates.append(contentsOf: result.candidateMemoryIDs)
            decisions.append(contentsOf: result.decisions.map { decision in
                .init(proposalIndex: index, memoryID: decision.memoryID, memoryRevision: decision.memoryRevision,
                      memoryState: decision.memoryState, disposition: decision.disposition,
                      validationReviewReason: decision.validationReviewReason, conflictReason: decision.conflictReason,
                      conflictingMemoryIDs: decision.conflictingMemoryIDs, replacedMemoryID: decision.replacedMemoryID)
            })
        }
        return (memories.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }, candidates.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }, decisions)
    }

    static func commitExtractionProposals(
        _ proposals: [MemoryExtractionProposal],
        claim: MemoryExtractionClaim,
        source: SessionUserEvidence,
        at: Date,
        in db: Database
    ) throws -> (memoryIDs: [MemoryID], candidateMemoryIDs: [MemoryID], decisions: [MemoryExtractionDecision]) {
        try claim.validate()
        try MemoryExtractionRequestBuilder.validate(source: source)
        try date(at)
        guard (source.reference == claim.source.reference || claim.job.turns.contains { $0.source == source.reference }),
            source.workspaceID == claim.job.workspaceID,
            claim.batchSources.contains(where: {
                $0.reference == source.reference && $0.text == source.text &&
                $0.workspaceID == source.workspaceID && $0.admittedAt == source.admittedAt &&
                $0.timeZoneIdentifier == source.timeZoneIdentifier &&
                $0.sessionAuthorizationEpoch == source.sessionAuthorizationEpoch
            }),
            source.sessionAuthorizationEpoch == claim.source.sessionAuthorizationEpoch,
            proposals.count <= 6
        else { throw invalid }

        let sourceIdentity = MemoryEvidenceSource.userMessage(source.reference)
        guard try !suppressedMemorySource(sourceIdentity, in: db) else { throw unauthorized }

        var memoryIDs: [MemoryID] = []
        var candidateIDs: [MemoryID] = []
        var decisions: [MemoryExtractionDecision] = []
        for (index, proposal) in proposals.enumerated() {
            try validate(proposal, source: source)
            guard proposal.triage == .active else { continue }
            let resolved = try resolve(
                .userMessage(evidence: source, excerpt: proposal.quote), draft: proposal.draft, in: db)
            try bindSource(resolved, in: db)
            let assertionKey = try assertionKey(draft: proposal.draft, source: sourceIdentity)

            if let row = try Row.fetchOne(
                db, sql: "SELECT memory_id FROM memory_assertions WHERE assertion_key = ?", arguments: [assertionKey])
            {
                let memory = try read(
                    .init(try uuid(row["memory_id"])), workspaceID: proposal.draft.scope.workspaceID, in: db)
                guard memory.forgottenAt == nil, memory.deletedAt == nil,
                    ![.removed, .rejected].contains(memory.state)
                else { throw conflict }
                decisions.append(
                    .init(
                        proposalIndex: index, memoryID: memory.id, memoryRevision: memory.revision,
                        memoryState: memory.state, disposition: .reused,
                        validationReviewReason: proposal.reviewReason))
                append(memory, to: &memoryIDs, candidates: &candidateIDs)
                continue
            }

            if let duplicate = claim.existingMemories.first(where: {
                $0.scope == proposal.draft.scope && $0.subject == proposal.draft.subject &&
                $0.draft.map { normalized($0.content) == normalized(proposal.draft.content) } == true
            }) {
                let current = try read(duplicate.id, workspaceID: source.workspaceID, in: db)
                guard current.revision == duplicate.revision, current.isCurrent else { throw conflict }
                decisions.append(.init(proposalIndex: index, memoryID: current.id, memoryRevision: current.revision,
                                       memoryState: current.state, disposition: .reused, validationReviewReason: nil))
                append(current, to: &memoryIDs, candidates: &candidateIDs)
                continue
            }
            let matches: [(memory: Memory, metadataRevision: Int)]
            if let target = proposal.replacesIndex {
                guard claim.existingMemories.indices.contains(target) else { throw invalid }
                let expected = claim.existingMemories[target]
                let current = try read(expected.id, workspaceID: source.workspaceID, in: db)
                guard current == expected else { throw conflict }
                matches = [(current, current.revision)]
            } else {
                matches = try matchingMemories(for: proposal, in: db)
            }
            let current = matches.count == 1 ? matches[0] : nil
            let replaces =
                current.map {
                    canAutomaticallyReplace(
                        $0.memory, metadataRevision: $0.metadataRevision,
                        proposal: proposal, source: source)
                } ?? false
            // Automatic extraction never creates a review inbox. Ambiguous
            // conflicts and low-confidence items are skipped atomically.
            guard proposal.triage == .active, matches.isEmpty || replaces else { continue }
            let state: MemoryState = .active
            let memory = Memory(
                draft: proposal.draft, scope: proposal.draft.scope, subject: proposal.draft.subject,
                state: state, origin: proposal.origin, authority: proposal.authority,
                createdAt: at, updatedAt: at)
            try write(memory, insert: true, in: db)

            let evidence = MemoryEvidence(
                memoryID: memory.id, source: sourceIdentity,
                sourceWorkspaceID: source.workspaceID, excerpt: resolved.excerpt,
                sourceHash: resolved.bodyHash, createdAt: at)
            try db.execute(
                sql:
                    "INSERT INTO memory_evidence(id, memory_id, source_key, source_workspace_id, json) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    key(evidence.id), key(memory.id), try sourceKey(sourceIdentity), source.workspaceID.map(key),
                    try encode(evidence),
                ])
            try db.execute(
                sql: "INSERT INTO memory_assertions(assertion_key, memory_id, source_key) VALUES (?, ?, ?)",
                arguments: [assertionKey, key(memory.id), try sourceKey(sourceIdentity)])
            try insertAspectMetadata(
                proposal.assertion, memoryID: memory.id, memoryRevision: memory.revision,
                source: sourceIdentity, sourceHash: resolved.bodyHash, at: at, in: db)

            if replaces, let current {
                var old = current.memory
                try writeRelation(
                    .init(replacementID: memory.id, previousID: old.id, state: .confirmed, createdAt: at), in: db)
                old.supersededBy = memory.id
                old.revision += 1
                old.updatedAt = at
                try write(old, insert: false, in: db)
            } else {
                for match in matches {
                    try writeRelation(
                        .init(
                            replacementID: memory.id, previousID: match.memory.id,
                            state: .proposed, createdAt: at), in: db)
                }
            }
            let conflictReason: MemoryExtractionConflictReason? =
                replaces || matches.isEmpty
                ? nil
                : (matches.count == 1 ? .currentMemoryRequiresReview : .multipleCurrentMemories)
            decisions.append(
                .init(
                    proposalIndex: index, memoryID: memory.id, memoryRevision: memory.revision,
                    memoryState: memory.state, disposition: .created,
                    validationReviewReason: proposal.reviewReason, conflictReason: conflictReason,
                    conflictingMemoryIDs: matches.map { $0.memory.id },
                    replacedMemoryID: replaces ? current?.memory.id : nil))
            append(memory, to: &memoryIDs, candidates: &candidateIDs)
        }
        for decision in decisions { try decision.validate() }
        return (memoryIDs, candidateIDs, decisions)
    }

    private static func append(_ memory: Memory, to ids: inout [MemoryID], candidates: inout [MemoryID]) {
        if !ids.contains(memory.id) { ids.append(memory.id) }
        if memory.state == .candidate, !candidates.contains(memory.id) { candidates.append(memory.id) }
    }

    private static func validate(
        _ proposal: MemoryExtractionProposal, source: SessionUserEvidence
    ) throws {
        try proposal.draft.validate()
        guard !proposal.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            proposal.quote.utf8.count <= 8_192,
            source.text.range(of: proposal.quote) != nil,
            proposal.draft.scope.workspaceID == source.workspaceID
        else { throw invalid }
        switch (proposal.origin, proposal.authority) {
        case (.observedUserStatement, .observedUser), (.agentInference, .inferred): break
        default: throw invalid
        }
        try validateAspect(proposal.assertion)
        if proposal.triage == .active {
            guard proposal.assertion.mode == .directStable,
                  proposal.assertion.changeIntent != .uncertain,
                  proposal.origin == .observedUserStatement, proposal.authority == .observedUser,
                  proposal.draft.sensitivity == .standard else { throw invalid }
        }
    }

    private static func validateAspect(_ assertion: MemoryAssertionMetadata) throws {
        guard let key = assertion.aspectKey else { return }
        let bytes = Array(key.utf8)
        guard (3...96).contains(bytes.count), !key.hasPrefix("."), !key.hasSuffix("."), !key.contains(".."),
            key.unicodeScalars.allSatisfy({
                ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0.value == 45
                    || $0.value == 46
            }),
            (2...4).contains(key.split(separator: ".").count),
            key.split(separator: ".").allSatisfy({ $0.first?.isASCII == true && $0.first?.isLetter == true })
        else { throw invalid }
    }

    private static func matchingMemories(for proposal: MemoryExtractionProposal, in db: Database) throws -> [(
        memory: Memory, metadataRevision: Int
    )] {
        guard let aspect = proposal.assertion.aspectKey else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT m.*, a.memory_revision AS aspect_memory_revision,
                       a.source_json AS aspect_source_json, a.source_hash AS aspect_source_hash,
                       a.semantic_key AS aspect_semantic_key, a.assertion_mode AS aspect_assertion_mode,
                       a.change_intent AS aspect_change_intent, a.metadata_json AS aspect_metadata_json,
                       a.created_at AS aspect_created_at, a.body_purged_at AS aspect_body_purged_at,
                       a.source_key AS aspect_source_key
                FROM memory_records m JOIN memory_extraction_aspects a ON a.memory_id = m.id
                WHERE m.scope = ? AND json_extract(m.json, '$.subject') = ? AND m.state = 'active'
                  AND m.superseded_by IS NULL AND m.forgotten_at IS NULL AND m.deleted_at IS NULL
                  AND json_extract(m.json, '$.draft.kind') = ?
                  AND a.semantic_key = ? AND a.body_purged_at IS NULL
                ORDER BY m.id LIMIT 101
                """,
            arguments: [
                proposal.draft.scope.key, proposal.draft.subject.rawValue,
                proposal.draft.kind.rawValue, aspect,
            ])
        guard rows.count <= 100 else { throw limit }
        return try rows.map { row in
            let memory = try record(row)
            let metadata = try validatedAspect(row, memory: memory, in: db)
            return (memory, metadata.memoryRevision)
        }
    }

    private static func canAutomaticallyReplace(
        _ current: Memory, metadataRevision: Int,
        proposal: MemoryExtractionProposal,
        source: SessionUserEvidence
    ) -> Bool {
        guard proposal.triage == .active,
            proposal.assertion.mode == .directStable,
            proposal.assertion.changeIntent == .explicitReplacement,
            metadataRevision == current.revision,
            current.state == .active, current.supersededBy == nil,
            current.deletedAt == nil, current.forgottenAt == nil,
            let oldDraft = current.draft,
            oldDraft.scope == proposal.draft.scope,
            oldDraft.subject == proposal.draft.subject,
            oldDraft.kind == proposal.draft.kind,
            oldDraft.sensitivity == proposal.draft.sensitivity,
            oldDraft.allowsRemoteUse == proposal.draft.allowsRemoteUse,
            oldDraft.allowedConnectionIDs == proposal.draft.allowedConnectionIDs,
            (try? compatible(proposal.draft, previous: current)) != nil
        else { return false }
        return true
    }

    private static func insertAspectMetadata(
        _ assertion: MemoryAssertionMetadata, memoryID: MemoryID,
        memoryRevision: Int, source: MemoryEvidenceSource,
        sourceHash: String, at: Date, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO memory_extraction_aspects
                  (memory_id, memory_revision, source_key, source_json, source_hash, semantic_key, assertion_mode,
                   change_intent, metadata_json, created_at, body_purged_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
            arguments: [
                key(memoryID), memoryRevision, try sourceKey(source), try encode(source), sourceHash,
                assertion.aspectKey, assertion.mode.rawValue, assertion.changeIntent.rawValue,
                try encode(assertion), at.timeIntervalSince1970,
            ])
    }

    private static func validatedAspect(_ row: Row, memory: Memory, in db: Database) throws -> (
        memoryRevision: Int, assertion: MemoryAssertionMetadata, source: MemoryEvidenceSource
    ) {
        guard let sourceBytes: Data = row["aspect_source_json"],
            let metadataBytes: Data = row["aspect_metadata_json"],
            let sourceHash: String = row["aspect_source_hash"], sourceHash.utf8.count == 64,
            let modeValue: String = row["aspect_assertion_mode"],
            let changeValue: String = row["aspect_change_intent"],
            let mode = MemoryAssertionMode(rawValue: modeValue),
            let changeIntent = MemoryChangeIntent(rawValue: changeValue),
            let memoryRevision: Int = row["aspect_memory_revision"], memoryRevision > 0,
            let createdAt: Double = row["aspect_created_at"], createdAt.isFinite,
            row["aspect_body_purged_at"] as Double? == nil
        else { throw corrupt }
        let source: MemoryEvidenceSource = try decode(sourceBytes)
        let assertion: MemoryAssertionMetadata = try decode(metadataBytes)
        guard case .userMessage(let reference) = source else { throw corrupt }
        do { try reference.validate() } catch { throw corrupt }
        guard let storedSourceKey: String = row["aspect_source_key"] else { throw corrupt }
        guard assertion.mode == mode, assertion.changeIntent == changeIntent,
            assertion.aspectKey == (row["aspect_semantic_key"] as String?),
            assertion.aspectKey.map({ (3...96).contains($0.utf8.count) }) ?? true,
            try sourceKey(source) == storedSourceKey
        else { throw corrupt }
        let evidence = try evidence(memory.id, in: db)
        guard
            evidence.contains(where: { $0.source == source && $0.sourceHash == sourceHash && $0.bodyPurgedAt == nil }),
            memoryRevision <= memory.revision
        else { throw corrupt }
        return (memoryRevision, assertion, source)
    }
}
