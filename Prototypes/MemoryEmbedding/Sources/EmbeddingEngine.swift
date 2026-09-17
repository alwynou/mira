import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import Tokenizers

enum PrototypeError: Error {
    case invalidInput(String)
    case checkFailed(String)
    case database(String)
}

struct LocalTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        LocalTokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct EmbeddedBatch: Sendable {
    let vectors: [[Float]]
    let tokenCounts: [Int]
}

struct EmbeddingEngine: Sendable {
    let container: EmbedderModelContainer
    static let queryPrefix = "Instruct: Given a conversation request, retrieve relevant user memories that help answer it.\nQuery:"

    init(directory: URL) async throws {
        container = try await EmbedderModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
    }

    func encode(_ texts: [String], query: Bool = false, maxTokens: Int = 1024) async throws -> EmbeddedBatch {
        guard !texts.isEmpty, texts.count <= 16,
              texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PrototypeError.invalidInput("Empty input or unsupported batch size")
        }
        return try await container.perform { context in
            let tokens = texts.map {
                context.tokenizer.encode(text: query ? Self.queryPrefix + $0 : $0, addSpecialTokens: true)
            }
            let counts = tokens.map(\.count)
            guard counts.allSatisfy({ $0 > 0 && $0 <= maxTokens }) else {
                throw PrototypeError.invalidInput("Token limit exceeded; no silent truncation")
            }
            let width = counts.max()!
            let paddingID = context.tokenizer.eosTokenId ?? 0
            let ids = tokens.flatMap { $0 + Array(repeating: paddingID, count: width - $0.count) }
            let mask = counts.flatMap { Array(repeating: Int32(1), count: $0) + Array(repeating: Int32(0), count: width - $0) }
            let input = MLXArray(ids).reshaped(texts.count, width)
            let attentionMask = MLXArray(mask).reshaped(texts.count, width)
            let output = context.model(input, positionIds: nil, tokenTypeIds: nil, attentionMask: attentionMask)
            let pooled = context.pooling(output, mask: attentionMask, normalize: false, applyLayerNorm: false)
            // Materialize on the serialized model owner before transferring plain Swift values.
            pooled.eval()
            let vectors = (0..<texts.count).map { pooled[$0].asArray(Float.self) }
            guard vectors.allSatisfy({ $0.count == 1024 && $0.allSatisfy(\.isFinite) }) else {
                throw PrototypeError.checkFailed("Invalid embedding shape or non-finite output")
            }
            // Normalize materialized Float32 values so BF16 rounding does not change vector length.
            let norms = vectors.map { sqrt(dot($0, $0)) }
            guard norms.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw PrototypeError.checkFailed("Invalid vector norm")
            }
            let normalized = zip(vectors, norms).map { vector, norm in vector.map { $0 / norm } }
            return EmbeddedBatch(vectors: normalized, tokenCounts: counts)
        }
    }
}
