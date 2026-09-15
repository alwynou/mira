import Foundation

/// Reconstructs active streaming draft components from committed journal facts.
/// The reader owns no cache and never interprets provider output.
public struct SessionDraftReader: Sendable {
    private let journal: any SessionJournal
    private let payloads: any SessionPayloadReader
    private static let maximumParts = 3
    private static let maximumTotalBytes = SessionFormatLimits.maximumPayloadBytes * maximumParts

    public init(journal: any SessionJournal, payloads: any SessionPayloadReader) {
        self.journal = journal
        self.payloads = payloads
    }

    public func read(state: SessionState, executionID: ExecutionID,
                     parts: Set<SessionDraftPart> = [.answer, .thinking, .transcript]) async throws -> [SessionDraftPart: Data] {
        guard let execution = state.executions[executionID] else { throw MiraError(.notFound, "The execution is unavailable.") }
        guard execution.completion == nil, !state.excludedExecutionIDs.contains(executionID) else { return [:] }
        guard execution.drafts.count <= Self.maximumParts else { throw MiraError(.storage, "The session draft contains too many components.") }
        let expectedDrafts = execution.drafts.filter { parts.contains($0.key) }
        if expectedDrafts.isEmpty { return [:] }

        var values: [SessionDraftPart: Data] = [:]
        var sequences: [SessionDraftPart: Int64?] = [:]
        var latest: [SessionDraftPart: SessionDraftCheckpoint] = [:]
        var cursor: Int64 = 0
        while cursor < state.sequence {
            try Task.checkCancellation()
            let page = try await journal.read(sessionID: state.id, after: cursor, limit: SessionFormatLimits.maximumReadBatches)
            guard !page.isEmpty else { throw MiraError(.storage, "The session journal ended before the captured draft state.") }
            for batch in page {
                try batch.validate()
                guard batch.sessionID == state.id, batch.cursor.sequence > cursor,
                      batch.expectedSequence == cursor else { throw MiraError(.storage, "The session journal cursor is malformed.") }
                if batch.expectedSequence >= state.sequence { cursor = state.sequence; break }
                for event in batch.events where event.sequence <= state.sequence {
                    if case .draftCheckpoint(let checkpoint) = event.fact, checkpoint.executionID == executionID,
                       parts.contains(checkpoint.part) {
                        guard execution.attemptIDs.contains(checkpoint.attemptID),
                              state.references[checkpoint.replacement.id] == checkpoint.replacement,
                              checkpoint.replacement.kind == .draft,
                              !state.invalidatedRetentionGroups.contains(checkpoint.replacement.retentionGroup) else {
                            throw MiraError(.storage, "The session draft checkpoint is not an authorized committed reference.")
                        }
                        let previous = values[checkpoint.part, default: Data()]
                        let previousSequence = sequences[checkpoint.part] ?? nil
                        try Task.checkCancellation()
                        let replacement = try await payloads.read(checkpoint.replacement)
                        try Task.checkCancellation()
                        values[checkpoint.part] = try SessionDraftPatch.apply(checkpoint, replacement: replacement, previous: previous, previousSequence: previousSequence)
                        sequences[checkpoint.part] = event.sequence
                        latest[checkpoint.part] = checkpoint
                    }
                }
                if batch.cursor.sequence > state.sequence { throw MiraError(.storage, "The captured state is not at a committed batch boundary.") }
                cursor = batch.cursor.sequence
                if cursor == state.sequence { break }
            }
        }

        guard Set(values.keys) == Set(expectedDrafts.keys) else { throw MiraError(.storage, "The captured session draft components are incomplete.") }
        var total = 0
        for (part, expected) in expectedDrafts {
            guard let bytes = values[part], let sequence = sequences[part], let checkpoint = latest[part],
                  bytes.count <= SessionFormatLimits.maximumPayloadBytes,
                  expected.sequence == sequence,
                  expected.checkpoint.resultByteCount == bytes.count,
                  expected.checkpoint == checkpoint else { throw MiraError(.storage, "The reconstructed session draft metadata does not match.") }
            total += bytes.count; guard total <= Self.maximumTotalBytes else { throw MiraError(.outputLimit, "The session draft exceeds the read limit.") }
        }
        try Task.checkCancellation()
        return values
    }
}
