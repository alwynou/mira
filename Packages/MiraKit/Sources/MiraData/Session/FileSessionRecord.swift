import Foundation
import MiraCore

/// In-memory assembly of one transaction; the file codec emits typed event lines.
/// A missing inline body is legal only after a later durable retention invalidation.
struct FileSessionRecord: Equatable {
    static let maximumInlineBytes = 256 * 1_024
    static let maximumInlineBatchBytes = 2 * 1_024 * 1_024
    static let maximumBytes = 8 * 1_024 * 1_024

    let batch: SessionBatch
    var payloads: [String: String]

    func validate() throws {
        try batch.validate()
        guard try SessionCodec.encode(batch).count <= SessionFormatLimits.maximumBatchBytes else {
            throw FileSessionIO.failure()
        }
        var owned: [String: SessionPayloadReference] = [:]
        for reference in batch.events.flatMap(\.fact.payloadReferences)
            where reference.batchID == batch.id && reference.storage == .inline {
            if let previous = owned.updateValue(reference, forKey: reference.id.uuidString), previous != reference {
                throw FileSessionIO.failure()
            }
        }
        var encodedCount = 0
        for (id, text) in payloads {
            guard let reference = owned[id] else { throw FileSessionIO.failure() }
            let bytes = Data(text.utf8)
            guard bytes.count <= Self.maximumInlineBytes, bytes.count == reference.byteCount,
                  FileSessionIO.digest(bytes) == reference.digest else { throw FileSessionIO.failure() }
            encodedCount += try SessionCodec.encode(text).count
            guard encodedCount <= Self.maximumInlineBatchBytes else { throw FileSessionIO.failure() }
        }
    }
}
