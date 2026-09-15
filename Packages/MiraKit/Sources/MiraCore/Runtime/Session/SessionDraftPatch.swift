import Foundation

/// Byte patches preserve arbitrary UTF-8 boundaries and opaque provider continuation encodings.
public struct SessionDraftPatch: Sendable, Equatable {
    public let prefixByteCount: Int
    public let suffixByteCount: Int
    public let replacement: Data
    public let resultByteCount: Int

    public init(previous: Data, current: Data) throws {
        guard previous.count <= SessionFormatLimits.maximumPayloadBytes,
              current.count <= SessionFormatLimits.maximumPayloadBytes else {
            throw MiraError(.outputLimit, "The draft component exceeds its storage limit.")
        }
        let prefix = zip(previous, current).prefix(while: { $0 == $1 }).count
        let remaining = min(previous.count, current.count) - prefix
        let suffix = zip(previous.reversed(), current.reversed()).prefix(remaining)
            .prefix(while: { $0 == $1 }).count
        prefixByteCount = prefix; suffixByteCount = suffix; resultByteCount = current.count
        replacement = Data(current.dropFirst(prefix).dropLast(suffix))
    }

    static func validate(_ checkpoint: SessionDraftCheckpoint, previous: SessionDraftState?) throws {
        let oldSize = previous?.checkpoint.resultByteCount ?? 0
        guard checkpoint.baseSequence == previous?.sequence,
              (0...oldSize).contains(checkpoint.prefixByteCount),
              (0...(oldSize - checkpoint.prefixByteCount)).contains(checkpoint.suffixByteCount),
              (0...SessionFormatLimits.maximumPayloadBytes).contains(checkpoint.resultByteCount),
              checkpoint.replacement.byteCount >= 0,
              checkpoint.replacement.byteCount <= SessionFormatLimits.maximumPayloadBytes,
              checkpoint.resultByteCount == checkpoint.prefixByteCount + checkpoint.suffixByteCount + checkpoint.replacement.byteCount,
              previous.map({ $0.checkpoint.replacement.retentionGroup == checkpoint.replacement.retentionGroup }) ?? true else {
            throw MiraError(.conflict, "The draft patch has a stale base or invalid bounds.")
        }
    }

    public static func apply(_ checkpoint: SessionDraftCheckpoint, replacement: Data,
                             previous: Data, previousSequence: Int64?) throws -> Data {
        guard replacement.count == checkpoint.replacement.byteCount,
              previous.count <= SessionFormatLimits.maximumPayloadBytes,
              checkpoint.baseSequence == previousSequence,
              (0...previous.count).contains(checkpoint.prefixByteCount),
              (0...(previous.count - checkpoint.prefixByteCount)).contains(checkpoint.suffixByteCount),
              (0...SessionFormatLimits.maximumPayloadBytes).contains(checkpoint.resultByteCount),
              checkpoint.resultByteCount == checkpoint.prefixByteCount + checkpoint.suffixByteCount + replacement.count else {
            throw MiraError(.storage, "The draft patch chain is invalid.")
        }
        var result = Data(previous.prefix(checkpoint.prefixByteCount))
        result.append(replacement); result.append(contentsOf: previous.suffix(checkpoint.suffixByteCount))
        return result
    }
}
