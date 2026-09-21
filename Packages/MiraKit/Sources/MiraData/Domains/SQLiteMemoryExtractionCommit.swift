import Foundation
import GRDB
import MiraCore

/// Commits validated proposals and their evolution in one business transaction.
/// The model identifies semantic relationships; source, policy and revision
/// authority remain host-owned. Similarity and aspect keys never authorize enrichment.
extension SQLiteMemoryStore {
    static func commitExtractionBatchProposals(
        _ proposals: [MemoryExtractionProposal], claim: MemoryExtractionClaim,
        sources: [SessionUserEvidence], at: Date, in db: Database
    ) throws -> (memoryIDs: [MemoryID], candidateMemoryIDs: [MemoryID], decisions: [MemoryExtractionDecision]) {
        try claim.validate()
        try date(at)
        guard !sources.isEmpty, sources.count == claim.batchSources.count, proposals.count <= 6 else { throw invalid }
        for (source, expected) in zip(sources, claim.batchSources) {
            try MemoryExtractionRequestBuilder.validate(source: source)
            guard source.reference == expected.reference, source.text == expected.text,
                source.workspaceID == expected.workspaceID, source.admittedAt == expected.admittedAt,
                source.timeZoneIdentifier == expected.timeZoneIdentifier,
                source.sessionAuthorizationEpoch == expected.sessionAuthorizationEpoch,
                source.sessionAuthorizationEpoch == claim.source.sessionAuthorizationEpoch,
                source.workspaceID == claim.job.workspaceID,
                source.reference == claim.source.reference || claim.job.turns.contains(where: { $0.source == source.reference })
            else { throw invalid }
            guard try !suppressedMemorySource(.userMessage(source.reference), in: db) else { throw unauthorized }
        }

        var decisions: [MemoryExtractionDecision] = []
        // Raw output positions stay stable even when an item is skipped.
        var committed: [Int: Memory] = [:]
        for (index, proposal) in proposals.enumerated() {
            guard sources.indices.contains(proposal.inputIndex) else { throw invalid }
            let source = sources[proposal.inputIndex]
            try validate(proposal, source: source)
            try validateEvolutionTarget(proposal, index: index, existingCount: claim.existingMemories.count)
            guard proposal.triage == .active else { continue }
            if let target = proposal.replacesProposalIndex, committed[target] == nil { continue }

            let resolved = try resolve(.userMessage(evidence: source, excerpt: proposal.quote), draft: proposal.draft, in: db)
            try bindSource(resolved, in: db)
            let assertion = try assertionKey(draft: proposal.draft, source: resolved.identity)
            if let row = try Row.fetchOne(db, sql: "SELECT memory_id FROM memory_assertions WHERE assertion_key = ?", arguments: [assertion]) {
                let memory = try read(.init(try uuid(row["memory_id"])), workspaceID: source.workspaceID, in: db)
                guard memory.forgottenAt == nil, memory.deletedAt == nil, ![.removed, .rejected].contains(memory.state) else { throw conflict }
                decisions.append(.init(proposalIndex: index, memoryID: memory.id, memoryRevision: memory.revision,
                    memoryState: memory.state, disposition: .reused, validationReviewReason: nil))
                committed[index] = memory
                continue
            }

            // Also reuse exact assertions produced by earlier items in this batch.
            // Compare policy and validity as well as text; deduplication cannot widen disclosure.
            let candidates = claim.existingMemories + committed.keys.sorted().compactMap { committed[$0] }
            let duplicates = candidates.filter { sameAssertion($0, draft: proposal.draft) }
            var duplicate: Memory?
            for expected in duplicates {
                let current = try read(expected.id, workspaceID: source.workspaceID, in: db)
                // Earlier items may have evolved inside this transaction. They are no longer duplicate targets.
                if current.supersededBy != nil { continue }
                guard current == expected, current.isCurrent else { throw conflict }
                duplicate = current
                break
            }
            if let duplicate {
                decisions.append(.init(proposalIndex: index, memoryID: duplicate.id, memoryRevision: duplicate.revision,
                    memoryState: duplicate.state, disposition: .reused, validationReviewReason: nil))
                committed[index] = duplicate
                continue
            }

            let matches: [(memory: Memory, metadataRevision: Int)]
            if let target = proposal.replacesIndex {
                let expected = claim.existingMemories[target]
                let current = try read(expected.id, workspaceID: source.workspaceID, in: db)
                guard current == expected else { throw conflict }
                matches = [(current, current.revision)]
            } else if let target = proposal.replacesProposalIndex {
                guard let expected = committed[target] else { continue }
                let current = try read(expected.id, workspaceID: source.workspaceID, in: db)
                guard current == expected else { throw conflict }
                matches = [(current, current.revision)]
            } else {
                matches = try matchingMemories(for: proposal, in: db)
            }
            let previous = matches.count == 1 ? matches[0] : nil
            let evolves = previous.map {
                canAutomaticallyReplace($0.memory, metadataRevision: $0.metadataRevision, proposal: proposal, at: at)
            } ?? false
            guard matches.isEmpty || evolves else { continue }
            let memory = Memory(draft: proposal.draft, scope: proposal.draft.scope, subject: proposal.draft.subject,
                state: .active, origin: proposal.origin, authority: proposal.authority, createdAt: at, updatedAt: at)
            try write(memory, insert: true, in: db)

            // Enrichment inherits old evidence, not just the later statement that supplied the new detail.
            // A copied source remains subject to suppression, workspace and disclosure checks.
            if proposal.assertion.changeIntent == .enrichment, let previous {
                for item in try evidence(previous.memory.id, in: db) {
                    guard item.bodyPurgedAt == nil, try !suppressedMemorySource(item.source, in: db) else { throw unauthorized }
                    try insertExtractionEvidence(.init(memoryID: memory.id, source: item.source,
                        sourceWorkspaceID: item.sourceWorkspaceID, excerpt: item.excerpt,
                        sourceHash: item.sourceHash, createdAt: item.createdAt), in: db)
                }
            }
            for context in sources {
                let value = try resolve(.userMessage(evidence: context, excerpt: String(context.text.prefix(2_048))), draft: proposal.draft, in: db)
                try bindSource(value, in: db)
                try insertExtractionEvidence(.init(memoryID: memory.id, source: value.identity,
                    sourceWorkspaceID: context.workspaceID, excerpt: value.excerpt, sourceHash: value.bodyHash, createdAt: at), in: db)
            }
            try db.execute(sql: "INSERT INTO memory_assertions(assertion_key, memory_id, source_key) VALUES (?, ?, ?)",
                arguments: [assertion, key(memory.id), try sourceKey(resolved.identity)])
            try insertAspectMetadata(proposal.assertion, memoryID: memory.id, memoryRevision: memory.revision,
                source: resolved.identity, sourceHash: resolved.bodyHash, at: at, in: db)
            if evolves, let previous {
                var old = previous.memory
                try writeRelation(.init(replacementID: memory.id, previousID: old.id, state: .confirmed, createdAt: at), in: db)
                old.supersededBy = memory.id
                old.revision += 1
                old.updatedAt = at
                try write(old, insert: false, in: db)
            }
            decisions.append(.init(proposalIndex: index, memoryID: memory.id, memoryRevision: memory.revision,
                memoryState: memory.state, disposition: .created, validationReviewReason: nil,
                conflictingMemoryIDs: matches.map { $0.memory.id }, replacedMemoryID: evolves ? previous?.memory.id : nil))
            committed[index] = memory
        }
        for decision in decisions { try decision.validate() }
        let ids = decisions.reduce(into: [MemoryID]()) { if !$0.contains($1.memoryID) { $0.append($1.memoryID) } }
        let candidateIDs = decisions.filter { $0.memoryState == .candidate }.reduce(into: [MemoryID]()) {
            if !$0.contains($1.memoryID) { $0.append($1.memoryID) }
        }
        return (ids, candidateIDs, decisions)
    }

    private static func sameAssertion(_ memory: Memory, draft: MemoryDraft) -> Bool {
        guard var prior = memory.draft else { return false }
        prior.content = normalized(prior.content)
        var proposed = draft
        proposed.content = normalized(proposed.content)
        return prior == proposed
    }

    private static func validateEvolutionTarget(_ proposal: MemoryExtractionProposal, index: Int, existingCount: Int) throws {
        let intent = proposal.assertion.changeIntent
        guard proposal.replacesIndex == nil || proposal.replacesProposalIndex == nil else { throw invalid }
        if let target = proposal.replacesIndex {
            guard (0..<existingCount).contains(target), intent == .explicitReplacement || intent == .enrichment else { throw invalid }
        }
        if let target = proposal.replacesProposalIndex {
            guard (0..<index).contains(target), intent == .enrichment else { throw invalid }
        }
        if intent == .enrichment {
            guard proposal.replacesIndex != nil || proposal.replacesProposalIndex != nil else { throw invalid }
        }
    }

    private static func insertExtractionEvidence(_ value: MemoryEvidence, in db: Database) throws {
        let source = try sourceKey(value.source)
        if try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_evidence WHERE memory_id = ? AND source_key = ?",
            arguments: [key(value.memoryID), source]) == 1 { return }
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_evidence WHERE memory_id = ?",
            arguments: [key(value.memoryID)]) ?? 0 < 100 else { throw limit }
        try db.execute(sql: "INSERT INTO memory_evidence(id, memory_id, source_key, source_workspace_id, json) VALUES (?, ?, ?, ?, ?)",
            arguments: [key(value.id), key(value.memoryID), source, value.sourceWorkspaceID.map(key), try encode(value)])
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
        at: Date
    ) -> Bool {
        guard proposal.triage == .active,
            proposal.assertion.mode == .directStable,
            (proposal.assertion.changeIntent == .explicitReplacement || proposal.assertion.changeIntent == .enrichment),
            metadataRevision == current.revision,
            current.lifecycleStatus(at: at) == .active,
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
        // Adding detail cannot change when the original fact applies.
        if proposal.assertion.changeIntent == .enrichment {
            guard oldDraft.validFrom == proposal.draft.validFrom, oldDraft.validUntil == proposal.draft.validUntil else { return false }
        }
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
