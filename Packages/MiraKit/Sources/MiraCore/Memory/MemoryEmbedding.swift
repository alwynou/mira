import Foundation

/// A complete embedding space identity. Changing any preprocessing or model detail requires reindexing.
public struct MemoryEmbeddingIdentity: Codable, Hashable, Sendable {
    public let fingerprint: String
    public let dimensions: Int

    public init(fingerprint: String, dimensions: Int) {
        self.fingerprint = fingerprint
        self.dimensions = dimensions
    }

    public static let qwen3FourBit = Self(
        fingerprint: "qwen3-0.6b:6c3ae70858513f1a78e9cdca3cae330d9075cd2a:dwq4-g64:rightpad:last:fp32norm:1024:memory-query-v1",
        dimensions: 1024)

    public static let queryInstruction = "Instruct: Given a conversation request, retrieve relevant user memories that help answer it.\nQuery:"
}

public enum MemoryEmbeddingInput: Sendable {
    case query(String)
    case documents([String])
}

public enum MemoryEmbeddingStatus: Equatable, Sendable {
    case unavailable, installing, ready, failed(MiraError)
}

/// The host owns installation and serialized local inference. No remote inference fallback is permitted.
/// Queries must take priority between bounded document dispatches. Cancellation drains submitted work.
public protocol MemoryEmbeddingService: Sendable {
    var identity: MemoryEmbeddingIdentity { get }
    func status() async -> MemoryEmbeddingStatus
    func prepare() async throws
    func embed(_ input: MemoryEmbeddingInput) async throws -> [[Float]]
    func unload() async
    func close() async
}
