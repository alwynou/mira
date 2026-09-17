import Darwin
import Foundation
import MLX
import Metal

struct QueryFixture: Codable, Sendable {
    let id: String
    let text: String
    let expected: [String]
    let category: String
}

struct Corpus: Codable, Sendable {
    let description: String
    let memories: [MemoryFixture]
    let queries: [QueryFixture]
}

struct Manifest: Codable {
    let repo: String
    let revision: String
}

struct Timing: Codable {
    let samples: Int
    let p50Ms: Double
    let p95Ms: Double
    let minMs: Double
    let maxMs: Double
    init(_ values: [Double]) {
        let sorted = values.sorted()
        samples = sorted.count
        p50Ms = sorted[Int(ceil(Double(samples) * 0.5)) - 1]
        p95Ms = sorted[Int(ceil(Double(samples) * 0.95)) - 1]
        minMs = sorted.first!
        maxMs = sorted.last!
    }
}

struct QueryResult: Codable {
    let id: String
    let category: String
    let expected: [String]
    let lexical: [RankedHit]
    let semantic: [RankedHit]
    let hybrid: [RankedHit]
    let tokenCount: Int
    let embeddingMs: Double
    let vector: [Float]
}

struct BatchResult: Codable {
    let count: Int
    let targetTokens: Int
    let actualTokens: [Int]
    let timing: Timing
}

struct Report: Codable {
    var model: Manifest
    var fingerprint: String
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    var metalDeviceName = MTLCreateSystemDefaultDevice()?.name ?? "unavailable"
    var modelLoadMs: Double
    var firstInferenceMs: Double
    var warmQueryTiming: Timing
    var batchMinimumCosine: Float
    var batchMaximumAbsoluteError: Float
    var normMaximumError: Float
    var publicReferenceScores: [[Float]]
    var publicReferenceMaximumError: Float
    var checks: [String: Bool]
    var queries: [QueryResult]
    var batches: [BatchResult]
    var scan10KTiming: Timing
    var sqlite10KReadMs: Double
    var sqlite10KBytes: Int
    var mlxPeakActiveBytes: Int
    var mlxActiveBytes: Int
    var mlxCacheBytes: Int
    var processPeakRSSBytes: Int
    var documentVectors: [[Float]]
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

func require(_ condition: Bool, _ label: String) throws {
    guard condition else { throw PrototypeError.checkFailed(label) }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

@main
struct Prototype {
    static func main() async {
        do { try await run() }
        catch { log("Prototype failed: \(error)"); exit(1) }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 || (args.count == 6 && ["--smoke", "--compare"].contains(args[5])) else {
            throw PrototypeError.invalidInput("Usage: prototype MODEL_DIRECTORY CORPUS_JSON OUTPUT_JSON TEMP_DIRECTORY [--smoke|--compare]")
        }
        let modelURL = URL(fileURLWithPath: args[1])
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: modelURL.appendingPathComponent("prototype-manifest.json")))
        let tempURL = URL(fileURLWithPath: args[4]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard MTLCreateSystemDefaultDevice() != nil else { throw PrototypeError.invalidInput("Metal device unavailable") }
        Device.setDefault(device: .gpu)
        Memory.cacheLimit = 128 * 1024 * 1024
        let fingerprint = "\(manifest.repo)@\(manifest.revision):tokenizer-1.3.0:right-last:l2:f32:1024:query-v1"
        var start = now()
        let engine = try await EmbeddingEngine(directory: modelURL)
        let loadMs = now() - start
        start = now()
        let first = try await engine.encode([corpus.memories[0].text])
        let firstMs = now() - start
        log("Loaded \(manifest.repo); first inference complete")
        if args.last == "--compare" {
            try await runPrecisionComparison(engine: engine, corpus: corpus, manifest: manifest,
                loadMs: loadMs, firstMs: firstMs, output: URL(fileURLWithPath: args[3]), directory: tempURL)
            return
        }
        if args.last == "--smoke" {
            let normError = abs(sqrt(dot(first.vectors[0], first.vectors[0])) - 1)
            try require(normError < 0.00001, "Smoke vector normalization")
            let result: [String: Any] = ["model": manifest.repo, "revision": manifest.revision,
                "modelLoadMs": loadMs, "firstInferenceMs": firstMs, "dimension": first.vectors[0].count,
                "normError": normError, "passed": true]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: args[3]), options: .atomic)
            return
        }

        var checks: [String: Bool] = [:]
        do { _ = try await engine.encode([""]); checks["emptyRejected"] = false }
        catch PrototypeError.invalidInput { checks["emptyRejected"] = true }
        do { _ = try await engine.encode(["This input exceeds a one-token limit."], maxTokens: 1); checks["overlongRejected"] = false }
        catch PrototypeError.invalidInput { checks["overlongRejected"] = true }

        let batchTexts = Array(corpus.memories.prefix(8).map(\.text))
        let batch = try await engine.encode(batchTexts)
        var minCosine: Float = 1
        var maxAbsolute: Float = 0
        for (index, text) in batchTexts.enumerated() {
            let single = try await engine.encode([text]).vectors[0]
            let cosine = dot(single, batch.vectors[index]) / sqrt(dot(single, single) * dot(batch.vectors[index], batch.vectors[index]))
            minCosine = min(minCosine, cosine)
            maxAbsolute = max(maxAbsolute, zip(single, batch.vectors[index]).map { abs($0 - $1) }.max()!)
        }
        checks["batchMatchesSingleton"] = minCosine >= 0.999
        checks["mixedBatchLengths"] = Set(batch.tokenCounts).count > 1

        // Exact public model-card inputs: approximate numeric parity catches formatting/pooling errors.
        let referenceTexts = [
            "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:What is the capital of China?",
            "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:Explain gravity",
            "The capital of China is Beijing.",
            "Gravity is a force that attracts two bodies towards each other. It gives weight to physical objects and is responsible for the movement of planets around the sun."
        ]
        let reference = try await engine.encode(referenceTexts).vectors
        let scores = (0..<2).map { q in (2..<4).map { d in dot(reference[q], reference[d]) } }
        let published: [[Float]] = [[0.7645568, 0.1414251], [0.1354974, 0.5999550]]
        let referenceError = zip(scores.flatMap { $0 }, published.flatMap { $0 }).map { abs($0 - $1) }.max()!
        checks["publicReferenceApproximation"] = referenceError < 0.06

        var documentVectors: [[Float]] = []
        for offset in stride(from: 0, to: corpus.memories.count, by: 8) {
            let texts = corpus.memories[offset..<min(offset + 8, corpus.memories.count)].map(\.text)
            documentVectors += try await engine.encode(texts).vectors
        }
        let normError = documentVectors.map { abs(sqrt(dot($0, $0)) - 1) }.max()!
        checks["normalizedFiniteVectors"] = normError < 0.00001
        let storePath = tempURL.appendingPathComponent("recall.sqlite").path
        var store: VectorStore? = try VectorStore(path: storePath)
        for (index, fact) in corpus.memories.enumerated() {
            try store!.put(fact)
            try store!.putVector(id: fact.id, revision: fact.revision, fingerprint: fingerprint, vector: documentVectors[index])
        }
        let expectedEligible = Set(corpus.memories.filter { $0.active && $0.allowed && ["global", "work"].contains($0.scope) }.map(\.id))
        let beforeReopen = try store!.rows(scope: "work", fingerprint: fingerprint)
        store = nil
        store = try VectorStore(path: storePath)
        let rows = try store!.rows(scope: "work", fingerprint: fingerprint)
        checks["persistenceReopen"] = zip(beforeReopen, rows).allSatisfy { $0.id == $1.id && $0.vector == $1.vector } && beforeReopen.count == rows.count
        checks["scopeLifecycleDisclosure"] = Set(rows.map(\.id)) == expectedEligible
        checks["wrongFingerprintExcluded"] = try store!.rows(scope: "work", fingerprint: "wrong-space").isEmpty
        checks["wrongWorkspaceExcluded"] = try store!.rows(scope: "unrelated", fingerprint: fingerprint).allSatisfy { row in
            corpus.memories.first(where: { $0.id == row.id })!.scope == "global"
        }

        var results: [QueryResult] = []
        for query in corpus.queries {
            start = now()
            let encoded = try await engine.encode([query.text], query: true)
            let ms = now() - start
            let semantic = rank(encoded.vectors[0], rows: rows)
            let lexical = try store!.lexical(query.text, scope: "work")
            try require((semantic + lexical).allSatisfy { expectedEligible.contains($0.id) }, "Excluded retrieval")
            results.append(.init(id: query.id, category: query.category, expected: query.expected,
                lexical: Array(lexical.prefix(6)), semantic: Array(semantic.prefix(6)), hybrid: fuse([semantic, lexical]),
                tokenCount: encoded.tokenCounts[0], embeddingMs: ms, vector: encoded.vectors[0]))
        }
        checks["retrievalFilters"] = true
        let warm = Timing(results.map(\.embeddingMs))
        log("Recall queries complete; validating update/delete boundaries")

        let updated = MemoryFixture(id: "drink", text: "Updated synthetic preference", scope: "global", allowed: true, active: true, revision: 2)
        try store!.put(updated)
        checks["oldRevisionExcluded"] = try !store!.rows(scope: "work", fingerprint: fingerprint).contains { $0.id == "drink" }
        checks["staleWriteRejected"] = try !store!.putVector(id: "drink", revision: 1, fingerprint: fingerprint, vector: documentVectors[0])
        checks["currentWriteAccepted"] = try store!.putVector(id: "drink", revision: 2, fingerprint: fingerprint, vector: documentVectors[0])
        try store!.delete(id: "drink")
        checks["deleteClearsRetrieval"] = try !store!.rows(scope: "work", fingerprint: fingerprint).contains { $0.id == "drink" }
            && !store!.lexical(updated.text, scope: "work").contains { $0.id == "drink" }
        checks["lateWriteAfterDeleteRejected"] = try !store!.putVector(id: "drink", revision: 2, fingerprint: fingerprint, vector: documentVectors[0])
        store = nil

        // Repeat synthetic vectors only for the scan/storage workload, not recall quality.
        let scalePath = tempURL.appendingPathComponent("scale.sqlite").path
        var scale: VectorStore? = try VectorStore(path: scalePath)
        for index in 0..<10_000 {
            let fact = MemoryFixture(id: "scale-\(index)", text: "Synthetic scale record \(index)", scope: "global", allowed: true, active: true, revision: 1)
            try scale!.put(fact)
            try scale!.putVector(id: fact.id, revision: 1, fingerprint: fingerprint, vector: documentVectors[index % documentVectors.count])
        }
        scale = nil
        let dbBytes = (try FileManager.default.attributesOfItem(atPath: scalePath)[.size] as! NSNumber).intValue
        scale = try VectorStore(path: scalePath)
        start = now()
        let scaleRows = try scale!.rows(scope: "work", fingerprint: fingerprint)
        let readMs = now() - start
        try require(scaleRows.count == 10_000, "Scale corpus count")
        var scanMs: [Double] = []
        for index in 0..<50 {
            start = now()
            let found = rank(results[index % results.count].vector, rows: scaleRows, limit: 6)
            scanMs.append(now() - start)
            try require(found.count == 6, "Scale search result count")
        }
        scale = nil

        var batches: [BatchResult] = []
        for target in [128, 512] {
            let repeated = String(repeating: "memory ", count: target - 1)
            for count in [1, 8, 16] {
                let texts = Array(repeating: repeated, count: count)
                var times: [Double] = []
                var counts: [Int] = []
                for _ in 0..<3 {
                    start = now()
                    let result = try await engine.encode(texts)
                    times.append(now() - start)
                    counts = result.tokenCounts
                }
                batches.append(.init(count: count, targetTokens: target, actualTokens: counts, timing: Timing(times)))
                log("Measured batch \(count) x \(target) tokens")
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let report = Report(model: manifest, fingerprint: fingerprint, modelLoadMs: loadMs, firstInferenceMs: firstMs,
            warmQueryTiming: warm, batchMinimumCosine: minCosine, batchMaximumAbsoluteError: maxAbsolute,
            normMaximumError: normError, publicReferenceScores: scores, publicReferenceMaximumError: referenceError,
            checks: checks, queries: results, batches: batches,
            scan10KTiming: Timing(scanMs), sqlite10KReadMs: readMs, sqlite10KBytes: dbBytes,
            mlxPeakActiveBytes: Memory.peakMemory, mlxActiveBytes: Memory.activeMemory,
            mlxCacheBytes: Memory.cacheMemory, processPeakRSSBytes: Int(usage.ru_maxrss), documentVectors: documentVectors)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
        for (name, passed) in checks.sorted(by: { $0.key < $1.key }) { log("\(passed ? "PASS" : "FAIL") \(name)") }
        try require(checks.values.allSatisfy { $0 }, "One or more prototype checks failed; see report")
        log("Report written: \(args[3])")
    }
}
