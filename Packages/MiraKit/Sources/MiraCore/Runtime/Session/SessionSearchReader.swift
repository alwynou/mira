import Foundation

/// Finite journal replay and source verification, independent of the index technology.
enum SessionSearchReader {
    static func synchronize(
        journal: any SessionJournal, payloads: any SessionContentReader,
        index: any SessionSearchIndex, schemas: [String: Set<Int>],
        lease: AgentLibraryAccessLease
    ) async throws {
        var cursor: ConversationID?
        var count = 0
        while true {
            try Task.checkCancellation()
            let after = cursor
            let ids = try await lease.read { try await journal.sessions(after: after, limit: 128) }
            guard ids.count <= 128 else { throw invalid }
            if ids.isEmpty { return }
            for id in ids {
                guard count < 4_096, cursor.map({ $0.rawValue.uuidString < id.rawValue.uuidString }) ?? true else {
                    throw invalid
                }
                try await synchronize(
                    sessionID: id, journal: journal, payloads: payloads,
                    index: index, schemas: schemas, lease: lease)
                cursor = id
                count += 1
            }
        }
    }

    private static func synchronize(
        sessionID: ConversationID, journal: any SessionJournal,
        payloads: any SessionContentReader, index: any SessionSearchIndex,
        schemas: [String: Set<Int>], lease: AgentLibraryAccessLease
    ) async throws {
        let target = try await lease.read { try await journal.head(sessionID: sessionID) }
        try await validate(target, journal: journal, lease: lease)
        var checkpoint =
            try await lease.read { try await index.head(sessionID: sessionID) }
            ?? .init(cursor: .init(sessionID: sessionID, sequence: 0), batchID: nil)
        guard checkpoint.cursor.sessionID == sessionID, checkpoint.cursor.sequence <= target.cursor.sequence else {
            throw invalid
        }
        try await validate(checkpoint, journal: journal, lease: lease)
        if checkpoint == target { return }
        let snapshot = try await lease.read {
            try await JournalSessionReader(journal: journal, payloads: payloads, extensionSchemas: schemas)
                .snapshot(through: target)
        }
        while checkpoint.cursor.sequence < target.cursor.sequence {
            try Task.checkCancellation()
            let after = checkpoint.cursor.sequence
            let page = try await lease.read {
                try await journal.read(
                    sessionID: sessionID, after: after, limit: SessionFormatLimits.maximumReadBatches)
            }
            guard !page.isEmpty, page.count <= SessionFormatLimits.maximumReadBatches else { throw invalid }
            for batch in page {
                try Task.checkCancellation()
                try batch.validate()
                guard batch.sessionID == sessionID, batch.expectedSequence == checkpoint.cursor.sequence,
                    batch.cursor.sequence <= target.cursor.sequence,
                    batch.cursor.sequence != target.cursor.sequence || batch.id == target.batchID
                else { throw invalid }
                let locations = locations(in: batch)
                var bytes = 0
                for location in locations { try reserve(location, total: &bytes, maximum: 64 * 1_024 * 1_024) }
                var documents: [SessionSearchDocument] = []
                for location in locations {
                    documents.append(
                        .init(
                            location: location,
                            text: try await text(location.reference, payloads: payloads, lease: lease)))
                }
                let update = SessionSearchUpdate(batch: batch, documents: documents)
                try await lease.read { try await index.apply(update) }
                checkpoint = .init(cursor: batch.cursor, batchID: batch.id)
                if checkpoint == target { return }
            }
        }
    }

    static func resolve(
        _ page: SessionSearchIndexPage, selection: SessionSearchSelection, limit: Int,
        journal: any SessionJournal, payloads: any SessionContentReader, schemas: [String: Set<Int>],
        lease: AgentLibraryAccessLease, maximumPageBytes: Int
    ) async throws -> SessionSearchPage {
        guard page.matches.count <= limit, (0...20_000).contains(page.scannedCandidates),
            page.scannedCandidates >= page.matches.count,
            Set(page.matches.map { $0.reference.id }).count == page.matches.count
        else { throw invalid }
        // Check the whole page before any body I/O, including hits later found stale.
        var bytes = 0
        for location in page.matches { try reserve(location, total: &bytes, maximum: maximumPageBytes) }
        var hits: [UUID: SessionSearchHit] = [:]
        let groups = Dictionary(grouping: page.matches, by: \.sessionID)
        for sessionID in groups.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            try Task.checkCancellation()
            let snapshot = try await lease.read {
                try await JournalSessionReader(journal: journal, payloads: payloads, extensionSchemas: schemas)
                    .snapshot(sessionID: sessionID)
            }
            let state = snapshot.state
            guard state.header != nil, selection.includeArchived || !state.isArchived,
                scopeMatches(selection.scope, workspaceID: state.header?.workspaceID)
            else { continue }
            for location in groups[sessionID, default: []] {
                guard location.sequence <= state.sequence,
                    state.references[location.reference.id] == location.reference,
                    location.part != .title || state.title == location.reference,
                    selection.since.map({ location.occurredAt >= $0 }) ?? true,
                    selection.until.map({ location.occurredAt < $0 }) ?? true
                else { continue }
                let batch = try await lease.read {
                    try await journal.read(sessionID: sessionID, after: location.sequence - 1, limit: 1).first
                }
                guard let batch, batch.cursor.sequence <= snapshot.head.cursor.sequence else { throw invalid }
                try batch.validate()
                guard locations(in: batch).contains(location) else { throw invalid }
                let body = try await text(location.reference, payloads: payloads, lease: lease)
                guard SessionSearchText.matches(body, query: selection.text) else { continue }
                hits[location.reference.id] = .init(
                    location: location,
                    snippet: SessionSearchText.snippet(body, query: selection.text), observedHead: snapshot.head)
            }
        }
        try Task.checkCancellation()
        try await lease.check()
        try Task.checkCancellation()
        return .init(
            hits: page.matches.compactMap { hits[$0.reference.id] }, nextCursor: page.nextCursor,
            isTruncated: page.isTruncated || hits.count != page.matches.count,
            scannedCandidates: page.scannedCandidates, capabilities: page.capabilities)
    }

    static func locations(in batch: SessionBatch) -> [SessionSearchLocation] {
        var result: [SessionSearchLocation] = []
        for event in batch.events {
            func append(
                _ reference: SessionContent?, part: SessionSearchPart,
                messageID: MessageID? = nil, executionID: ExecutionID? = nil
            ) {
                guard let reference else { return }
                result.append(
                    .init(
                        sessionID: batch.sessionID, messageID: messageID, executionID: executionID,
                        part: part, sequence: event.sequence, occurredAt: event.occurredAt, reference: reference))
            }
            switch event.fact {
            case .opened(let header): append(header.title, part: .title)
            case .renamed(let title, _): append(title, part: .title)
            case .admitted(let admission):
                append(
                    admission.userBody, part: .user, messageID: admission.userMessageID,
                    executionID: admission.executionID)
            case .finished(let completion):
                if let messageID = completion.assistantMessageID {
                    append(
                        completion.answer, part: .assistant, messageID: messageID, executionID: completion.executionID)
                    append(
                        completion.visibleThinking, part: .thinking, messageID: messageID,
                        executionID: completion.executionID)
                }
            default: break
            }
        }
        return result
    }

    private static func scopeMatches(_ scope: SessionQueryScope, workspaceID: WorkspaceID?) -> Bool {
        switch scope {
        case .all: true
        case .inbox: workspaceID == nil
        case .workspace(let id): workspaceID == id
        }
    }

    private static func validate(
        _ head: SessionJournalHead, journal: any SessionJournal,
        lease: AgentLibraryAccessLease
    ) async throws {
        try head.validate()
        guard let id = head.batchID else { return }
        let batch = try await lease.read { try await journal.batch(id: id, sessionID: head.cursor.sessionID) }
        guard let batch, batch.id == id, batch.cursor == head.cursor else { throw invalid }
        try batch.validate()
    }

    private static func reserve(_ location: SessionSearchLocation, total: inout Int, maximum: Int) throws {
        try location.validate()
        guard location.reference.byteCount <= maximum - total else {
            throw MiraError(.outputLimit, "The session query page exceeds its content limit.")
        }
        total += location.reference.byteCount
    }

    private static func text(
        _ reference: SessionContent, payloads: any SessionContentReader,
        lease: AgentLibraryAccessLease
    ) async throws -> String {
        try Task.checkCancellation()
        let bytes = try await lease.read { try await payloads.read(reference) }
        try Task.checkCancellation()
        guard bytes.count == reference.byteCount else { throw invalid }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw MiraError(.storage, "The session payload contains invalid text encoding.")
        }
        return text
    }

    private static var invalid: MiraError { .init(.storage, "The session search index does not match the journal.") }
}
