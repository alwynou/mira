import MiraCore

/// Ordinary host tests never download a model or create a GPU context.
/// Native model tests explicitly construct MacMemoryEmbeddingService instead.
struct OfflineMemoryEmbedding: MemoryEmbeddingService {
    let identity = MemoryEmbeddingIdentity.qwen3FourBit
    func status() async -> MemoryEmbeddingStatus { .unavailable }
    func prepare() async throws { throw MiraError(.unsupported, "Synthetic embedding is offline.") }
    func embed(_ input: MemoryEmbeddingInput) async throws -> [[Float]] {
        throw MiraError(.unsupported, "Synthetic embedding is offline.")
    }
    func unload() async {}
    func close() async {}
}
