import Darwin
import Foundation
import MLX

struct PrecisionQuery: Codable {
    let id: String
    let category: String
    let expected: [String]
    let expectedRanks: [String: Int]
    let expectedScores: [String: Float]
    let semantic: [RankedHit]
    let lexical: [RankedHit]
    let hybrid: [RankedHit]
    let embeddingMs: Double
    let tokenCount: Int
}

struct IndexBatch: Codable {
    let kind: String
    let count: Int
    let tokenCounts: [Int]
    let indexTiming: Timing
    let followingQueryTiming: Timing
    let combinedTiming: Timing
}

struct PrecisionReport: Codable {
    let model: Manifest
    let loadMs: Double
    let firstInferenceMs: Double
    let documentIndexMs: Double
    let documentCount: Int
    let queries: [PrecisionQuery]
    let queryTiming: Timing
    let normalActiveBytes: Int
    let normalCacheBytes: Int
    let normalPeakActiveBytes: Int
    let normalProcessResidentBytes: UInt64?
    let clearedActiveBytes: Int
    let clearedCacheBytes: Int
    let clearedProcessResidentBytes: UInt64?
    let batches: [IndexBatch]
    let finalPeakActiveBytes: Int
}

private func residentBytes() -> UInt64? {
    var info = mach_task_basic_info()
    let capacity = MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
    var count = mach_msg_type_number_t(capacity)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.resident_size : nil
}

func runPrecisionComparison(
    engine: EmbeddingEngine, corpus: Corpus, manifest: Manifest, loadMs: Double,
    firstMs: Double, output: URL, directory: URL
) async throws {
    let indexStart = now()
    var vectors: [[Float]] = []
    for offset in stride(from: 0, to: corpus.memories.count, by: 8) {
        vectors += try await engine.encode(corpus.memories[offset..<min(offset + 8, corpus.memories.count)].map(\.text)).vectors
    }
    let indexMs = now() - indexStart
    let store = try VectorStore(path: directory.appendingPathComponent("comparison.sqlite").path)
    for (fact, vector) in zip(corpus.memories, vectors) {
        try store.put(fact)
        try store.putVector(id: fact.id, revision: fact.revision, fingerprint: manifest.revision, vector: vector)
    }
    let rows = try store.rows(scope: "work", fingerprint: manifest.revision)
    for query in corpus.queries.prefix(3) { _ = try await engine.encode([query.text], query: true) }
    var results: [PrecisionQuery] = []
    for query in corpus.queries {
        let start = now()
        let encoded = try await engine.encode([query.text], query: true)
        let ms = now() - start
        let semantic = rank(encoded.vectors[0], rows: rows, limit: rows.count)
        let lexical = try store.lexical(query.text, scope: "work")
        var ranks: [String: Int] = [:]
        var scores: [String: Float] = [:]
        for (index, hit) in semantic.enumerated() where query.expected.contains(hit.id) {
            ranks[hit.id] = index + 1
            scores[hit.id] = hit.score
        }
        try require(ranks.count == query.expected.count, "Missing labeled target from eligible corpus")
        results.append(.init(id: query.id, category: query.category, expected: query.expected,
            expectedRanks: ranks, expectedScores: scores, semantic: Array(semantic.prefix(12)),
            lexical: lexical, hybrid: fuse([Array(semantic.prefix(12)), lexical], limit: 12),
            embeddingMs: ms, tokenCount: encoded.tokenCounts[0]))
    }
    let active = Memory.activeMemory
    let cache = Memory.cacheMemory
    let peak = Memory.peakMemory
    let resident = residentBytes()
    Memory.clearCache()
    let clearedActive = Memory.activeMemory
    let clearedCache = Memory.cacheMemory
    let clearedResident = residentBytes()
    log("Expanded queries complete; measuring small indexing batches")

    var batches: [IndexBatch] = []
    for kind in ["real-memory", "longer-memory"] {
        for count in [1, 2, 4, 8] {
            let texts = (0..<count).map { index in
                kind == "real-memory" ? corpus.memories[index].text : String(repeating: "memory ", count: 127)
            }
            _ = try await engine.encode(texts)
            var indexTimes: [Double] = []
            var queryTimes: [Double] = []
            var combinedTimes: [Double] = []
            var counts: [Int] = []
            for sample in 0..<5 {
                let start = now()
                let encoded = try await engine.encode(texts)
                let indexed = now()
                _ = try await engine.encode([corpus.queries[sample].text], query: true)
                let ended = now()
                counts = encoded.tokenCounts
                indexTimes.append(indexed - start)
                queryTimes.append(ended - indexed)
                combinedTimes.append(ended - start)
            }
            batches.append(.init(kind: kind, count: count, tokenCounts: counts,
                indexTiming: Timing(indexTimes), followingQueryTiming: Timing(queryTimes), combinedTiming: Timing(combinedTimes)))
        }
    }
    let report = PrecisionReport(model: manifest, loadMs: loadMs, firstInferenceMs: firstMs,
        documentIndexMs: indexMs, documentCount: corpus.memories.count, queries: results,
        queryTiming: Timing(results.map(\.embeddingMs)), normalActiveBytes: active, normalCacheBytes: cache,
        normalPeakActiveBytes: peak, normalProcessResidentBytes: resident,
        clearedActiveBytes: clearedActive, clearedCacheBytes: clearedCache, clearedProcessResidentBytes: clearedResident,
        batches: batches, finalPeakActiveBytes: Memory.peakMemory)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: output, options: .atomic)
    log("Expanded precision report written")
}
