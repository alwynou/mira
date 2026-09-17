import Foundation
import CryptoKit
import MLX
import MLXEmbedders
import MLXLMCommon
import Tokenizers
import MiraCore

/// The production owner of the local Qwen embedding model.  The model is deliberately
/// kept out of MiraCore: loading MLX is a macOS concern and must never become a remote
/// provider fallback.
public actor MacMemoryEmbeddingService: MemoryEmbeddingService {
    public let identity: MemoryEmbeddingIdentity

    private let directory: URL
    private var container: EmbedderModelContainer?
    private var currentStatus: MemoryEmbeddingStatus = .unavailable
    private var closed = false
    private var admissionOpen = true
    private var prepareTask: Task<EmbedderModelContainer, Error>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var memoryPressureActive = false
    private let inferenceQueue = EmbeddingInferenceQueue()

    public init(directory: URL) {
        self.directory = directory
        self.identity = .qwen3FourBit
    }

    public func status() async -> MemoryEmbeddingStatus { currentStatus }

    public func prepare() async throws {
        guard !closed, admissionOpen else { throw MiraError(.busy, "The local embedding service is closed.") }
        guard !memoryPressureActive else { throw MiraError(.busy, "The local embedding model is paused during memory pressure.") }
        if container != nil { return }
        if let prepareTask {
            let loaded = try await withTaskCancellationHandler { try await prepareTask.value } onCancel: { prepareTask.cancel() }
            try Task.checkCancellation()
            guard !closed, admissionOpen, !memoryPressureActive else {
                throw MiraError(.busy, "The local embedding service is unavailable.")
            }
            container = loaded
            currentStatus = .ready
            startMemoryPressureMonitor()
            return
        }
        currentStatus = .installing
        Device.setDefault(device: .gpu)
        Memory.cacheLimit = 128 * 1024 * 1024
        startMemoryPressureMonitor()
        let task = Task { [directory] in
            try await MacMemoryEmbeddingInstaller.ensureInstalled(at: directory)
            return try await EmbedderModelFactory.shared.loadContainer(
                from: directory, using: LocalTokenizerLoader())
        }
        prepareTask = task
        do {
            let loaded = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            prepareTask = nil
            guard !closed, admissionOpen, !memoryPressureActive else {
                throw MiraError(.busy, "The local embedding service is unavailable.")
            }
            container = loaded
            currentStatus = .ready
            startMemoryPressureMonitor()
        } catch is CancellationError {
            currentStatus = .unavailable
            prepareTask = nil
            throw CancellationError()
        } catch let error as MiraError {
            currentStatus = memoryPressureActive ? .unavailable : .failed(error)
            prepareTask = nil
            throw error
        } catch {
            let safe = MiraError(.configuration, "The local embedding model is unavailable or invalid.")
            currentStatus = .failed(safe)
            prepareTask = nil
            throw safe
        }
    }

    public func embed(_ input: MemoryEmbeddingInput) async throws -> [[Float]] {
        guard !closed, admissionOpen, !memoryPressureActive else {
            throw MiraError(.busy, "The local embedding service is unavailable.")
        }
        guard let container else {
            throw MiraError(.configuration, "The local embedding model is not prepared.")
        }
        try Task.checkCancellation()
        let isQuery: Bool
        let texts: [String]
        let maxTokens: Int
        switch input {
        case .query(let text):
            isQuery = true
            texts = [text]
            maxTokens = 1024
        case .documents(let values):
            isQuery = false
            guard !values.isEmpty, values.count <= 4 else {
                throw MiraError(.invalidInput, "A document embedding dispatch supports one to four documents.")
            }
            texts = values
            // Active conversation indexing is intentionally small. A single explicitly
            // requested long document is allowed to use the model's normal bound.
            maxTokens = values.count == 1 ? 1024 : 128
        }
        guard texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw MiraError(.invalidInput, "Embedding input cannot be empty.")
        }
        await inferenceQueue.acquire(isQuery: isQuery)
        do {
            try Task.checkCancellation()
            let result = try await encode(texts, query: isQuery, maxTokens: maxTokens, container: container)
            await inferenceQueue.release()
            return result
        } catch is CancellationError {
            // Cancellation cannot preempt a submitted MLX graph. Waiting for perform()
            // to return above preserves the single-owner invariant before release.
            await inferenceQueue.release()
            throw CancellationError()
        } catch let error as MiraError {
            await inferenceQueue.release()
            throw error
        } catch {
            await inferenceQueue.release()
            throw MiraError(.storage, "Local embedding inference failed.")
        }
    }

    public func unload() async {
        admissionOpen = false
        prepareTask?.cancel()
        if let prepareTask { _ = await prepareTask.result }
        prepareTask = nil
        await inferenceQueue.waitUntilIdle()
        container = nil
        Memory.clearCache()
        if !closed { admissionOpen = true; currentStatus = .unavailable }
    }

    public func close() async {
        admissionOpen = false
        closed = true
        pressureSource?.setEventHandler(handler: {})
        pressureSource?.cancel()
        pressureSource = nil
        prepareTask?.cancel()
        if let prepareTask { _ = try? await prepareTask.value }
        await inferenceQueue.waitUntilIdle()
        container = nil
        Memory.clearCache()
        prepareTask = nil
        currentStatus = .unavailable
    }

    private func startMemoryPressureMonitor() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let rawEvent = source.data.rawValue
            Task { await self.handleMemoryPressure(rawEvent) }
        }
        source.resume()
        pressureSource = source
    }

    private func handleMemoryPressure(_ rawEvent: UInt) async {
        let event = DispatchSource.MemoryPressureEvent(rawValue: rawEvent)
        if event.contains(.normal) {
            memoryPressureActive = false
            return
        }
        guard event.contains(.warning) || event.contains(.critical) else { return }
        memoryPressureActive = true
        guard !closed else { return }
        await unload()
    }

    private func encode(
        _ texts: [String], query: Bool, maxTokens: Int, container: EmbedderModelContainer
    ) async throws -> [[Float]] {
        try await container.perform { context in
            let tokenLists = texts.map {
                context.tokenizer.encode(
                    text: query ? MemoryEmbeddingIdentity.queryInstruction + $0 : $0,
                    addSpecialTokens: true)
            }
            let counts = tokenLists.map(\.count)
            guard counts.allSatisfy({ $0 > 0 && $0 <= maxTokens }) else {
                throw MiraError(.outputLimit, "Embedding input exceeds its token limit.")
            }
            let width = counts.max() ?? 0
            let paddingID = context.tokenizer.eosTokenId ?? 0
            let ids = tokenLists.flatMap { $0 + Array(repeating: paddingID, count: width - $0.count) }
            let mask = counts.flatMap {
                Array(repeating: Int32(1), count: $0) + Array(repeating: Int32(0), count: width - $0)
            }
            let input = MLXArray(ids).reshaped(texts.count, width)
            let attentionMask = MLXArray(mask).reshaped(texts.count, width)
            let output = context.model(input, positionIds: nil, tokenTypeIds: nil, attentionMask: attentionMask)
            let pooled = context.pooling(output, mask: attentionMask, normalize: false, applyLayerNorm: false)
            pooled.eval()
            let vectors = (0..<texts.count).map { pooled[$0].asArray(Float.self) }
            guard vectors.allSatisfy({ $0.count == 1024 && $0.allSatisfy(\.isFinite) }) else {
                throw MiraError(.storage, "The embedding model returned an invalid vector.")
            }
            let normalized = vectors.map { vector in
                let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
                guard norm.isFinite, norm > 0 else { return [Float]() }
                return vector.map { $0 / norm }
            }
            guard normalized.allSatisfy({ $0.count == 1024 }) else {
                throw MiraError(.storage, "The embedding model returned a zero vector.")
            }
            return normalized
        }
    }
}

private actor EmbeddingInferenceQueue {
    private var busy = false
    private var queries: [CheckedContinuation<Void, Never>] = []
    private var documents: [CheckedContinuation<Void, Never>] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func acquire(isQuery: Bool) async {
        if !busy { busy = true; return }
        await withCheckedContinuation { continuation in
            if isQuery { queries.append(continuation) } else { documents.append(continuation) }
        }
    }

    func release() {
        if let next = queries.first {
            queries.removeFirst(); next.resume(); return
        }
        if let next = documents.first {
            documents.removeFirst(); next.resume(); return
        }
        busy = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilIdle() async {
        if !busy { return }
        await withCheckedContinuation { continuation in idleWaiters.append(continuation) }
    }
}

private struct LocalTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        LocalTokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}
